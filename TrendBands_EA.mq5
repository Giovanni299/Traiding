//+------------------------------------------------------------------+
//|                                              TrendBands_EA.mq5  |
//|              EMA Band Trend + AO Confirmation — Multi-Symbol    |
//|              v1.0 — funciona en forex, oro, índices             |
//+------------------------------------------------------------------+
//
//  ESTRATEGIA (basada en video):
//  1. TENDENCIA  — banda de EMAs alineadas en H4 (EMA20 > EMA50 > EMA200)
//  2. PULLBACK   — precio regresa cerca de la EMA20_H4 (soporte dinámico)
//  3. CONFIRMACIÓN — Awesome Oscillator en H1 confirma momentum
//  4. ENTRADA    — vela M15 fuerte en dirección del trend
//
//  POR QUÉ ES MEJOR QUE EL PULLBACK SIMPLE:
//  El filtro de PROXIMIDAD A LA BANDA es la clave: solo entra cuando
//  el precio pullbackeó hasta la EMA20_H4 y el AO confirma que el
//  momentum vuelve. Evita entrar en medio del movimiento (tarde)
//  o demasiado lejos de la banda (ruido).
//
//  VENTANA DE OPERACIÓN:
//    UTC / GMT   →  13:00 – 16:59   Cierre forzado: 17:00 UTC
//    UTC-5 (EST) →  08:00 – 11:59   Cierre forzado: 12:00 EST
//
//  HISTORIAL:
//  v1.0 — baseline multi-símbolo
//
#property copyright "TrendBands EA"
#property version   "1.0"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
CPositionInfo posInfo;

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input double Version = 1.0;

input group "=== RIESGO ==="
input double RiskPercent   = 1.0;   // 1% del balance por trade
input double ATR_SL_Mult   = 1.2;   // SL = 1.2 × ATR(M15)
input double ATR_TP_Mult   = 2.5;   // TP = 2.5 × ATR(M15) — RR mínimo 1:2

input group "=== BANDA EMA H4 ==="
// Los 3 períodos crean la "banda" — cuando están alineados el trend es fuerte
input int    EMA_Fast      = 20;    // EMA rápida — precio vuelve a ella en pullback
input int    EMA_Mid       = 50;    // EMA media
input int    EMA_Slow      = 200;   // EMA lenta — tendencia de largo plazo
// Umbral de proximidad: precio debe estar dentro de N×ATR(H4) de la EMA fast
// Demasiado amplio = entradas tardías. Demasiado estricto = pocas señales.
input double BandProximity = 1.5;   // N×ATR(H4) máximo desde EMA_Fast para entrar

input group "=== CONFIRMACIÓN AWESOME OSCILLATOR ==="
// AO = SMA5 - SMA34 de los precios medios. Positivo+subiendo = momentum alcista.
// Se usa en H1 para filtrar el ruido del M15 pero no tan lento como H4.
input bool   UseAOFilter   = true;
// true = AO debe cruzar cero en la misma dirección del trade (señal fuerte)
// false = basta con que AO esté en la dirección correcta y subiendo/bajando
input bool   AORequireCross = false;

input group "=== GESTIÓN DE POSICIÓN ==="
input bool   UseBreakEven   = true;
input double BE_TriggerMult = 1.5;  // Mover SL cuando el precio avanza 1.5×ATR
input double BE_LockMult    = 0.5;  // SL se fija en entrada + 0.5×ATR

input group "=== PROTECCIÓN DIARIA ==="
input bool   UseDailyLossLimit = true;
input double MaxDailyLossPct   = 2.0;

input group "=== CIRCUIT BREAKER ==="
input bool   UseCircuitBreaker   = true;
input int    MaxConsecLosses     = 4;
input int    CircuitBreakerHours = 48;

input group "=== CIERRE POR TIEMPO ==="
input bool   UseForceClose    = true;
input int    ForceCloseHour   = 17;
input int    ForceCloseMinute = 0;

input group "=== FILTROS DE ENTRADA ==="
input double MinBodyPct      = 0.6;   // Cuerpo mínimo vela M15 (60% del rango)
input double VolumeFilterMult = 1.0;  // Cuerpo mínimo vs promedio de 10 velas
input int    MinCandlesWait  = 6;     // Cooldown entre trades (en velas M15)
input int    MaxSpreadPoints = 30;    // Spread máximo — ajustar por símbolo

//+------------------------------------------------------------------+
//| VARIABLES GLOBALES                                               |
//+------------------------------------------------------------------+
datetime g_lastBarTime        = 0;
datetime g_lastTradeTime      = 0;
int      g_consecLosses       = 0;
datetime g_circuitBreakerUntil = 0;
ulong    g_lastProcessedDeal  = 0;
double   g_dayStartBalance    = 0;
datetime g_currentDay         = 0;

//+------------------------------------------------------------------+
//| INICIALIZACIÓN                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(20250010);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_currentDay      = StringToTime(TimeToString(TimeGMT(), TIME_DATE));

   Print("✅ TrendBands EA v1.0 — símbolo: ", _Symbol,
         " | banda EMA", EMA_Fast, "/", EMA_Mid, "/", EMA_Slow,
         " | riesgo ", RiskPercent, "%");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| TICK PRINCIPAL                                                    |
//+------------------------------------------------------------------+
void OnTick()
{
   if(UseForceClose) CloseAtSessionEnd();

   datetime today = StringToTime(TimeToString(TimeGMT(), TIME_DATE));
   if(today > g_currentDay)
   {
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_currentDay      = today;
   }

   ManageBreakEven();

   if(UseCircuitBreaker && TimeCurrent() < g_circuitBreakerUntil) return;
   if(UseDailyLossLimit && IsDailyLossExceeded())                  return;
   if(TimeCurrent() - g_lastTradeTime < MinCandlesWait * 15 * 60)  return;

   datetime curBar = iTime(_Symbol, PERIOD_M15, 0);
   if(curBar == g_lastBarTime) return;
   g_lastBarTime = curBar;

   if(!IsTradingTime() || !IsSpreadOk() || HasPosition()) return;

   int signal = GetSignal();
   if(signal != 0) ExecuteTrade(signal);
}

//+------------------------------------------------------------------+
//| CIRCUIT BREAKER                                                  |
//+------------------------------------------------------------------+
void OnTrade()
{
   if(!UseCircuitBreaker) return;

   HistorySelect(TimeCurrent() - 120, TimeCurrent());
   int   total     = HistoryDealsTotal();
   ulong maxTicket = g_lastProcessedDeal;

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket <= g_lastProcessedDeal) break;
      if(ticket > maxTicket) maxTicket = ticket;

      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != 20250010)       continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      if(profit < 0.0)
      {
         g_consecLosses++;
         if(g_consecLosses >= MaxConsecLosses)
         {
            g_circuitBreakerUntil = TimeCurrent() + CircuitBreakerHours * 3600;
            g_consecLosses = 0;
            Print("⛔ Circuit breaker — ", MaxConsecLosses, " pérdidas.",
                  " Pausa hasta: ", TimeToString(g_circuitBreakerUntil));
         }
      }
      else
         g_consecLosses = 0;
   }

   if(maxTicket > g_lastProcessedDeal)
      g_lastProcessedDeal = maxTicket;
}

//+------------------------------------------------------------------+
//| SEÑAL PRINCIPAL: +1 buy, -1 sell, 0 nada                        |
//+------------------------------------------------------------------+
int GetSignal()
{
   // ── PASO 1: BANDA EMA H4 — tendencia macro ──────────────────────
   // Las 3 EMAs deben estar alineadas en cascada (banda ordenada)
   double emaFast_H4 = GetEMA(PERIOD_H4, EMA_Fast);
   double emaMid_H4  = GetEMA(PERIOD_H4, EMA_Mid);
   double emaSlow_H4 = GetEMA(PERIOD_H4, EMA_Slow);
   double closeH4    = iClose(_Symbol, PERIOD_H4, 1);

   bool bandUp   = (emaFast_H4 > emaMid_H4) && (emaMid_H4 > emaSlow_H4);
   bool bandDown = (emaFast_H4 < emaMid_H4) && (emaMid_H4 < emaSlow_H4);
   if(!bandUp && !bandDown) return 0; // banda en rango — no operar

   // Precio debe estar del lado correcto de la banda
   if(bandUp   && closeH4 < emaSlow_H4) return 0;
   if(bandDown && closeH4 > emaSlow_H4) return 0;

   // ── PASO 2: PROXIMIDAD A LA BANDA ───────────────────────────────
   // El precio debe haber pullbackeado hasta la EMA_Fast (soporte/resistencia dinámica)
   // Si está demasiado lejos, el pullback no llegó a la banda → no es el setup
   double atrH4      = GetATR(PERIOD_H4);
   double distBand   = MathAbs(closeH4 - emaFast_H4);
   if(distBand > BandProximity * atrH4) return 0;

   // ── PASO 3: AWESOME OSCILLATOR en H1 — confirmación ─────────────
   // AO mide momentum: positivo+subiendo = compradores activos
   // Negativo+bajando = vendedores activos
   if(UseAOFilter)
   {
      double ao0 = GetAO(PERIOD_H1, 0); // barra actual cerrada (H1)
      double ao1 = GetAO(PERIOD_H1, 1); // barra anterior
      double ao2 = GetAO(PERIOD_H1, 2);

      if(AORequireCross)
      {
         // Señal fuerte: AO cruzó la línea cero en la dirección del trade
         bool aoCrossBull = (ao0 > 0) && (ao1 <= 0); // cruzó de negativo a positivo
         bool aoCrossBear = (ao0 < 0) && (ao1 >= 0); // cruzó de positivo a negativo
         if(bandUp   && !aoCrossBull) return 0;
         if(bandDown && !aoCrossBear) return 0;
      }
      else
      {
         // Señal normal: AO en la zona correcta y con momentum en esa dirección
         bool aoConfirmBull = (ao0 > 0) && (ao0 > ao1); // positivo y subiendo
         bool aoConfirmBear = (ao0 < 0) && (ao0 < ao1); // negativo y bajando
         if(bandUp   && !aoConfirmBull) return 0;
         if(bandDown && !aoConfirmBear) return 0;
      }
   }

   // ── PASO 4: VELA GATILLO EN M15 ─────────────────────────────────
   // Vela de confirmación fuerte en dirección del trend
   MqlRates r[]; ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, PERIOD_M15, 0, 15, r) < 15) return 0;

   double body  = MathAbs(r[1].close - r[1].open);
   double range = r[1].high - r[1].low;
   if(range > 0 && body / range < MinBodyPct) return 0;

   double avgBody = 0;
   for(int j = 2; j < 12; j++) avgBody += MathAbs(r[j].close - r[j].open);
   avgBody /= 10.0;
   if(avgBody > 0 && body < avgBody * VolumeFilterMult) return 0;

   if(bandUp   && r[1].close > r[1].open) return  1;
   if(bandDown && r[1].close < r[1].open) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| EJECUTAR TRADE                                                   |
//+------------------------------------------------------------------+
void ExecuteTrade(int signal)
{
   double atr     = GetATR(PERIOD_M15);
   double price   = (signal > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                 : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    dig     = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double sl      = NormalizeDouble(price - signal * atr * ATR_SL_Mult, dig);
   double tp      = NormalizeDouble(price + signal * atr * ATR_TP_Mult, dig);

   double riskUSD  = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double slTicks  = MathAbs(price - sl) / tickSize;
   if(slTicks <= 0 || tickVal <= 0) return;

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lots = MathFloor((riskUSD / (slTicks * tickVal)) / step) * step;
   lots = NormalizeDouble(lots, 2);
   lots = MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
          MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), lots));

   bool ok = (signal > 0) ? trade.Buy( lots, _Symbol, price, sl, tp, "TB_v1")
                          : trade.Sell(lots, _Symbol, price, sl, tp, "TB_v1");

   if(ok)
      Print("📊 TrendBands entry: ", (signal > 0 ? "BUY" : "SELL"),
            " lots=", lots, " SL=", sl, " TP=", tp);

   if(ok) g_lastTradeTime = TimeCurrent();
}

//+------------------------------------------------------------------+
//| BREAK-EVEN LOCK-IN                                               |
//+------------------------------------------------------------------+
void ManageBreakEven()
{
   if(!UseBreakEven) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i) || posInfo.Magic() != 20250010) continue;

      double entry    = posInfo.PriceOpen();
      double curSL    = posInfo.StopLoss();
      double curPx    = posInfo.PriceCurrent();
      double atr      = GetATR(PERIOD_M15);
      double trigger  = atr * BE_TriggerMult;
      double lockDist = atr * BE_LockMult;
      int    dig      = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      ulong  ticket   = posInfo.Ticket();

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
      {
         double lockSL = entry + lockDist;
         if(curPx >= entry + trigger && curSL < lockSL)
            trade.PositionModify(ticket, NormalizeDouble(lockSL, dig), posInfo.TakeProfit());
      }
      else
      {
         double lockSL = entry - lockDist;
         if(curPx <= entry - trigger && (curSL > lockSL || curSL == 0.0))
            trade.PositionModify(ticket, NormalizeDouble(lockSL, dig), posInfo.TakeProfit());
      }
   }
}

//+------------------------------------------------------------------+
//| CIERRE FORZADO                                                   |
//+------------------------------------------------------------------+
void CloseAtSessionEnd()
{
   MqlDateTime dt; TimeToStruct(TimeGMT(), dt);
   if(dt.hour != ForceCloseHour || dt.min != ForceCloseMinute) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i) || posInfo.Magic() != 20250010) continue;
      ulong ticket = posInfo.Ticket();
      if(trade.PositionClose(ticket))
         Print("🕔 Cierre sesión: P&L=", NormalizeDouble(posInfo.Profit(), 2));
   }
}

//+------------------------------------------------------------------+
//| HELPERS                                                          |
//+------------------------------------------------------------------+
bool IsTradingTime()
{
   MqlDateTime dt; TimeToStruct(TimeGMT(), dt);
   return (dt.hour >= 13 && dt.hour < 17);
}

bool IsSpreadOk()
{
   return (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) < MaxSpreadPoints;
}

bool HasPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == 20250010)
         return true;
   return false;
}

bool IsDailyLossExceeded()
{
   double loss  = g_dayStartBalance - AccountInfoDouble(ACCOUNT_BALANCE);
   double limit = g_dayStartBalance * MaxDailyLossPct / 100.0;
   if(loss >= limit)
   {
      static datetime lastWarn = 0;
      if(TimeCurrent() - lastWarn > 3600)
      {
         Print("🛑 Daily loss limit: -$", NormalizeDouble(loss, 2), " — sin entradas hoy");
         lastWarn = TimeCurrent();
      }
      return true;
   }
   return false;
}

double GetEMA(ENUM_TIMEFRAMES tf, int period)
{
   int    h = iMA(_Symbol, tf, period, 0, MODE_EMA, PRICE_CLOSE);
   double v[]; ArraySetAsSeries(v, true);
   CopyBuffer(h, 0, 0, 1, v);
   IndicatorRelease(h);
   return v[0];
}

double GetATR(ENUM_TIMEFRAMES tf)
{
   int    h = iATR(_Symbol, tf, 14);
   double v[]; ArraySetAsSeries(v, true);
   CopyBuffer(h, 0, 0, 1, v);
   IndicatorRelease(h);
   return v[0];
}

// Awesome Oscillator = SMA5 - SMA34 de precios medios (H+L)/2
double GetAO(ENUM_TIMEFRAMES tf, int shift)
{
   int    h = iAO(_Symbol, tf);
   double v[]; ArraySetAsSeries(v, true);
   if(CopyBuffer(h, 0, shift, 1, v) < 1) { IndicatorRelease(h); return 0; }
   IndicatorRelease(h);
   return v[0];
}
//+------------------------------------------------------------------+
