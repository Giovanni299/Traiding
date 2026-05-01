//+------------------------------------------------------------------+
//|                                         SessionBias_USDJPY.mq5  |
//|              Trend Breakout + AO Confirmation -- USD/JPY Only   |
//|              v1.3 -- H1 EMA alignment filter (EMA21 vs EMA50)   |
//+------------------------------------------------------------------+
//
//  VENTANA DE OPERACION (solo dias habiles):
//
//    UTC / GMT   ->  07:00 - 12:59   Cierre forzado: 13:00 UTC
//    UTC-5 (EST) ->  02:00 - 07:59   Cierre forzado: 08:00 EST
//
//  POR QUE 07-13h Y NO 13-17h:
//  v1.0 uso 13-17h (mismo que EURUSD) -> PF 0.83, -$421
//  El JPY hace su movimiento ANTES de que lleguen los datos de EEUU.
//  07-13h UTC captura: cierre de Tokio + apertura Londres + pre-NY.
//  Ese bloque es cuando el JPY tiene direccion propia, no reaccion.
//  13-17h el movimiento ya ocurrio -- entramos tarde al breakout.
//
//  USDJPY EN 2025: tendencia bajista fuerte (158 -> 141)
//  impulsada por expectativas de subida de tasas BOJ + debilidad USD.
//
//  POR QUE BREAKOUT + AO (y no pullback):
//  El pullback simple fallo (WR 27%) porque el JPY tiene spikes
//  violentos por intervencion del BOJ -- los SL ajustados se activan.
//  USDJPY consolida varias horas y luego ROMPE con fuerza (mismo patron
//  que el oro, que con breakout paso de PF 0.83 a PF 1.20).
//  El AO confirma que el momentum ya empezo -- evita falsas rupturas.
//
//  AVISO DE RIESGO:
//  El BOJ puede intervenir sin previo aviso (+200 pips en segundos).
//  El daily loss limit 2% y circuit breaker protegen el portfolio.
//  No operar dias con decisiones del BOJ o NFP de EEUU.
//
//  HISTORIAL:
//  v1.0 -- 13-17h UTC: PF 0.83, -$421 (llegaba tarde al movimiento)
//  v1.1 -- 07-13h UTC: PF 1.17, +$561 -- SHORT WR 58% / LONG WR 45%
//  v1.2 -- filtro W1 EMA20: PF 1.06, +$200 -- REGRESION
//          Solo elimino 2 longs (44->42). EMA20 W1 era lagging y estaba
//          por debajo del precio a inicio de 2025 (JPY venia de subida 2024).
//          Ademas bajo SHORT WR 58%->54% -- el filtro W1 bloqueaba shorts buenos.
//  v1.3 -- filtro H1 EMA21 vs EMA50 (UseH1EMAAlign=true)
//          En downtrend sostenido: EMA21(H1) < EMA50(H1) casi todo el año.
//          Bloquea longs cuando H1 esta bajista -- mucho mas preciso que W1.
//          Responde en horas, no semanas. W1 vuelve a default=false.
//
#property copyright "SessionBias EA"
#property version   "1.3"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
CPositionInfo posInfo;

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input double Version = 1.3;

input group "=== RIESGO ==="
input double RiskPercent   = 1.0;
input double ATR_SL_Mult   = 1.4;   // Mas amplio que EURUSD -- JPY tiene spikes de intervencion
input double ATR_TP_Mult   = 2.5;

input group "=== GESTION DE POSICION ==="
input bool   UseBreakEven   = true;
input double BE_TriggerMult = 1.5;
input double BE_LockMult    = 0.5;

input group "=== PROTECCION DIARIA ==="
input bool   UseDailyLossLimit = true;
input double MaxDailyLossPct   = 2.0;

input group "=== CIRCUIT BREAKER ==="
input bool   UseCircuitBreaker   = true;
input int    MaxConsecLosses     = 3;   // Estricto -- el JPY puede romper rachas rapido
input int    CircuitBreakerHours = 48;

input group "=== CIERRE POR TIEMPO ==="
input bool   UseForceClose    = true;
input int    ForceCloseHour   = 13;   // v1.1: cierre a 13h -- antes de datos EEUU
input int    ForceCloseMinute = 0;

input group "=== FILTROS DE TENDENCIA MACRO ==="
input int    ADX_H4_Min      = 28;
input int    ADX_D1_Min      = 17;
input bool   UseADX_D1Filter = true;
// v1.3: H1 EMA alignment -- mas rapido y preciso que el W1 EMA20 de v1.2
// Para longs: requiere EMA21(H1) > EMA50(H1) -- H1 en tendencia alcista
// Para shorts: requiere EMA21(H1) < EMA50(H1) -- H1 en tendencia bajista
// En downtrend sostenido, EMA21 < EMA50 casi todo el año -> longs bloqueados
input bool   UseH1EMAAlign   = true;
// v1.2: W1 filter -- desactivado (regresion: solo elimino 2 longs, bajo short WR)
input bool   UseWeeklyFilter = false;

input group "=== BREAKOUT + AO ==="
// Breakout: el cierre M15 supera el maximo/minimo de las N velas previas
// Captura el momento en que el JPY rompe el rango de consolidacion
input int    BreakoutPeriod  = 8;    // 2h de consolidacion (vs 10 en Gold -- JPY rompe antes)
input double MinBreakoutATR  = 0.25; // Ruptura minima 0.25xATR (Gold uso 0.3, JPY mas dinamico)
// AO confirma que el momentum ya empezo -- filtra falsas rupturas de spread
input bool   UseAOFilter     = true;
input bool   AORequireCross  = false; // false = AO en zona + direccion. true = cruce de cero

input group "=== FILTROS DE SEGURIDAD ==="
input int    MinCandlesWait  = 8;
input int    MaxSpreadPoints = 20;   // JPY spread tipico 0.1-1 pip = 1-10 pts (3 decimales)

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
//| INICIALIZACION                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   if(StringFind(_Symbol, "JPY") < 0)
      Print("EA disenado para USDJPY -- simbolo actual: ", _Symbol);

   trade.SetExpertMagicNumber(20250003);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_currentDay      = StringToTime(TimeToString(TimeGMT(), TIME_DATE));

   Print("SessionBias USDJPY v1.3 -- simbolo: ", _Symbol,
         " | breakout ", BreakoutPeriod, " velas + AO",
         " | H1 EMA align: ", (UseH1EMAAlign ? "ON" : "OFF"),
         " | 07-13h UTC | riesgo ", RiskPercent, "%");
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

      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != 20250003)       continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      if(profit < 0.0)
      {
         g_consecLosses++;
         if(g_consecLosses >= MaxConsecLosses)
         {
            g_circuitBreakerUntil = TimeCurrent() + CircuitBreakerHours * 3600;
            g_consecLosses = 0;
            Print("Circuit breaker JPY -- ", MaxConsecLosses, " perdidas.",
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
//| SENAL: +1 buy, -1 sell, 0 nada                                  |
//+------------------------------------------------------------------+
int GetSignal()
{
   // 1. TENDENCIA MACRO -- D1 + H4 + EMA50 D1
   double closeD1  = iClose(_Symbol, PERIOD_D1, 0);
   double openD1   = iOpen( _Symbol, PERIOD_D1, 0);
   double ema200H4 = GetEMA(PERIOD_H4, 200);
   double ema50D1  = GetEMA(PERIOD_D1, 50);
   double closeH4  = iClose(_Symbol, PERIOD_H4, 1);

   bool trendUp   = (closeH4 > ema200H4) && (closeD1 > openD1) && (closeD1 > ema50D1);
   bool trendDown = (closeH4 < ema200H4) && (closeD1 < openD1) && (closeD1 < ema50D1);
   if(!trendUp && !trendDown) return 0;

   // 1b. H1 EMA ALIGNMENT -- filtro mas rapido y preciso que W1 EMA20 (v1.2)
   // En downtrend sostenido: EMA21(H1) < EMA50(H1) casi todo el año -> longs bloqueados
   // Responde en horas, no semanas. Evita longs en H1 bajistas y shorts en H1 alcistas.
   if(UseH1EMAAlign)
   {
      double ema21H1 = GetEMA(PERIOD_H1, 21);
      double ema50H1 = GetEMA(PERIOD_H1, 50);
      if(trendUp   && ema21H1 < ema50H1) return 0; // H1 bajista -- no long breakout
      if(trendDown && ema21H1 > ema50H1) return 0; // H1 alcista -- no short breakout
   }

   // 1c. FILTRO SEMANAL (default=false -- regresion en v1.2, reemplazado por H1 EMA)
   if(UseWeeklyFilter)
   {
      double ema20W1 = GetEMA(PERIOD_W1, 20);
      double closeW1 = iClose(_Symbol, PERIOD_W1, 0);
      if(trendUp   && closeW1 < ema20W1) return 0;
      if(trendDown && closeW1 > ema20W1) return 0;
   }

   // 2. ADX H4 y D1 -- tendencia con fuerza suficiente
   if(GetADX(PERIOD_H4) < ADX_H4_Min) return 0;
   if(UseADX_D1Filter && GetADX(PERIOD_D1) < ADX_D1_Min) return 0;

   // 3. AWESOME OSCILLATOR H1 -- confirma que el momentum ya arranco
   // Filtra falsas rupturas: si el AO no confirma, la ruptura es solo spread/ruido
   if(UseAOFilter)
   {
      double ao0 = GetAO(PERIOD_H1, 0);
      double ao1 = GetAO(PERIOD_H1, 1);

      if(AORequireCross)
      {
         if(trendUp   && !((ao0 > 0) && (ao1 <= 0))) return 0;
         if(trendDown && !((ao0 < 0) && (ao1 >= 0))) return 0;
      }
      else
      {
         if(trendUp   && !((ao0 > 0) && (ao0 > ao1))) return 0;
         if(trendDown && !((ao0 < 0) && (ao0 < ao1))) return 0;
      }
   }

   // 4. BREAKOUT DE SESION EN M15
   // USDJPY consolida 2h y luego rompe -- mismo patron que el oro
   // Entrada cuando cierre M15 supera el maximo/minimo de las N velas previas
   int      lookback = BreakoutPeriod + 2;
   MqlRates r[]; ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, PERIOD_M15, 0, lookback, r) < lookback) return 0;

   double atr      = GetATR(PERIOD_M15);
   double minBreak = atr * MinBreakoutATR;

   double highN = r[2].high, lowN = r[2].low;
   for(int j = 2; j <= BreakoutPeriod; j++)
   {
      if(r[j].high > highN) highN = r[j].high;
      if(r[j].low  < lowN)  lowN  = r[j].low;
   }

   bool breakUp   = trendUp   && (r[1].close > highN + minBreak) && (r[1].close > r[1].open);
   bool breakDown = trendDown && (r[1].close < lowN  - minBreak) && (r[1].close < r[1].open);

   if(breakUp)   return  1;
   if(breakDown) return -1;
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

   bool ok = (signal > 0) ? trade.Buy( lots, _Symbol, price, sl, tp, "SB_JPY_v1")
                          : trade.Sell(lots, _Symbol, price, sl, tp, "SB_JPY_v1");

   if(ok)
      Print("JPY entry: ", (signal > 0 ? "BUY" : "SELL"),
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
      if(!posInfo.SelectByIndex(i) || posInfo.Magic() != 20250003) continue;

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
      if(!posInfo.SelectByIndex(i) || posInfo.Magic() != 20250003) continue;
      ulong ticket = posInfo.Ticket();
      if(trade.PositionClose(ticket))
         Print("Cierre sesion JPY: P&L=", NormalizeDouble(posInfo.Profit(), 2));
   }
}

//+------------------------------------------------------------------+
//| HELPERS                                                          |
//+------------------------------------------------------------------+
bool IsTradingTime()
{
   MqlDateTime dt; TimeToStruct(TimeGMT(), dt);
   // v1.1: 07-12:59h UTC -- cierre Tokio + apertura Londres + pre-mercado NY
   return (dt.hour >= 7 && dt.hour < 13);
}

bool IsSpreadOk()
{
   return (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) < MaxSpreadPoints;
}

bool HasPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == 20250003)
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
         Print("Daily loss limit JPY: -$", NormalizeDouble(loss, 2), " -- sin entradas hoy");
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

double GetAO(ENUM_TIMEFRAMES tf, int shift)
{
   int    h = iAO(_Symbol, tf);
   double v[]; ArraySetAsSeries(v, true);
   if(CopyBuffer(h, 0, shift, 1, v) < 1) { IndicatorRelease(h); return 0; }
   IndicatorRelease(h);
   return v[0];
}
//+------------------------------------------------------------------+
