//+------------------------------------------------------------------+
//|                                         SessionBias_EURUSD.mq5  |
//|                         Multi-TF Trend + Pullback — EURUSD only  |
//|                         v1.2 — revert H1 confirm | PF 1.51 base  |
//|                                Sharpe 14.81 | DD 11.6% | WR 54%  |
//+------------------------------------------------------------------+
//
//  VENTANA DE OPERACIÓN (solo días hábiles):
//
//    UTC / GMT   →  13:00 – 16:59   Cierre forzado: 17:00 UTC
//    UTC-5 (EST) →  08:00 – 11:59   Cierre forzado: 12:00 EST
//
//  Cubre la apertura de Nueva York + overlap Londres-NY:
//  la ventana de mayor volumen y tendencia en EUR/USD.
//  Evita la sesión asiática (movimientos sin dirección en EUR).
//
//  HISTORIAL DE VERSIONES:
//  v1.0 — baseline: PF 1.51, Sharpe 14.81, WR 54%, DD 11.6%
//  v1.1 — DESCARTADO: filtro dirección vela H1 (PF cayó a 0.90)
//         Error: estrategia pullback entra cuando H1 aún baja —
//         exigir H1 alcista elimina los mejores setups.
//  v1.2 — revert a v1.0, UseH1CandleConfirm=false mantenido como opción
//
#property copyright "SessionBias EA"
#property version   "1.2"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
CPositionInfo posInfo;

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input double Version = 1.2;
input group "=== RIESGO ==="
input double RiskPercent      = 1.0;   // % del balance por trade
input double ATR_SL_Mult      = 1.2;   // SL = ATR × este valor
input double ATR_TP_Mult      = 2.5;   // TP = ATR × este valor

input group "=== GESTIÓN DE POSICIÓN ==="
input bool   UseBreakEven     = true;
input double BE_TriggerMult   = 1.5;   // Activar BE cuando precio avanza 1.5×ATR
input double BE_LockMult      = 0.5;   // SL se mueve a entrada + 0.5×ATR

input group "=== PROTECCIÓN DIARIA ==="
input bool   UseDailyLossLimit = true;
input double MaxDailyLossPct   = 2.0;  // Detiene trading si el día pierde > 2% balance

input group "=== CIRCUIT BREAKER ==="
input bool   UseCircuitBreaker  = true;
input int    MaxConsecLosses    = 4;
input int    CircuitBreakerHours = 48;

input group "=== CIERRE POR TIEMPO ==="
input bool   UseForceClose   = true;
input int    ForceCloseHour  = 17;     // Cierre forzado GMT (sesión Londres cierra)
input int    ForceCloseMinute = 0;

input group "=== FILTROS DE TENDENCIA ==="
input int    ADX_H4_Min      = 28;     // ADX en H4 mínimo para operar
input int    ADX_D1_Min      = 17;     // ADX en D1 mínimo (filtra mercados en rango)
input bool   UseADX_D1Filter = true;
input bool   UseStrictEMA    = true;   // EMA21 > EMA50 en H1 para confirmar dirección
// UseH1CandleConfirm=false (v1.1 lo activó y PF cayó de 1.51 a 0.90)
// Razón: estrategia pullback — la mejor entrada ocurre cuando H1 AÚN baja
// (el pullback activo). Exigir H1 alcista elimina esos setups y deja solo
// las entradas tardías de momentum, que tienen peor RR.
// Mantener como opción desactivada para referencia futura.
input bool   UseH1CandleConfirm = false;
input double MinBodyPct      = 0.6;    // Cuerpo mínimo de la vela gatillo (60% del rango)

input group "=== FILTROS DE MOMENTUM ==="
input bool   UseRSIFilter    = true;
input int    RSI_Period      = 14;
input int    RSI_Overbought  = 70;     // No comprar si RSI > 70
input int    RSI_Oversold    = 30;     // No vender si RSI < 30

input group "=== FILTROS DE SEGURIDAD ==="
input int    MinCandlesWait  = 8;      // Cooldown mínimo entre trades (en velas M15)
input double VolumeFilterMult = 1.1;   // Vela gatillo debe ser 1.1× el cuerpo promedio
input int    MaxSpreadPoints  = 30;    // Spread máximo permitido (3 pips en 5 dígitos)

//+------------------------------------------------------------------+
//| VARIABLES GLOBALES                                               |
//+------------------------------------------------------------------+
datetime g_lastBarTime   = 0;
datetime g_lastTradeTime = 0;

int      g_consecLosses       = 0;
datetime g_circuitBreakerUntil = 0;
ulong    g_lastProcessedDeal  = 0;

double   g_dayStartBalance = 0;
datetime g_currentDay      = 0;

//+------------------------------------------------------------------+
//| INICIALIZACIÓN                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   if(_Symbol != "EURUSD-T" && _Symbol != "EURUSDm" && _Symbol != "EURUSD")
      Print("⚠️ EA diseñado para EURUSD — símbolo actual: ", _Symbol);

   trade.SetExpertMagicNumber(20250001);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_currentDay      = StringToTime(TimeToString(TimeGMT(), TIME_DATE));

   Print("✅ SessionBias EURUSD v1.2 — símbolo: ", _Symbol,
         " | riesgo ", RiskPercent, "% | 13-17h UTC / 08-12h EST");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| TICK PRINCIPAL                                                    |
//+------------------------------------------------------------------+
void OnTick()
{
   if(UseForceClose) CloseAtSessionEnd();

   // Resetear balance de referencia al cambiar de día GMT
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
//| CIRCUIT BREAKER — detectar pérdidas                              |
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

      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != 20250001)       continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);

      if(profit < 0.0)
      {
         g_consecLosses++;
         if(g_consecLosses >= MaxConsecLosses)
         {
            g_circuitBreakerUntil = TimeCurrent() + CircuitBreakerHours * 3600;
            g_consecLosses = 0;
            Print("⛔ Circuit breaker — ", MaxConsecLosses, " pérdidas seguidas.",
                  " Pausa hasta: ", TimeToString(g_circuitBreakerUntil));
         }
      }
      else
      {
         g_consecLosses = 0;
      }
   }

   if(maxTicket > g_lastProcessedDeal)
      g_lastProcessedDeal = maxTicket;
}

//+------------------------------------------------------------------+
//| SEÑAL DE ENTRADA — retorna +1 (buy), -1 (sell), 0 (nada)        |
//+------------------------------------------------------------------+
int GetSignal()
{
   // 1. TENDENCIA MACRO: H4 vs EMA200 + vela D1 + EMA50 D1
   double closeD1  = iClose(_Symbol, PERIOD_D1, 0);
   double openD1   = iOpen(_Symbol,  PERIOD_D1, 0);
   double ema200H4 = GetEMA(PERIOD_H4, 200);
   double ema50D1  = GetEMA(PERIOD_D1, 50);
   double closeH4  = iClose(_Symbol, PERIOD_H4, 1);

   bool trendUp   = (closeH4 > ema200H4) && (closeD1 > openD1) && (closeD1 > ema50D1);
   bool trendDown = (closeH4 < ema200H4) && (closeD1 < openD1) && (closeD1 < ema50D1);
   if(!trendUp && !trendDown) return 0;

   // 2. RSI M15 — no entrar en extremos
   if(UseRSIFilter)
   {
      double rsi = GetRSI();
      if(trendUp   && rsi > RSI_Overbought) return 0;
      if(trendDown && rsi < RSI_Oversold)   return 0;
   }

   // 3. EMA21 vs EMA50 en H1
   if(UseStrictEMA)
   {
      double ema21H1 = GetEMA(PERIOD_H1, 21);
      double ema50H1 = GetEMA(PERIOD_H1, 50);
      if(trendUp   && ema21H1 <= ema50H1) return 0;
      if(trendDown && ema21H1 >= ema50H1) return 0;
   }

   // 3b. CONFIRMACIÓN VELA H1 — la vela H1 anterior debe cerrar en la dirección del trade
   // Completa la cadena D1→H4→H1→M15: sin este filtro se entra en M15 alcista
   // mientras H1 aún está bajando (pullback no terminado → SL inmediato)
   if(UseH1CandleConfirm)
   {
      double h1Close = iClose(_Symbol, PERIOD_H1, 1);
      double h1Open  = iOpen( _Symbol, PERIOD_H1, 1);
      if(trendUp   && h1Close <= h1Open) return 0;
      if(trendDown && h1Close >= h1Open) return 0;
   }

   // 4. ADX H4 — fuerza de tendencia
   if(GetADX(PERIOD_H4) < ADX_H4_Min) return 0;

   // 4b. ADX D1 — filtro de rango macro
   if(UseADX_D1Filter && GetADX(PERIOD_D1) < ADX_D1_Min) return 0;

   // 5. VELA GATILLO EN M15
   MqlRates r[]; ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, PERIOD_M15, 0, 15, r) < 15) return 0;

   double body  = MathAbs(r[1].close - r[1].open);
   double range = r[1].high - r[1].low;
   if(range > 0 && body / range < MinBodyPct) return 0;

   // Cuerpo de la vela gatillo vs promedio de 10 velas previas
   double avgBody = 0;
   for(int j = 2; j < 12; j++) avgBody += MathAbs(r[j].close - r[j].open);
   avgBody /= 10.0;
   if(body < avgBody * VolumeFilterMult) return 0;

   if(trendUp   && r[1].close > r[1].open) return  1;
   if(trendDown && r[1].close < r[1].open) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| EJECUTAR TRADE                                                   |
//+------------------------------------------------------------------+
void ExecuteTrade(int signal)
{
   double atr      = GetATR(PERIOD_M15);
   double price    = (signal > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    dig      = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double sl       = NormalizeDouble(price - signal * atr * ATR_SL_Mult, dig);
   double tp       = NormalizeDouble(price + signal * atr * ATR_TP_Mult, dig);

   double riskUSD  = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double slTicks  = MathAbs(price - sl) / tickSize;
   if(slTicks <= 0 || tickVal <= 0) return;

   double lots = NormalizeDouble(riskUSD / (slTicks * tickVal), 2);
   lots = MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
          MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), lots));

   bool ok = (signal > 0) ? trade.Buy( lots, _Symbol, price, sl, tp, "SB_EUR_v1")
                          : trade.Sell(lots, _Symbol, price, sl, tp, "SB_EUR_v1");

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
      if(!posInfo.SelectByIndex(i) || posInfo.Magic() != 20250001) continue;

      double entry  = posInfo.PriceOpen();
      double curSL  = posInfo.StopLoss();
      double curPx  = posInfo.PriceCurrent();
      double atr    = GetATR(PERIOD_M15);
      double trigger = atr * BE_TriggerMult;
      double lockDist = atr * BE_LockMult;
      int    dig    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      ulong  ticket = posInfo.Ticket();

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
//| CIERRE FORZADO AL FIN DE SESIÓN                                  |
//+------------------------------------------------------------------+
void CloseAtSessionEnd()
{
   MqlDateTime dt; TimeToStruct(TimeGMT(), dt);
   if(dt.hour != ForceCloseHour || dt.min != ForceCloseMinute) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i) || posInfo.Magic() != 20250001) continue;
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
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == 20250001)
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

double GetADX(ENUM_TIMEFRAMES tf)
{
   int    h = iADX(_Symbol, tf, 14);
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

double GetRSI()
{
   int    h = iRSI(_Symbol, PERIOD_M15, RSI_Period, PRICE_CLOSE);
   double v[]; ArraySetAsSeries(v, true);
   if(CopyBuffer(h, 0, 0, 1, v) < 1) { IndicatorRelease(h); return 50; }
   IndicatorRelease(h);
   return v[0];
}
//+------------------------------------------------------------------+
