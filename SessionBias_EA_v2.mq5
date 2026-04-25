//+------------------------------------------------------------------+
//|                                              SessionBias_EA.mq5  |
//|                         Multi-TF Trend + Pullback Strategy       |
//|                         v7.0 — Pullback Pro + XAUUSD Support     |
//+------------------------------------------------------------------+
#property copyright "SessionBias EA"
#property version   "8.60"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade         trade;
CPositionInfo  posInfo;

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input double Version = 8.6;

input group "=== GESTIÓN DE RIESGO ==="
input double   RiskPercent       = 0.5;     // Bajado a 0.5% para controlar el Drawdown 60%
input double   ATR_Multiplier_SL = 2.5;     // SL más amplio (era 2.0)
input double   ATR_Multiplier_TP = 5.0;     // RR 1:2 fijo
input int      ATR_Period        = 14;   

input group "=== GESTIÓN DE POSICIÓN (ESCALONES DE GANANCIA) ==="
input bool   UseBreakEven       = true;
input bool   UsePartialClose    = true;
input double PartialClose_Pct   = 30.0;     
input double BreakEven_ATR_Mult = 1.5;      
input int    BreakEven_Padding  = 10;       
input bool   UseStepTrailing    = true;     // Nuevo sistema por escalones
input double Step1_Trigger      = 2.5;      // Cuando el precio alcance 2.5x ATR...
input double Step1_Lock         = 1.0;      // ...Asegurar 1.0x ATR de ganancia
input double Step2_Trigger      = 3.5;      // Cuando el precio alcance 3.5x ATR...
input double Step2_Lock         = 2.0;      // ...Asegurar 2.0x ATR de ganancia

input group "=== FILTROS DE ALTA PROBABILIDAD ==="
input int      ADX_Min           = 25;      // Solo tendencias fuertes
input bool     UseDailyFilter    = true;    // Solo operar a favor de la vela D1
input double   MinBodyPct        = 0.6;     // La vela de entrada debe ser 60% cuerpo (evita mechas)

input group "=== PARES ==="
input bool     Trade_EURUSD = true;
input bool     Trade_GBPUSD = true;
input bool     Trade_USDJPY = true;
input bool     Trade_XAUUSD = true; 
//+------------------------------------------------------------------+
//| ESTRUCTURAS                                                       |
//+------------------------------------------------------------------+
enum MARKET_REGIME
{
   REGIME_TREND_UP,
   REGIME_TREND_DOWN,
   REGIME_RANGE,
   REGIME_UNDEFINED
};

enum SIGNAL_TYPE
{
   SIGNAL_BUY,
   SIGNAL_SELL,
   SIGNAL_NONE
};

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

//+------------------------------------------------------------------+
//| INICIALIZACIÓN                                                    |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(20240001);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   BuildPairsList();
   ArrayResize(g_lastBarTime, ArraySize(g_pairs));
   ArrayInitialize(g_lastBarTime, 0);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| TICK PRINCIPAL                                                    |
//+------------------------------------------------------------------+
void OnTick() {
   // Llama a la gestión de posiciones en cada tick para que el BE sea instantáneo
   ManageBreakEven();
   for(int i=0; i<ArraySize(g_pairs); i++) {
      string symbol = g_pairs[i];
      //ManageExits(symbol);

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
//| LÓGICA QUANT OPTIMIZADA                                          |
//+------------------------------------------------------------------+
void AnalyzePullback(string symbol, MarketAnalysis &analysis) {
   analysis.signal = SIGNAL_NONE;

   // 1. FILTRO MACRO: H4 + D1
   double adx = GetADX(symbol, PERIOD_H4);
   double ema200_H4 = GetEMA(symbol, PERIOD_H4, 200);
   double closeH4 = iClose(symbol, PERIOD_H4, 1);
   double closeD1 = iClose(symbol, PERIOD_D1, 1);
   double openD1  = iOpen(symbol, PERIOD_D1, 1);
   
   bool trendUp   = (closeH4 > ema200_H4) && (closeD1 > openD1);
   bool trendDown = (closeH4 < ema200_H4) && (closeD1 < openD1);

   // NUEVO: Filtro asimétrico de fuerza (Ventas exigen ADX > 30)
   int requiredADX_Buy = ADX_Min; 
   int requiredADX_Sell = ADX_Min + 5; 

   if(trendUp && adx < requiredADX_Buy) return;
   if(trendDown && adx < requiredADX_Sell) return;

   // 2. FILTRO DE PENDIENTE (EMA 21 H1)
   double ema21_now  = GetEMA(symbol, PERIOD_H1, 21);
   double ema21_prev = iMA(symbol, PERIOD_H1, 21, 0, MODE_EMA, PRICE_CLOSE);
   
   if(trendUp && ema21_now <= ema21_prev) return;
   if(trendDown && ema21_now >= ema21_prev) return;

   // 3. ENTRADA M15 CON FILTRO DE CUERPO
   MqlRates r[];
   ArraySetAsSeries(r,true);
   if(CopyRates(symbol, PERIOD_M15, 0, 3, r) < 3) return;

   double body   = MathAbs(r[1].close - r[1].open);
   double range  = r[1].high - r[1].low;
   if(range <= 0 || (body/range) < MinBodyPct) return;

   if(trendUp && r[1].close > r[1].open && r[1].close > r[2].high) analysis.signal = SIGNAL_BUY;
   if(trendDown && r[1].close < r[1].open && r[1].close < r[2].low) analysis.signal = SIGNAL_SELL;

   if(analysis.signal == SIGNAL_NONE) return;

   // 4. AJUSTE DINÁMICO DE TP/SL ASIMÉTRICO
   double atr = GetATR(symbol, PERIOD_M15);
   double slMult = ATR_Multiplier_SL;
   if(StringFind(symbol,"XAU")>=0) slMult *= 1.5;

   double p = (analysis.signal==SIGNAL_BUY)?SymbolInfoDouble(symbol,SYMBOL_ASK):SymbolInfoDouble(symbol,SYMBOL_BID);
   int dig = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   
   // Asignamos un TP más conservador a los Shorts (3.0 en lugar del 5.0 global)
   double dynamicTP_Mult = (analysis.signal == SIGNAL_BUY) ? ATR_Multiplier_TP : 3.0;
   
   analysis.entryPrice = p;
   analysis.stopLoss = NormalizeDouble((analysis.signal==SIGNAL_BUY)? p - (atr*slMult) : p + (atr*slMult), dig);
   analysis.takeProfit = NormalizeDouble((analysis.signal==SIGNAL_BUY)? p + (atr*dynamicTP_Mult) : p - (atr*dynamicTP_Mult), dig);
}

//+------------------------------------------------------------------+
//| GESTIÓN DE SALIDAS (BREAK-EVEN PROTECTOR)                        |
//+------------------------------------------------------------------+
void ManageExits(string symbol) {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(posInfo.SelectByIndex(i) && posInfo.Symbol()==symbol && posInfo.Magic()==20240001) {
         double entry = posInfo.PriceOpen();
         double sl = posInfo.StopLoss();
         double price = (posInfo.PositionType()==POSITION_TYPE_BUY)?SymbolInfoDouble(symbol,SYMBOL_BID):SymbolInfoDouble(symbol,SYMBOL_ASK);
         double atr = GetATR(symbol, PERIOD_M15);

         // Break-Even al alcanzar 2.5x ATR (distancia del SL original)
         if(MathAbs(price - entry) > atr * 2.5) {
            if((posInfo.PositionType()==POSITION_TYPE_BUY && sl < entry) || (posInfo.PositionType()==POSITION_TYPE_SELL && (sl > entry || sl==0))) {
               trade.PositionModify(posInfo.Ticket(), entry + (20 * SymbolInfoDouble(symbol, SYMBOL_POINT)), posInfo.TakeProfit());
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| HELPERS                                                          |
//+------------------------------------------------------------------+
void BuildPairsList() {
   string c[] = {"EURUSDm", "GBPUSDm", "USDJPYm", "XAUUSDm"};
   int count=0;
   for(int i=0; i<4; i++) {
      if(SymbolSelect(c[i], true)) {
         ArrayResize(g_pairs, count+1);
         g_pairs[count++] = c[i];
      }
   }
}

double GetEMA(string s, ENUM_TIMEFRAMES tf, int p) {
   int h = iMA(s, tf, p, 0, MODE_EMA, PRICE_CLOSE);
   double v[]; ArraySetAsSeries(v,true);
   CopyBuffer(h,0,0,1,v); IndicatorRelease(h);
   return v[0];
}

double GetADX(string s, ENUM_TIMEFRAMES tf) {
   int h = iADX(s, tf, 14);
   double v[]; ArraySetAsSeries(v,true);
   CopyBuffer(h,0,0,1,v); IndicatorRelease(h);
   return v[0];
}

double GetATR(string s, ENUM_TIMEFRAMES tf) {
   int h = iATR(s, tf, 14);
   double v[]; ArraySetAsSeries(v,true);
   CopyBuffer(h,0,0,1,v); IndicatorRelease(h);
   return v[0];
}

bool IsSpreadOk(string s) {
   return (SymbolInfoInteger(s, SYMBOL_SPREAD) < 30); // Max 3 pips
}

bool IsTradingTime() {
   MqlDateTime dt; TimeToStruct(TimeGMT(), dt);
   return (dt.hour >= 8 && dt.hour < 16); // Sesión Londres/NY pura
}

bool HasPosition(string s) {
   int c=0;
   for(int i=PositionsTotal()-1; i>=0; i--)
      if(posInfo.SelectByIndex(i) && posInfo.Symbol()==s && posInfo.Magic()==20240001) c++;
   return c >= 1;
}

void ExecuteTrade(string s, MarketAnalysis &a) {
   double riskUSD = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
   double tickVal = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_VALUE);
   double slT = MathAbs(a.entryPrice - a.stopLoss) / SymbolInfoDouble(s, SYMBOL_TRADE_TICK_SIZE);
   if(slT <= 0) return;
   
   double lots = NormalizeDouble(riskUSD / (slT * tickVal), 2);
   lots = MathMax(SymbolInfoDouble(s, SYMBOL_VOLUME_MIN), MathMin(SymbolInfoDouble(s, SYMBOL_VOLUME_MAX), lots));
   
   // CORRECCIÓN: Separar estrictamente Compra de Venta
   if(a.signal == SIGNAL_BUY) {
      trade.Buy(lots, s, a.entryPrice, a.stopLoss, a.takeProfit, "Quant_v8");
   } 
   else if(a.signal == SIGNAL_SELL) {
      trade.Sell(lots, s, a.entryPrice, a.stopLoss, a.takeProfit, "Quant_v8");
   }
}

void ManageBreakEven() {
   if(!UseBreakEven && !UseStepTrailing) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(posInfo.SelectByIndex(i) && posInfo.Magic() == 20240001) {
         string symbol = posInfo.Symbol();
         ulong ticket = posInfo.Ticket();
         double entryPrice = posInfo.PriceOpen();
         double currentSL = posInfo.StopLoss();
         double currentPrice = posInfo.PriceCurrent();
         double volume = posInfo.Volume();
         long type = posInfo.PositionType();

         double atr = GetATR(symbol, PERIOD_M15); 
         double beTrigger = atr * BreakEven_ATR_Mult;
         double step1Trigger = atr * Step1_Trigger;
         double step1Lock = atr * Step1_Lock;
         double step2Trigger = atr * Step2_Trigger;
         double step2Lock = atr * Step2_Lock;
         
         double pTickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
         int dig = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

         if(type == POSITION_TYPE_BUY) {
            // --- FASE 1: BreakEven y Cierre Parcial (1.5 ATR) ---
            if(currentPrice >= (entryPrice + beTrigger) && currentSL < entryPrice) {
               double newSL = NormalizeDouble(entryPrice + (BreakEven_Padding * pTickSize), dig);
               if(trade.PositionModify(ticket, newSL, posInfo.TakeProfit())) {
                  if(UsePartialClose) {
                     double volToClose = NormalizeDouble(volume * (PartialClose_Pct / 100.0), 2);
                     if(volToClose >= SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN)) {
                        trade.PositionClosePartial(ticket, volToClose);
                     }
                  }
               }
            }
            // --- FASE 2: Escalones de Ganancia ---
            if(UseStepTrailing) {
               // Escalón 2 (Asegurar 2.0 ATR)
               if(currentPrice >= (entryPrice + step2Trigger) && currentSL < (entryPrice + step2Lock - (10*pTickSize))) {
                  double newSL = NormalizeDouble(entryPrice + step2Lock, dig);
                  trade.PositionModify(ticket, newSL, posInfo.TakeProfit());
               }
               // Escalón 1 (Asegurar 1.0 ATR)
               else if(currentPrice >= (entryPrice + step1Trigger) && currentSL < (entryPrice + step1Lock - (10*pTickSize))) {
                  double newSL = NormalizeDouble(entryPrice + step1Lock, dig);
                  trade.PositionModify(ticket, newSL, posInfo.TakeProfit());
               }
            }
         }
         else if(type == POSITION_TYPE_SELL) {
            // --- FASE 1: BreakEven y Cierre Parcial (1.5 ATR) ---
            if(currentPrice <= (entryPrice - beTrigger) && (currentSL > entryPrice || currentSL == 0.0)) {
               double newSL = NormalizeDouble(entryPrice - (BreakEven_Padding * pTickSize), dig);
               if(trade.PositionModify(ticket, newSL, posInfo.TakeProfit())) {
                  if(UsePartialClose) {
                     double volToClose = NormalizeDouble(volume * (PartialClose_Pct / 100.0), 2);
                     if(volToClose >= SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN)) {
                        trade.PositionClosePartial(ticket, volToClose);
                     }
                  }
               }
            }
            // --- FASE 2: Escalones de Ganancia ---
            if(UseStepTrailing) {
               // Escalón 2 (Asegurar 2.0 ATR)
               if(currentPrice <= (entryPrice - step2Trigger) && (currentSL > (entryPrice - step2Lock + (10*pTickSize)) || currentSL == 0.0)) {
                  double newSL = NormalizeDouble(entryPrice - step2Lock, dig);
                  trade.PositionModify(ticket, newSL, posInfo.TakeProfit());
               }
               // Escalón 1 (Asegurar 1.0 ATR)
               else if(currentPrice <= (entryPrice - step1Trigger) && (currentSL > (entryPrice - step1Lock + (10*pTickSize)) || currentSL == 0.0)) {
                  double newSL = NormalizeDouble(entryPrice - step1Lock, dig);
                  trade.PositionModify(ticket, newSL, posInfo.TakeProfit());
               }
            }
         }
      }
   }
}