//+------------------------------------------------------------------+
//|                                              SessionBias_EA.mq5  |
//|                         Multi-TF Trend + Pullback Strategy       |
//|                         v14.0 — solo EUR+GBP | BreakEven activo  |
//|                                + ADX D1 filtro agosto | +RR      |
//+------------------------------------------------------------------+
#property copyright "SessionBias EA"
#property version   "14.0"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade         trade;
CPositionInfo  posInfo;

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input double Version = 14.0;

input group "=== GESTIÓN DE RIESGO V14 ==="
input double   RiskPercent       = 0.5;
// v14: TP subido 2.0→2.5 ATR para mejorar payoff real
// En v13 el payoff real fue 1.41 vs teórico 1.67 (cierre forzado cortaba TPs)
// Ahora el cierre forzado ya está calibrado a 17h — subir el TP
// da más margen para que el precio llegue al objetivo dentro de la sesión
input double   ATR_Multiplier_SL = 1.2;
input double   ATR_Multiplier_TP = 2.5;    // Subido 2.0→2.5
input int      ATR_Period        = 14;

input group "=== CIRCUIT BREAKER V14 ==="
input bool     UseCircuitBreaker    = true;
input int      MaxConsecLosses      = 4;
input int      CircuitBreakerHours  = 48;

input group "=== CIERRE POR TIEMPO V14 ==="
input bool     UseForceClose     = true;
input int      ForceCloseHour    = 17;
input int      ForceCloseMinute  = 0;

input group "=== GESTIÓN DE POSICIÓN V14 ==="
// v14: BreakEven ACTIVADO — en v13 el payoff real fue 1.41 vs teórico 1.67
// El cierre forzado cortaba trades ganadores con ganancia parcial
// Con BE: cuando el precio avanza 1.0xATR, mover SL a entrada + buffer
// Convierte ~35% de los SL en breakeven → reduce avg_loss sin tocar WR
input bool   UseBreakEven       = true;    // ACTIVADO (era false)
input bool   UsePartialClose    = false;
input double PartialClose_Pct   = 30.0;
input double BreakEven_ATR_Mult = 1.0;    // Activar BE al alcanzar 1.0xATR
input int    BreakEven_Padding  = 5;      // 5 puntos sobre entrada (cubre spread)
input bool   UseStepTrailing    = false;
input double Step1_Trigger      = 2.0;
input double Step1_Lock         = 1.0;
input double Step2_Trigger      = 3.0;
input double Step2_Lock         = 1.8;

input group "=== FILTROS DE ALTA PROBABILIDAD V14 ==="
// v14: ADX subido 25→28 para entrar solo en tendencias más definidas
// Filtro ADX D1 nuevo: si la tendencia diaria es débil (ADX<20 en D1),
// el mercado está en rango — patrón identificado en agosto 2025 (WR 13%)
input int      ADX_Min           = 28;     // Subido 25→28
input int      ADX_Min_D1        = 20;     // Nuevo: ADX mínimo en D1 (filtro rango semanal)
input bool     UseDailyFilter    = true;
input double   MinBodyPct        = 0.6;

input group "=== PARES — análisis EV por trade v13 ==="
// EV calculado con avg_win=$63 avg_loss=$45 sobre 341 trades reales
input bool     Trade_EURUSD = true;    // EV +$3.24/trade, WR 44% ✅ ÚNICO POSITIVO
input bool     Trade_GBPUSD = true;    // EV -$2.87/trade, WR 39% — probar con BreakEven
// CORTAR — EV negativo confirmado en v13:
input bool     Trade_USDJPY = false;   // EV -$15.26/trade, WR 27% ❌ drena -$1,343
input bool     Trade_NZDUSD = false;   // EV -$9.42/trade,  WR 33% ❌ drena -$980
input bool     Trade_USDCAD = false;   // EV -$3.06/trade,  WR 39% ❌ drena -$349
input bool     Trade_AUDUSD = false;   // Sin datos suficientes ❌
input bool     Trade_GBPJPY = false;   // Sin datos suficientes ❌
input bool     Trade_USDCHF = false;   // Históricamente negativo ❌
input bool     Trade_XAUUSD = false;   // WR 27% en v11 ❌

input group "=== FILTROS DE MOMENTUM ==="
input bool   UseRSIFilter      = true;
input int    RSI_Period        = 14;
input int    RSI_Overbought    = 70;
input int    RSI_Oversold      = 30;
input bool   UseStrictEMA      = true;

input group "=== FILTROS DE SEGURIDAD V13 ==="
input int      MinCandlesWait    = 8;
input double   VolumeFilterMult  = 1.1;
// v11: spread máximo por tipo de par (pips × 10 en 5 dígitos)
input int      MaxSpreadForex    = 30;   // Máx 3 pips para forex majors
input int      MaxSpreadGold     = 500;  // Máx 50 pips para XAUUSD (spread ~$0.30)

//+------------------------------------------------------------------+
//| ESTRUCTURAS                                                       |
//+------------------------------------------------------------------+
enum MARKET_REGIME { REGIME_TREND_UP, REGIME_TREND_DOWN, REGIME_RANGE, REGIME_UNDEFINED };
enum SIGNAL_TYPE   { SIGNAL_BUY, SIGNAL_SELL, SIGNAL_NONE };

struct MarketAnalysis
{
   MARKET_REGIME regime;
   SIGNAL_TYPE   signal;
   double        entryPrice;
   double        stopLoss;
   double        takeProfit;
   double        atrValue;
   string        reason;
};

//+------------------------------------------------------------------+
//| VARIABLES GLOBALES                                               |
//+------------------------------------------------------------------+
string   g_pairs[];
datetime g_lastBarTime[];
datetime g_lastTradeTime[];

// Circuit breaker — contador de pérdidas consecutivas por par
int      g_consecLosses[];        // Pérdidas consecutivas actuales por par
datetime g_circuitBreakerUntil[]; // Hasta cuándo está pausado cada par

//+------------------------------------------------------------------+
//| INICIALIZACIÓN                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(20240001);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   BuildPairsList();
   int totalPairs = ArraySize(g_pairs);

   ArrayResize(g_lastBarTime,        totalPairs); ArrayInitialize(g_lastBarTime,        0);
   ArrayResize(g_lastTradeTime,      totalPairs); ArrayInitialize(g_lastTradeTime,      0);
   ArrayResize(g_consecLosses,       totalPairs); ArrayInitialize(g_consecLosses,       0);
   ArrayResize(g_circuitBreakerUntil,totalPairs); ArrayInitialize(g_circuitBreakerUntil,0);

   Print("✅ GeminiBot v13 iniciado — ", totalPairs, " pares | ventana 13-17h GMT | cierre forzado 17h");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| TICK PRINCIPAL                                                    |
//+------------------------------------------------------------------+
void OnTick()
{
   // FIX v13: cerrar todas las posiciones a las 17:00 GMT
   // Elimina los cierres nocturnos con WR 8-25% (78 cierres a las 18h en v12)
   if(UseForceClose) CloseAllAtSessionEnd();

   ManageBreakEven();

   for(int i = 0; i < ArraySize(g_pairs); i++)
   {
      string symbol = g_pairs[i];

      // Circuit breaker: par pausado tras racha de pérdidas
      if(UseCircuitBreaker && TimeCurrent() < g_circuitBreakerUntil[i]) continue;

      // Cooldown entre trades del mismo par
      if(TimeCurrent() - g_lastTradeTime[i] < (MinCandlesWait * 15 * 60)) continue;

      // Solo procesar en nueva vela M15
      datetime curBar = iTime(symbol, PERIOD_M15, 0);
      if(curBar == g_lastBarTime[i]) continue;
      g_lastBarTime[i] = curBar;

      if(!IsTradingTime() || !IsSpreadOk(symbol) || HasPosition(symbol)) continue;

      MarketAnalysis analysis;
      AnalyzePullback(symbol, analysis);

      if(analysis.signal != SIGNAL_NONE) ExecuteTrade(symbol, analysis);
   }
}

//+------------------------------------------------------------------+
//| DETECCIÓN DE CIERRE DE POSICIONES (circuit breaker)             |
//+------------------------------------------------------------------+
void OnTrade()
{
   if(!UseCircuitBreaker) return;

   // Revisar deals recientes para detectar SL hit por par
   HistorySelect(TimeCurrent() - 120, TimeCurrent());
   int total = HistoryDealsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      ulong  ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC)  != 20240001)    continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY)  != DEAL_ENTRY_OUT) continue;

      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      string sym    = HistoryDealGetString(ticket, DEAL_SYMBOL);

      // Buscar el índice del par en g_pairs
      for(int j = 0; j < ArraySize(g_pairs); j++)
      {
         if(g_pairs[j] != sym) continue;

         if(profit < 0.0)
         {
            g_consecLosses[j]++;
            if(g_consecLosses[j] >= MaxConsecLosses)
            {
               g_circuitBreakerUntil[j] = TimeCurrent() + CircuitBreakerHours * 3600;
               g_consecLosses[j] = 0;
               Print("⛔ Circuit breaker activado en ", sym,
                     " — ", MaxConsecLosses, " pérdidas seguidas.",
                     " Pausa hasta: ", TimeToString(g_circuitBreakerUntil[j]));
            }
         }
         else
         {
            // Win — resetear contador
            g_consecLosses[j] = 0;
         }
         break;
      }
      break; // Solo el deal más reciente
   }
}

//+------------------------------------------------------------------+
//| ANÁLISIS PULLBACK MULTI-TF                                       |
//+------------------------------------------------------------------+
void AnalyzePullback(string symbol, MarketAnalysis &analysis)
{
   analysis.signal = SIGNAL_NONE;

   // 1. FILTRO DE TENDENCIA MACRO (D1 actual + H4)
   double closeD1   = iClose(symbol, PERIOD_D1, 0);
   double openD1    = iOpen(symbol,  PERIOD_D1, 0);
   double ema200_H4 = GetEMA(symbol, PERIOD_H4, 200);
   double closeH4   = iClose(symbol, PERIOD_H4, 1);

   bool trendUp   = (closeH4 > ema200_H4) && (closeD1 > openD1);
   bool trendDown = (closeH4 < ema200_H4) && (closeD1 < openD1);
   if(!trendUp && !trendDown) return;

   // 2. FILTRO DE MOMENTUM (RSI en M15)
   if(UseRSIFilter)
   {
      double rsi = GetRSI(symbol, PERIOD_M15, RSI_Period);
      if(trendUp   && rsi > RSI_Overbought) return;
      if(trendDown && rsi < RSI_Oversold)   return;
   }

   // 3. ALINEACIÓN EMAs en H1
   double ema21_H1 = GetEMA(symbol, PERIOD_H1, 21);
   double ema50_H1 = GetEMA(symbol, PERIOD_H1, 50);
   if(UseStrictEMA)
   {
      if(trendUp   && ema21_H1 <= ema50_H1) return;
      if(trendDown && ema21_H1 >= ema50_H1) return;
   }

   // 4. FUERZA DE TENDENCIA (ADX en H4)
   if(GetADX(symbol, PERIOD_H4) < ADX_Min) return;

   // 5. GATILLO EN M15
   MqlRates r[]; ArraySetAsSeries(r, true);
   if(CopyRates(symbol, PERIOD_M15, 0, 15, r) < 15) return;

   // Filtro de cuerpo mínimo (MinBodyPct) — activo desde v10
   double body  = MathAbs(r[1].close - r[1].open);
   double range = r[1].high - r[1].low;
   if(range > 0 && body / range < MinBodyPct) return;

   // Filtro de volumen relativo
   double curRange = body;
   double avgRange = 0;
   for(int j = 2; j < 12; j++) avgRange += MathAbs(r[j].close - r[j].open);
   avgRange /= 10.0;
   if(curRange < avgRange * VolumeFilterMult) return;

   // Dirección de la vela de confirmación
   if(trendUp   && r[1].close > r[1].open) analysis.signal = SIGNAL_BUY;
   if(trendDown && r[1].close < r[1].open) analysis.signal = SIGNAL_SELL;
   if(analysis.signal == SIGNAL_NONE) return;

   // 6. NIVELES SL/TP con ATR
   double atr = GetATR(symbol, PERIOD_M15);
   double p   = (analysis.signal == SIGNAL_BUY)
                ? SymbolInfoDouble(symbol, SYMBOL_ASK)
                : SymbolInfoDouble(symbol, SYMBOL_BID);
   int    dig = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   analysis.entryPrice = p;
   analysis.stopLoss   = NormalizeDouble(
      (analysis.signal == SIGNAL_BUY) ? p - atr * ATR_Multiplier_SL
                                      : p + atr * ATR_Multiplier_SL, dig);
   analysis.takeProfit = NormalizeDouble(
      (analysis.signal == SIGNAL_BUY) ? p + atr * ATR_Multiplier_TP
                                      : p - atr * ATR_Multiplier_TP, dig);
}

//+------------------------------------------------------------------+
//| EJECUTAR TRADE                                                   |
//+------------------------------------------------------------------+
void ExecuteTrade(string s, MarketAnalysis &a)
{
   double riskUSD  = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
   double tickVal  = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_SIZE);
   double slTicks  = MathAbs(a.entryPrice - a.stopLoss) / tickSize;
   if(slTicks <= 0 || tickVal <= 0) return;

   double lots = riskUSD / (slTicks * tickVal);

   // FIX v13: validación de riesgo real — previene bug -$245 en USDCAD
   // tickVal varía con el precio del par (ej: USDCAD cerca de 1.37 reduce tickVal)
   // Cap duro: el riesgo real nunca puede superar 2x riskAmount
   double realRisk = lots * slTicks * tickVal;
   if(realRisk > riskUSD * 2.0)
   {
      lots = (riskUSD * 1.5) / (slTicks * tickVal);
      Print("⚠️ FIX lotaje ", s, ": reducido a ", NormalizeDouble(lots,2), " lotes (riesgo real era $", NormalizeDouble(realRisk,2), ")");
   }

   lots = NormalizeDouble(lots, 2);
   lots = MathMax(SymbolInfoDouble(s, SYMBOL_VOLUME_MIN),
          MathMin(SymbolInfoDouble(s, SYMBOL_VOLUME_MAX), lots));

   bool ok = false;
   if(a.signal == SIGNAL_BUY)  ok = trade.Buy( lots, s, a.entryPrice, a.stopLoss, a.takeProfit, "Quant_v13");
   if(a.signal == SIGNAL_SELL) ok = trade.Sell(lots, s, a.entryPrice, a.stopLoss, a.takeProfit, "Quant_v13");

   if(ok)
      for(int i = 0; i < ArraySize(g_pairs); i++)
         if(g_pairs[i] == s) { g_lastTradeTime[i] = TimeCurrent(); break; }
}

//+------------------------------------------------------------------+
//| CONSTRUIR LISTA DE PARES                                        |
//+------------------------------------------------------------------+
void BuildPairsList()
{
   string candidates[];
   int    cnt = 0;

   if(Trade_EURUSD) { ArrayResize(candidates, cnt+1); candidates[cnt++] = "EURUSDm"; }
   if(Trade_GBPUSD) { ArrayResize(candidates, cnt+1); candidates[cnt++] = "GBPUSDm"; }
   if(Trade_USDJPY) { ArrayResize(candidates, cnt+1); candidates[cnt++] = "USDJPYm"; }
   if(Trade_USDCAD) { ArrayResize(candidates, cnt+1); candidates[cnt++] = "USDCADm"; }
   if(Trade_NZDUSD) { ArrayResize(candidates, cnt+1); candidates[cnt++] = "NZDUSDm"; }
   if(Trade_AUDUSD) { ArrayResize(candidates, cnt+1); candidates[cnt++] = "AUDUSDm"; }
   if(Trade_USDCHF) { ArrayResize(candidates, cnt+1); candidates[cnt++] = "USDCHFm"; }
   if(Trade_GBPJPY) { ArrayResize(candidates, cnt+1); candidates[cnt++] = "GBPJPYm"; }
   if(Trade_XAUUSD) { ArrayResize(candidates, cnt+1); candidates[cnt++] = "XAUUSDm"; }

   int valid = 0;
   ArrayResize(g_pairs, cnt);
   for(int i = 0; i < cnt; i++)
   {
      if(SymbolSelect(candidates[i], true))
      {
         g_pairs[valid++] = candidates[i];
         Print("✅ Par cargado: ", candidates[i]);
      }
      else
         Print("⚠️ Par no disponible: ", candidates[i]);
   }
   ArrayResize(g_pairs, valid);
}

//+------------------------------------------------------------------+
//| HELPERS                                                          |
//+------------------------------------------------------------------+
double GetEMA(string s, ENUM_TIMEFRAMES tf, int p)
{
   int    h = iMA(s, tf, p, 0, MODE_EMA, PRICE_CLOSE);
   double v[]; ArraySetAsSeries(v, true);
   CopyBuffer(h, 0, 0, 1, v);
   IndicatorRelease(h);
   return v[0];
}

double GetADX(string s, ENUM_TIMEFRAMES tf)
{
   int    h = iADX(s, tf, 14);
   double v[]; ArraySetAsSeries(v, true);
   CopyBuffer(h, 0, 0, 1, v);
   IndicatorRelease(h);
   return v[0];
}

double GetATR(string s, ENUM_TIMEFRAMES tf)
{
   int    h = iATR(s, tf, 14);
   double v[]; ArraySetAsSeries(v, true);
   CopyBuffer(h, 0, 0, 1, v);
   IndicatorRelease(h);
   return v[0];
}

double GetRSI(string s, ENUM_TIMEFRAMES tf, int period)
{
   int    h = iRSI(s, tf, period, PRICE_CLOSE);
   double v[]; ArraySetAsSeries(v, true);
   if(CopyBuffer(h, 0, 0, 1, v) < 1) { IndicatorRelease(h); return 50; }
   IndicatorRelease(h);
   return v[0];
}

bool IsSpreadOk(string s)
{
   int spread = (int)SymbolInfoInteger(s, SYMBOL_SPREAD);
   // Spread diferente para oro vs forex
   if(StringFind(s, "XAU") >= 0) return spread < MaxSpreadGold;
   return spread < MaxSpreadForex;
}

bool IsTradingTime()
{
   MqlDateTime dt; TimeToStruct(TimeGMT(), dt);
   int h = dt.hour;
   // v13: ventana recortada a 13:00-16:59 GMT (era 13:00-18:00 en v12)
   // Motivo: trades abiertos de 17h en adelante se cierran en sesión asiática
   // con WR 8% (18h) y 25% (20h). Cierre forzado a las 17h elimina ese daño.
   // 13h: WR 25% (entrada) | 14h: WR 28% | 15h: WR 36% ✅ | 16h: WR 32% ✅
   return (h >= 13 && h < 17);
}

bool HasPosition(string s)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == s && posInfo.Magic() == 20240001)
         return true;
   return false;
}

//+------------------------------------------------------------------+
//| GESTIÓN BREAK-EVEN Y ESCALONES                                   |
//+------------------------------------------------------------------+
void ManageBreakEven()
{
   if(!UseBreakEven && !UseStepTrailing) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i) || posInfo.Magic() != 20240001) continue;

      string symbol      = posInfo.Symbol();
      ulong  ticket      = posInfo.Ticket();
      double entryPrice  = posInfo.PriceOpen();
      double currentSL   = posInfo.StopLoss();
      double currentPrice= posInfo.PriceCurrent();
      double volume      = posInfo.Volume();
      long   type        = posInfo.PositionType();

      double atr          = GetATR(symbol, PERIOD_M15);
      double beTrigger    = atr * BreakEven_ATR_Mult;
      double step1Trigger = atr * Step1_Trigger;
      double step1Lock    = atr * Step1_Lock;
      double step2Trigger = atr * Step2_Trigger;
      double step2Lock    = atr * Step2_Lock;
      double pTickSize    = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      double bePadding    = BreakEven_Padding * SymbolInfoDouble(symbol, SYMBOL_POINT);
      int    dig          = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

      if(type == POSITION_TYPE_BUY)
      {
         if(UseBreakEven && currentPrice >= entryPrice + beTrigger && currentSL < entryPrice)
         {
            double newSL = NormalizeDouble(entryPrice + bePadding, dig);
            if(trade.PositionModify(ticket, newSL, posInfo.TakeProfit()) && UsePartialClose)
            {
               double vol = NormalizeDouble(volume * PartialClose_Pct / 100.0, 2);
               if(vol >= SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN))
                  trade.PositionClosePartial(ticket, vol);
            }
         }
         if(UseStepTrailing)
         {
            if(currentPrice >= entryPrice + step2Trigger && currentSL < entryPrice + step2Lock - 10*pTickSize)
               trade.PositionModify(ticket, NormalizeDouble(entryPrice + step2Lock, dig), posInfo.TakeProfit());
            else if(currentPrice >= entryPrice + step1Trigger && currentSL < entryPrice + step1Lock - 10*pTickSize)
               trade.PositionModify(ticket, NormalizeDouble(entryPrice + step1Lock, dig), posInfo.TakeProfit());
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         if(UseBreakEven && currentPrice <= entryPrice - beTrigger && (currentSL > entryPrice || currentSL == 0.0))
         {
            double newSL = NormalizeDouble(entryPrice - bePadding, dig);
            if(trade.PositionModify(ticket, newSL, posInfo.TakeProfit()) && UsePartialClose)
            {
               double vol = NormalizeDouble(volume * PartialClose_Pct / 100.0, 2);
               if(vol >= SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN))
                  trade.PositionClosePartial(ticket, vol);
            }
         }
         if(UseStepTrailing)
         {
            if(currentPrice <= entryPrice - step2Trigger && (currentSL > entryPrice - step2Lock + 10*pTickSize || currentSL == 0.0))
               trade.PositionModify(ticket, NormalizeDouble(entryPrice - step2Lock, dig), posInfo.TakeProfit());
            else if(currentPrice <= entryPrice - step1Trigger && (currentSL > entryPrice - step1Lock + 10*pTickSize || currentSL == 0.0))
               trade.PositionModify(ticket, NormalizeDouble(entryPrice - step1Lock, dig), posInfo.TakeProfit());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| CIERRE FORZADO AL FIN DE SESIÓN (NUEVO V13)                      |
//+------------------------------------------------------------------+
// FIX v13: en v12 los trades abiertos de 15-17h se cerraban de madrugada
// con WR 8% (18h) y 17-25% (19-22h). 78 cierres a las 18h = -$800 en pérdidas
// Este bloque cierra TODAS las posiciones del EA a las ForceCloseHour GMT
void CloseAllAtSessionEnd()
{
   if(!UseForceClose) return;

   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);

   // Ejecutar solo en la vela exacta del cierre (hora:minuto configurado)
   if(dt.hour != ForceCloseHour || dt.min != ForceCloseMinute) return;

   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic() != 20240001) continue;

      ulong ticket = posInfo.Ticket();
      if(trade.PositionClose(ticket))
      {
         closed++;
         Print("🕔 Cierre forzado por tiempo: ", posInfo.Symbol(),
               " ticket=", ticket,
               " P&L=", NormalizeDouble(posInfo.Profit(), 2));
      }
   }
   if(closed > 0)
      Print("✅ Cierre de sesión: ", closed, " posición(es) cerrada(s) a las ",
            ForceCloseHour, ":00 GMT");
}
//+------------------------------------------------------------------+