//+------------------------------------------------------------------+
//|                                           GOLDT.mq5              |
//|   Trend-pullback scalper tuned for gold (XAUUSD)                 |
//|   DEMO ACCOUNT ONLY until backtested and forward-tested.         |
//+------------------------------------------------------------------+
#property copyright "Kryx"
#property version   "1.00"

#include <Trade\Trade.mqh>
CTrade trade;

//--- Strategy
input group "--- Strategy ---"
input ENUM_TIMEFRAMES InpTrendTF     = PERIOD_M15; // Higher timeframe for trend direction
input int             InpTrendEMA    = 50;         // Trend EMA period (on higher timeframe)
input int             InpPullbackEMA = 20;         // Pullback EMA period (on chart timeframe)
input int             InpATRPeriod   = 14;         // ATR period (on chart timeframe)
input double          InpSL_ATR      = 1.5;        // Stop loss = ATR x this
input double          InpRR          = 1.5;        // Take profit = stop distance x this
input int             InpMaxHoldBars = 12;         // Close trade after this many bars (0 = off)

//--- Gold-specific filters (all in PRICE units, i.e. dollars per ounce)
input group "--- Gold filters ---"
input bool   InpGoldOnly     = true;  // Refuse to run on non-gold symbols
input double InpMaxSpread    = 0.40;  // Skip if spread above this ($)
input double InpMaxSpreadToSL = 0.15; // Skip if spread > this fraction of SL distance
input double InpMinATR       = 0.50;  // Skip dead markets: ATR below this ($)
input double InpMaxSpikeATR  = 3.0;   // Skip if last candle range > this x ATR (news spikes)

//--- Risk
input group "--- Risk ---"
input double InpRiskPercent      = 0.5; // Risk per trade (% of balance)
input int    InpMaxTradesPerDay = 5;   // Max entries per day
input double InpMaxDailyLossPct = 2.0; // Stop trading for the day at this loss (% of balance)

//--- Session, expressed in GMT so it is easy to reason about
input group "--- Session (GMT) ---"
input int InpBrokerGMTOffset = 2;  // Your broker's server time offset from GMT
input int InpStartHourGMT    = 7;  // Start trading (London open region)
input int InpEndHourGMT      = 17; // Stop opening trades

//--- General
input group "--- General ---"
input ulong InpMagic     = 123456; // Magic number
input int   InpDeviation = 30;     // Max slippage (points)

//--- Globals
int       hPullback = INVALID_HANDLE;
int       hTrend    = INVALID_HANDLE;
int       hATR      = INVALID_HANDLE;
datetime lastBarTime = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpGoldOnly && !IsGoldSymbol())
     {
      Print("This EA is set to gold only. Current symbol: ", _Symbol,
            ". Attach it to a gold chart or set InpGoldOnly = false.");
      return(INIT_FAILED);
     }

   Print("SUCCESS: GOLDT Expert Advisor initialized successfully on symbol: ", _Symbol);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);

   hPullback = iMA(_Symbol, _Period, InpPullbackEMA, 0, MODE_EMA, PRICE_CLOSE);
   hTrend    = iMA(_Symbol, InpTrendTF, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   hATR      = iATR(_Symbol, _Period, InpATRPeriod);

   if(hPullback == INVALID_HANDLE || hTrend == INVALID_HANDLE || hATR == INVALID_HANDLE)
     {
      Print("Error creating indicator handles: ", GetLastError());
      return(INIT_FAILED);
     }
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(hPullback);
   IndicatorRelease(hTrend);
   IndicatorRelease(hATR);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   // 1. Only act once per new bar (bar time is recorded immediately)
   if(!IsNewBar()) return;

   // 2. Manage existing trades first (runs even outside the session)
   ManageTimeStop();

   // 3. Cheap gatekeeping
   if(!InSession())         return;
   if(HasOpenPosition())    return;
   if(TradesToday() >= InpMaxTradesPerDay) return;
   if(DailyLossLimitHit()) return;

   // 4. Read indicator values (index 0 = last closed bar, 1 = the one before)
   double pb[], trendEMA[], atr[];
   ArraySetAsSeries(pb, true);
   ArraySetAsSeries(trendEMA, true);
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(hPullback, 0, 1, 2, pb)        < 2) return;
   if(CopyBuffer(hTrend,    0, 1, 2, trendEMA) < 2) return;
   if(CopyBuffer(hATR,      0, 1, 1, atr)      < 1) return;

   double close1   = iClose(_Symbol, _Period, 1);
   double close2   = iClose(_Symbol, _Period, 2);
   double htfClose = iClose(_Symbol, InpTrendTF, 1);

   // 5. Trend filter: higher-timeframe price vs EMA, and EMA slope
   bool uptrend   = (htfClose > trendEMA[0]) && (trendEMA[0] > trendEMA[1]);
   bool downtrend = (htfClose < trendEMA[0]) && (trendEMA[0] < trendEMA[1]);

   // 6. Entry: price dipped through the pullback EMA, then closed back with the trend
   bool buySignal  = uptrend   && (close2 < pb[1]) && (close1 > pb[0]);
   bool sellSignal = downtrend && (close2 > pb[1]) && (close1 < pb[0]);
   if(!buySignal && !sellSignal) return;

   // 7. Gold market-condition filters (only checked when a signal exists)
   if(atr[0] < InpMinATR)
     {
      Print("Skipped: market too quiet (ATR $", DoubleToString(atr[0], 2), ")");
      return;
     }
   double barRange = iHigh(_Symbol, _Period, 1) - iLow(_Symbol, _Period, 1);
   if(barRange > atr[0] * InpMaxSpikeATR)
     {
      Print("Skipped: spike candle (range $", DoubleToString(barRange, 2), ")");
      return;
     }

   // 8. Prices, spread filters
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double spread = ask - bid;

   double slDist = atr[0] * InpSL_ATR;
   double tpDist = slDist * InpRR;

   // Respect the broker's minimum stop distance
   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   slDist = MathMax(slDist, minDist);
   tpDist = MathMax(tpDist, minDist);

   if(spread > InpMaxSpread)
     {
      Print("Skipped: spread too wide ($", DoubleToString(spread, 2), ")");
      return;
     }
   if(spread > slDist * InpMaxSpreadToSL)
     {
      Print("Skipped: spread too large relative to the stop distance");
      return;
     }

   // 9. Position size from risk
   double lots = CalcLots(slDist);
   if(lots <= 0)
     {
      Print("Skipped: lot size below broker minimum for this risk setting");
      return;
     }

   // 10. Place the order and log the result either way
   bool ok = false;
   if(buySignal)
     {
      double sl = NormalizeDouble(ask - slDist, _Digits);
      double tp = NormalizeDouble(ask + tpDist, _Digits);
      ok = trade.Buy(lots, _Symbol, 0.0, sl, tp, "Gold PB Buy");
     }
   else
     {
      double sl = NormalizeDouble(bid + slDist, _Digits);
      double tp = NormalizeDouble(bid - tpDist, _Digits);
      ok = trade.Sell(lots, _Symbol, 0.0, sl, tp, "Gold PB Sell");
     }

   if(ok)
      Print("Order placed. Lots: ", DoubleToString(lots, 2),
            "  SL dist: $", DoubleToString(slDist, 2));
   else
      Print("Order FAILED. Code: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Is the current symbol gold?                                      |
//+------------------------------------------------------------------+
bool IsGoldSymbol()
  {
   string s = _Symbol;
   StringToUpper(s);
   return (StringFind(s, "XAU") >= 0 || StringFind(s, "GOLD") >= 0);
  }

//+------------------------------------------------------------------+
//| True once per new bar                                            |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t = iTime(_Symbol, _Period, 0);
   if(t == lastBarTime) return false;
   lastBarTime = t;
   return true;
  }

//+------------------------------------------------------------------+
//| Inside the allowed hours, converted from server time to GMT      |
//+------------------------------------------------------------------+
bool InSession()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int gmtHour = (((dt.hour - InpBrokerGMTOffset) % 24) + 24) % 24;
   return (gmtHour >= InpStartHourGMT && gmtHour < InpEndHourGMT);
  }

//+------------------------------------------------------------------+
//| Scalps should be short: close trades that have gone stale        |
//+------------------------------------------------------------------+
void ManageTimeStop()
  {
   if(InpMaxHoldBars <= 0) return;
   long maxSeconds = (long)InpMaxHoldBars * PeriodSeconds(_Period);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) continue;

      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      if(TimeCurrent() - opened >= maxSeconds)
        {
         if(trade.PositionClose(ticket))
            Print("Time stop: closed stale position #", ticket);
         else
            Print("Time stop FAILED. Code: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
        }
     }
  }

//+------------------------------------------------------------------+
//| Does THIS bot already have a position on THIS symbol?            |
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == (long)InpMagic)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| How many entries this bot opened today on this symbol            |
//+------------------------------------------------------------------+
int TradesToday()
  {
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   if(!HistorySelect(dayStart, TimeCurrent())) return 0;

   int count = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0) continue;
      if(HistoryDealGetInteger(t, DEAL_MAGIC) != (long)InpMagic) continue;
      if(HistoryDealGetString(t, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(t, DEAL_ENTRY) == DEAL_ENTRY_IN) count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
//| Daily loss limit protection check                                |
//+------------------------------------------------------------------+
bool DailyLossLimitHit()
  {
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   if(!HistorySelect(dayStart, TimeCurrent())) return false;

   double totalPnL = 0.0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0) continue;
      if(HistoryDealGetInteger(t, DEAL_MAGIC) != (long)InpMagic) continue;
      if(HistoryDealGetString(t, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(t, DEAL_ENTRY) == DEAL_ENTRY_OUT)
        {
         totalPnL += HistoryDealGetDouble(t, DEAL_PROFIT) +
                     HistoryDealGetDouble(t, DEAL_SWAP) +
                     HistoryDealGetDouble(t, DEAL_COMMISSION);
        }
     }

   double maxAllowedLoss = -(InpMaxDailyLossPct / 100.0 * AccountInfoDouble(ACCOUNT_BALANCE));
   return (totalPnL <= maxAllowedLoss);
  }

//+------------------------------------------------------------------+
//| Lot size so that hitting the stop loses InpRiskPercent of balance|
//+------------------------------------------------------------------+
double CalcLots(double slDistance)
  {
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0 || slDistance <= 0) return 0.0;

   double lossPerLot = (slDistance / tickSize) * tickValue;
   double lots = riskMoney / lossPerLot;

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lots = MathFloor(lots / step) * step;
   if(lots < minL) return 0.0;
   if(lots > maxL) lots = maxL;
   return NormalizeDouble(lots, 2);
  }
//+------------------------------------------------------------------+