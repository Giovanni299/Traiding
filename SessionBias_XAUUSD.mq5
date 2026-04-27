//+------------------------------------------------------------------+
//|                                          SessionBias_XAUUSD.mq5  |
//|              Multi-TF Trend + Session Breakout — Gold Only       |
//|              v2.0 — breakout de sesión vs pullback M15 fallido   |
//+------------------------------------------------------------------+
//
//  VENTANA DE OPERACIÓN (solo días hábiles):
//
//    UTC / GMT   →  13:00 – 16:59   Cierre forzado: 17:00 UTC
//    UTC-5 (EST) →  08:00 – 11:59   Cierre forzado: 12:00 EST
//
//  Mismo overlap Londres-NY que EURUSD — las 3 horas de mayor volumen.
//
//  POR QUÉ BREAKOUT Y NO PULLBACK PARA EL ORO:
//  v1.0 usó pullback M15 (mismo enfoque que EURUSD): PF 0.83, -$1,673
//  El oro NO hace pullbacks ordenados en M15. Consolida durante horas
//  y luego ROMPE con una vela grande. El patrón es:
//    1. Tendencia macro alcista (D1 > EMA50, H4 > EMA200)
//    2. Consolidación en rango estrecho durante N velas
//    3. Ruptura: M15 cierra por encima del máximo de las últimas N velas
//    4. Ese breakout confirma la reanudación del trend → entrar
//  Este patrón captura las explosiones del oro que generan los grandes
//  movimientos. Con pullback, se entra demasiado pronto o en ruido.
//
//  HISTORIAL:
//  v1.0 — pullback M15 + EMA21: PF 0.83, WR 37%, -$1,673 (descartado)
//         171 trades = demasiados. El M15 es muy ruidoso para oro.
//  v2.0 — breakout de sesión: breakout de N velas + filtros macro
//
#property copyright "SessionBias EA"
#property version   "2.0"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
CPositionInfo posInfo;

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input double Version = 2.0;

input group "=== RIESGO ==="
input double RiskPercent    = 1.0;
input double ATR_SL_Mult    = 1.5;   // SL debajo del breakout level + ATR buffer
input double ATR_TP_Mult    = 2.5;   // TP alcanzable dentro de la sesión (3.0 era demasiado)

input group "=== GESTIÓN DE POSICIÓN ==="
input bool   UseBreakEven   = true;
input double BE_TriggerMult = 1.5;   // Bajado de 2.0 — el TP también bajó a 2.5
input double BE_LockMult    = 0.7;   // Lock-in intermedio para oro

input group "=== PROTECCIÓN DIARIA ==="
input bool   UseDailyLossLimit = true;
input double MaxDailyLossPct   = 2.0;

input group "=== CIRCUIT BREAKER ==="
input bool   UseCircuitBreaker   = true;
input int    MaxConsecLosses     = 3;
input int    CircuitBreakerHours = 48;

input group "=== CIERRE POR TIEMPO ==="
input bool   UseForceClose    = true;
input int    ForceCloseHour   = 17;
input int    ForceCloseMinute = 0;

input group "=== FILTROS DE TENDENCIA ==="
input int    ADX_H4_Min      = 28;    // Subido de 25 → 28, igual que EURUSD
input int    ADX_D1_Min      = 20;
input bool   UseADX_D1Filter = true;
input bool   UseStrictEMA    = true;  // EMA21 > EMA50 en H1

input group "=== BREAKOUT ENTRY ==="
// El oro consolida y rompe — no pullea ordenadamente como EURUSD en M15
// Entry: M15 cierra por encima del máximo de las últimas N velas (breakout)
// Confirma que el precio salió del rango y retoma la tendencia macro
input int    BreakoutPeriod  = 10;   // Mirar los últimos 10 M15 (2.5 horas de consolidación)
input double MinBreakoutATR  = 0.3;  // Breakout mínimo de 0.3×ATR sobre el máximo (evita falsas rupturas)

input group "=== FILTROS DE MOMENTUM ==="
input bool   UseRSIFilter   = true;
input int    RSI_Period      = 14;
input int    RSI_Overbought  = 72;
input int    RSI_Oversold    = 28;

input group "=== FILTROS DE SEGURIDAD ==="
input int    MinCandlesWait  = 8;
input int    MaxSpreadPoints = 50;

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
   string sym = _Symbol;
   if(StringFind(sym, "XAU") < 0 && StringFind(sym, "GOLD") < 0)
      Print("⚠️ EA diseñado para XAUUSD — símbolo actual: ", sym);

   trade.SetExpertMagicNumber(20250002);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_currentDay      = StringToTime(TimeToString(TimeGMT(), TIME_DATE));

   Print("✅ SessionBias XAUUSD v2.0 — símbolo: ", sym,
         " | riesgo ", RiskPercent, "% | 13-17h UTC / 08-12h EST | breakout ", BreakoutPeriod, " velas");
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

      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != 20250002)       continue;
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
         g_consecLosses = 0;
   }

   if(maxTicket > g_lastProcessedDeal)
      g_lastProcessedDeal = maxTicket;
}

//+------------------------------------------------------------------+
//| SEÑAL: +1 buy, -1 sell, 0 sin señal                             |
//+------------------------------------------------------------------+
int GetSignal()
{
   // 1. TENDENCIA MACRO — D1 + H4 + EMA50 D1
   double closeD1  = iClose(_Symbol, PERIOD_D1, 0);
   double openD1   = iOpen( _Symbol, PERIOD_D1, 0);
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

   // 4. ADX H4 y D1
   if(GetADX(PERIOD_H4) < ADX_H4_Min) return 0;
   if(UseADX_D1Filter && GetADX(PERIOD_D1) < ADX_D1_Min) return 0;

   // 5. BREAKOUT DE SESIÓN EN M15
   // El oro no pullea ordenadamente: consolida N velas y luego ROMPE
   // Entry: última vela M15 cerró por encima del máximo de las N velas previas (buy)
   //        o por debajo del mínimo de las N velas previas (sell)
   // Esto confirma que el precio salió del rango y retoma la tendencia macro
   int   lookback = BreakoutPeriod + 2;
   MqlRates r[]; ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, PERIOD_M15, 0, lookback, r) < lookback) return 0;

   double atr = GetATR(PERIOD_M15);
   double minBreak = atr * MinBreakoutATR;

   // Calcular máximo y mínimo de las N velas anteriores a la vela de señal (r[1])
   double highN = r[2].high, lowN = r[2].low;
   for(int j = 2; j <= BreakoutPeriod; j++)
   {
      if(r[j].high > highN) highN = r[j].high;
      if(r[j].low  < lowN)  lowN  = r[j].low;
   }

   bool breakoutUp   = trendUp   && (r[1].close > highN + minBreak) && (r[1].close > r[1].open);
   bool breakoutDown = trendDown && (r[1].close < lowN  - minBreak) && (r[1].close < r[1].open);

   if(breakoutUp)   return  1;
   if(breakoutDown) return -1;
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

   // Redondear hacia abajo al step del broker — nunca superar el 1% de riesgo
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lots = MathFloor((riskUSD / (slTicks * tickVal)) / step) * step;
   lots = NormalizeDouble(lots, 2);
   lots = MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
          MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), lots));

   bool ok = (signal > 0) ? trade.Buy( lots, _Symbol, price, sl, tp, "SB_XAU_v2")
                          : trade.Sell(lots, _Symbol, price, sl, tp, "SB_XAU_v2");

   if(ok)
      Print("📈 Trade abierto: ", (signal > 0 ? "BUY" : "SELL"),
            " lots=", lots, " SL=", sl, " TP=", tp,
            " ATR=", NormalizeDouble(atr, dig));

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
      if(!posInfo.SelectByIndex(i) || posInfo.Magic() != 20250002) continue;

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
      if(!posInfo.SelectByIndex(i) || posInfo.Magic() != 20250002) continue;
      ulong ticket = posInfo.Ticket();
      if(trade.PositionClose(ticket))
         Print("🕔 Cierre sesión XAU: P&L=", NormalizeDouble(posInfo.Profit(), 2));
   }
}

//+------------------------------------------------------------------+
//| HELPERS                                                          |
//+------------------------------------------------------------------+
bool IsTradingTime()
{
   MqlDateTime dt; TimeToStruct(TimeGMT(), dt);
   // v2.0: misma ventana que EURUSD — el overlap NY es el período de mayor dirección
   return (dt.hour >= 13 && dt.hour < 17);
}

bool IsSpreadOk()
{
   return (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) < MaxSpreadPoints;
}

bool HasPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == 20250002)
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
         Print("🛑 Daily loss limit XAU: -$", NormalizeDouble(loss, 2), " — sin entradas hoy");
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
