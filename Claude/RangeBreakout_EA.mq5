//+------------------------------------------------------------------+
//|                                           RangeBreakout_EA.mq5   |
//|                                   Range Breakout Trading Strategy |
//|                                                                    |
//+------------------------------------------------------------------+
#property copyright "Range Breakout EA"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== Range Time Settings ==="
input int      InpRangeStartHour     = 2;        // Range Start Hour (0-23)
input int      InpRangeStartMinute   = 0;        // Range Start Minute (0-59)
input int      InpRangeEndHour       = 7;        // Range End Hour (0-23)
input int      InpRangeEndMinute     = 0;        // Range End Minute (0-59)

input group "=== Trading Time Settings ==="
input int      InpCloseHour          = 20;       // Close All & Delete Orders Hour (0-23)
input int      InpCloseMinute        = 0;        // Close All & Delete Orders Minute (0-59)

input group "=== Risk Management ==="
input double   InpRiskAmount         = 100.0;    // Risk Amount per Trade (fixed money)
input double   InpSLFactor           = 1.0;      // Stop Loss Factor (x Range Size)
input double   InpTPFactor           = 2.0;      // Take Profit Factor (x Range Size, 0 = No TP)

input group "=== Trade Settings ==="
input bool     InpTradeBothDirections = true;   // Trade Both Directions (Buy & Sell)
input bool     InpDeleteOnFirstFill   = true;   // Delete Other Order When First Fills (if trading both)
input int      InpMagicNumber         = 123456; // Magic Number
input int      InpSlippage            = 10;     // Slippage (points)

input group "=== Visual Settings ==="
input bool     InpShowRange          = true;    // Show Range on Chart
input color    InpRangeColor         = clrDodgerBlue; // Range Box Color
input color    InpHighColor          = clrLime;       // Range High Line Color
input color    InpLowColor           = clrRed;        // Range Low Line Color

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
CTrade         trade;
double         g_rangeHigh           = 0;
double         g_rangeLow            = 0;
datetime       g_rangeStartTime      = 0;
datetime       g_rangeEndTime        = 0;
datetime       g_closeTime           = 0;
bool           g_rangeCreated        = false;
bool           g_buyOrderPlaced      = false;
bool           g_sellOrderPlaced     = false;
bool           g_buyTriggered        = false;
bool           g_sellTriggered       = false;
datetime       g_lastDayProcessed    = 0;
ulong          g_buyTicket           = 0;
ulong          g_sellTicket          = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   // Validate inputs
   if(InpRangeStartHour < 0 || InpRangeStartHour > 23 ||
      InpRangeEndHour < 0 || InpRangeEndHour > 23 ||
      InpCloseHour < 0 || InpCloseHour > 23)
   {
      Print("Error: Invalid hour settings. Hours must be between 0-23.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   if(InpRangeStartMinute < 0 || InpRangeStartMinute > 59 ||
      InpRangeEndMinute < 0 || InpRangeEndMinute > 59 ||
      InpCloseMinute < 0 || InpCloseMinute > 59)
   {
      Print("Error: Invalid minute settings. Minutes must be between 0-59.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   if(InpRiskAmount <= 0)
   {
      Print("Error: Risk amount must be positive.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   // Initialize trade object
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   // Reset daily variables
   ResetDailyVariables();
   
   Print("Range Breakout EA initialized successfully.");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Remove visual objects
   ObjectsDeleteAll(0, "RangeBreakout_");
   ChartRedraw();
   Print("Range Breakout EA deinitialized.");
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime currentTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);
   
   // Check for new day
   datetime today = StringToTime(TimeToString(currentTime, TIME_DATE));
   if(today != g_lastDayProcessed)
   {
      ResetDailyVariables();
      g_lastDayProcessed = today;
      CalculateDailyTimes(today);
   }
   
   // Check if we should close everything
   if(currentTime >= g_closeTime)
   {
      CloseAllPositions();
      DeleteAllPendingOrders();
      return;
   }
   
   // During range period - calculate range
   if(currentTime >= g_rangeStartTime && currentTime < g_rangeEndTime)
   {
      CalculateRange();
   }
   // After range period - place orders and manage trades
   else if(currentTime >= g_rangeEndTime && currentTime < g_closeTime)
   {
      // Mark range as created
      if(!g_rangeCreated && g_rangeHigh > 0 && g_rangeLow > 0)
      {
         g_rangeCreated = true;
         DrawRange();
         Print("Range created - High: ", g_rangeHigh, " Low: ", g_rangeLow, 
               " Size: ", NormalizeDouble((g_rangeHigh - g_rangeLow) / _Point, 0), " points");
      }
      
      // Place pending orders if range is created
      if(g_rangeCreated)
      {
         PlacePendingOrders();
         CheckForBreakoutEntry();
         CheckOrderFills();
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate daily times                                              |
//+------------------------------------------------------------------+
void CalculateDailyTimes(datetime today)
{
   g_rangeStartTime = today + InpRangeStartHour * 3600 + InpRangeStartMinute * 60;
   g_rangeEndTime = today + InpRangeEndHour * 3600 + InpRangeEndMinute * 60;
   g_closeTime = today + InpCloseHour * 3600 + InpCloseMinute * 60;
   
   // Handle overnight range
   if(g_rangeEndTime <= g_rangeStartTime)
      g_rangeEndTime += 86400; // Add one day
   
   if(g_closeTime <= g_rangeEndTime)
      g_closeTime += 86400; // Add one day
}

//+------------------------------------------------------------------+
//| Reset daily variables                                              |
//+------------------------------------------------------------------+
void ResetDailyVariables()
{
   g_rangeHigh = 0;
   g_rangeLow = DBL_MAX;
   g_rangeCreated = false;
   g_buyOrderPlaced = false;
   g_sellOrderPlaced = false;
   g_buyTriggered = false;
   g_sellTriggered = false;
   g_buyTicket = 0;
   g_sellTicket = 0;
   
   // Remove previous day's visual objects
   //ObjectsDeleteAll(0, "RangeBreakout_");
}

//+------------------------------------------------------------------+
//| Calculate range high and low                                       |
//+------------------------------------------------------------------+
void CalculateRange()
{
   double high = iHigh(_Symbol, PERIOD_M1, 0);
   double low = iLow(_Symbol, PERIOD_M1, 0);
   
   // Also check historical bars within range
   int bars = iBars(_Symbol, PERIOD_M1);
   for(int i = 0; i < bars; i++)
   {
      datetime barTime = iTime(_Symbol, PERIOD_M1, i);
      if(barTime < g_rangeStartTime)
         break;
      if(barTime >= g_rangeEndTime)
         continue;
         
      high = MathMax(high, iHigh(_Symbol, PERIOD_M1, i));
      low = MathMin(low, iLow(_Symbol, PERIOD_M1, i));
   }
   
   g_rangeHigh = high;
   g_rangeLow = low;
}

//+------------------------------------------------------------------+
//| Place pending orders                                               |
//+------------------------------------------------------------------+
void PlacePendingOrders()
{
   if(g_rangeHigh <= g_rangeLow)
      return;
      
   double rangeSize = g_rangeHigh - g_rangeLow;
   double sl = rangeSize * InpSLFactor;
   double tp = (InpTPFactor > 0) ? rangeSize * InpTPFactor : 0;
   
   // Calculate lot size based on risk
   double lotSize = CalculateLotSize(sl);
   if(lotSize <= 0)
      return;
   
   // Place Buy Stop order
   if(!g_buyOrderPlaced && !g_buyTriggered)
   {
      if(InpTradeBothDirections || (!g_sellOrderPlaced && !g_sellTriggered))
      {
         double buyEntry = g_rangeHigh;
         double buySL = buyEntry - sl;
         double buyTP = (tp > 0) ? buyEntry + tp : 0;
         
         // Check if price is below entry level
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(ask < buyEntry)
         {
            if(trade.BuyStop(lotSize, buyEntry, _Symbol, buySL, buyTP, ORDER_TIME_GTC, 0, "RangeBreakout Buy"))
            {
               g_buyTicket = trade.ResultOrder();
               g_buyOrderPlaced = true;
               Print("Buy Stop order placed at ", buyEntry, " SL: ", buySL, " TP: ", buyTP);
            }
            else
            {
               Print("Failed to place Buy Stop order. Error: ", GetLastError());
            }
         }
      }
   }
   
   // Place Sell Stop order
   if(!g_sellOrderPlaced && !g_sellTriggered)
   {
      if(InpTradeBothDirections || (!g_buyOrderPlaced && !g_buyTriggered))
      {
         double sellEntry = g_rangeLow;
         double sellSL = sellEntry + sl;
         double sellTP = (tp > 0) ? sellEntry - tp : 0;
         
         // Check if price is above entry level
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(bid > sellEntry)
         {
            if(trade.SellStop(lotSize, sellEntry, _Symbol, sellSL, sellTP, ORDER_TIME_GTC, 0, "RangeBreakout Sell"))
            {
               g_sellTicket = trade.ResultOrder();
               g_sellOrderPlaced = true;
               Print("Sell Stop order placed at ", sellEntry, " SL: ", sellSL, " TP: ", sellTP);
            }
            else
            {
               Print("Failed to place Sell Stop order. Error: ", GetLastError());
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check for breakout entry (market order if pending fails)          |
//+------------------------------------------------------------------+
void CheckForBreakoutEntry()
{
   if(g_rangeHigh <= g_rangeLow)
      return;
      
   double rangeSize = g_rangeHigh - g_rangeLow;
   double sl = rangeSize * InpSLFactor;
   double tp = (InpTPFactor > 0) ? rangeSize * InpTPFactor : 0;
   double lotSize = CalculateLotSize(sl);
   
   if(lotSize <= 0)
      return;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // Check for buy breakout
   if(!g_buyTriggered && !g_buyOrderPlaced && ask >= g_rangeHigh)
   {
      if(InpTradeBothDirections || !g_sellTriggered)
      {
         double buySL = ask - sl;
         double buyTP = (tp > 0) ? ask + tp : 0;
         
         if(trade.Buy(lotSize, _Symbol, ask, buySL, buyTP, "RangeBreakout Buy Market"))
         {
            g_buyTriggered = true;
            Print("Buy market order executed at ", ask);
            
            if(!InpTradeBothDirections || InpDeleteOnFirstFill)
            {
               DeleteSellOrder();
            }
         }
      }
   }
   
   // Check for sell breakout
   if(!g_sellTriggered && !g_sellOrderPlaced && bid <= g_rangeLow)
   {
      if(InpTradeBothDirections || !g_buyTriggered)
      {
         double sellSL = bid + sl;
         double sellTP = (tp > 0) ? bid - tp : 0;
         
         if(trade.Sell(lotSize, _Symbol, bid, sellSL, sellTP, "RangeBreakout Sell Market"))
         {
            g_sellTriggered = true;
            Print("Sell market order executed at ", bid);
            
            if(!InpTradeBothDirections || InpDeleteOnFirstFill)
            {
               DeleteBuyOrder();
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check if pending orders have been filled                          |
//+------------------------------------------------------------------+
void CheckOrderFills()
{
   // Check Buy order status
   if(g_buyOrderPlaced && !g_buyTriggered && g_buyTicket > 0)
   {
      if(!OrderSelect(g_buyTicket))
      {
         // Order no longer exists - check if it was filled
         if(HistorySelectByPosition(g_buyTicket))
         {
            g_buyTriggered = true;
            Print("Buy order filled.");
            
            if(!InpTradeBothDirections || InpDeleteOnFirstFill)
            {
               DeleteSellOrder();
            }
         }
         else
         {
            // Check if position exists
            for(int i = PositionsTotal() - 1; i >= 0; i--)
            {
               ulong ticket = PositionGetTicket(i);
               if(PositionSelectByTicket(ticket))
               {
                  if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
                     PositionGetString(POSITION_SYMBOL) == _Symbol &&
                     PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                  {
                     g_buyTriggered = true;
                     g_buyOrderPlaced = false;
                     Print("Buy position detected - order was filled.");
                     
                     if(!InpTradeBothDirections || InpDeleteOnFirstFill)
                     {
                        DeleteSellOrder();
                     }
                     break;
                  }
               }
            }
         }
      }
   }
   
   // Check Sell order status
   if(g_sellOrderPlaced && !g_sellTriggered && g_sellTicket > 0)
   {
      if(!OrderSelect(g_sellTicket))
      {
         // Order no longer exists - check if it was filled
         if(HistorySelectByPosition(g_sellTicket))
         {
            g_sellTriggered = true;
            Print("Sell order filled.");
            
            if(!InpTradeBothDirections || InpDeleteOnFirstFill)
            {
               DeleteBuyOrder();
            }
         }
         else
         {
            // Check if position exists
            for(int i = PositionsTotal() - 1; i >= 0; i--)
            {
               ulong ticket = PositionGetTicket(i);
               if(PositionSelectByTicket(ticket))
               {
                  if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
                     PositionGetString(POSITION_SYMBOL) == _Symbol &&
                     PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
                  {
                     g_sellTriggered = true;
                     g_sellOrderPlaced = false;
                     Print("Sell position detected - order was filled.");
                     
                     if(!InpTradeBothDirections || InpDeleteOnFirstFill)
                     {
                        DeleteBuyOrder();
                     }
                     break;
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk amount and stop loss             |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
   if(slDistance <= 0)
      return 0;
   
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   
   if(tickSize == 0 || tickValue == 0)
      return minLot;
   
   // Calculate risk in ticks
   double slTicks = slDistance / tickSize;
   
   // Calculate lot size
   double lotSize = InpRiskAmount / (slTicks * tickValue);
   
   // Normalize lot size
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   
   // Apply limits
   lotSize = MathMax(lotSize, minLot);
   lotSize = MathMin(lotSize, maxLot);
   
   return NormalizeDouble(lotSize, 2);
}

//+------------------------------------------------------------------+
//| Close all positions for this EA                                    |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
            PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            if(trade.PositionClose(ticket))
            {
               Print("Position closed: ", ticket);
            }
            else
            {
               Print("Failed to close position: ", ticket, " Error: ", GetLastError());
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Delete all pending orders for this EA                              |
//+------------------------------------------------------------------+
void DeleteAllPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
      {
         if(OrderGetInteger(ORDER_MAGIC) == InpMagicNumber &&
            OrderGetString(ORDER_SYMBOL) == _Symbol)
         {
            if(trade.OrderDelete(ticket))
            {
               Print("Pending order deleted: ", ticket);
            }
            else
            {
               Print("Failed to delete order: ", ticket, " Error: ", GetLastError());
            }
         }
      }
   }
   
   g_buyOrderPlaced = false;
   g_sellOrderPlaced = false;
   g_buyTicket = 0;
   g_sellTicket = 0;
}

//+------------------------------------------------------------------+
//| Delete Buy pending order                                           |
//+------------------------------------------------------------------+
void DeleteBuyOrder()
{
   if(g_buyTicket > 0 && OrderSelect(g_buyTicket))
   {
      if(trade.OrderDelete(g_buyTicket))
      {
         Print("Buy order deleted: ", g_buyTicket);
         g_buyOrderPlaced = false;
         g_buyTicket = 0;
      }
   }
}

//+------------------------------------------------------------------+
//| Delete Sell pending order                                          |
//+------------------------------------------------------------------+
void DeleteSellOrder()
{
   if(g_sellTicket > 0 && OrderSelect(g_sellTicket))
   {
      if(trade.OrderDelete(g_sellTicket))
      {
         Print("Sell order deleted: ", g_sellTicket);
         g_sellOrderPlaced = false;
         g_sellTicket = 0;
      }
   }
}

//+------------------------------------------------------------------+
//| Draw range visualization on chart                                  |
//+------------------------------------------------------------------+
void DrawRange()
{
   if(!InpShowRange)
      return;
   
   if(g_rangeHigh <= 0 || g_rangeLow <= 0 || g_rangeHigh <= g_rangeLow)
      return;
   
   string prefix = "RangeBreakout_";
   
   // Draw range box
   string boxName = prefix + "Box_" + TimeToString(g_rangeStartTime, TIME_DATE);
   ObjectCreate(0, boxName, OBJ_RECTANGLE, 0, g_rangeStartTime, g_rangeHigh, g_rangeEndTime, g_rangeLow);
   ObjectSetInteger(0, boxName, OBJPROP_COLOR, InpRangeColor);
   ObjectSetInteger(0, boxName, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, boxName, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, boxName, OBJPROP_FILL, true);
   ObjectSetInteger(0, boxName, OBJPROP_BACK, true);
   ObjectSetInteger(0, boxName, OBJPROP_SELECTABLE, false);
   
   // Draw high line extended
   string highLineName = prefix + "High_" + TimeToString(g_rangeStartTime, TIME_DATE);
   ObjectCreate(0, highLineName, OBJ_TREND, 0, g_rangeEndTime, g_rangeHigh, g_closeTime, g_rangeHigh);
   ObjectSetInteger(0, highLineName, OBJPROP_COLOR, InpHighColor);
   ObjectSetInteger(0, highLineName, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, highLineName, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, highLineName, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, highLineName, OBJPROP_SELECTABLE, false);
   
   // Draw low line extended
   string lowLineName = prefix + "Low_" + TimeToString(g_rangeStartTime, TIME_DATE);
   ObjectCreate(0, lowLineName, OBJ_TREND, 0, g_rangeEndTime, g_rangeLow, g_closeTime, g_rangeLow);
   ObjectSetInteger(0, lowLineName, OBJPROP_COLOR, InpLowColor);
   ObjectSetInteger(0, lowLineName, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, lowLineName, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, lowLineName, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, lowLineName, OBJPROP_SELECTABLE, false);
   
   // Add range size label
   string labelName = prefix + "Label_" + TimeToString(g_rangeStartTime, TIME_DATE);
   double rangeSize = (g_rangeHigh - g_rangeLow) / _Point;
   ObjectCreate(0, labelName, OBJ_TEXT, 0, g_rangeStartTime, g_rangeHigh + 10 * _Point);
   ObjectSetString(0, labelName, OBJPROP_TEXT, "Range: " + DoubleToString(rangeSize, 0) + " pts");
   ObjectSetInteger(0, labelName, OBJPROP_COLOR, InpRangeColor);
   ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, labelName, OBJPROP_SELECTABLE, false);
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Trade transaction handler                                          |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   // Handle order fill events
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      if(trans.order_type == ORDER_TYPE_BUY || trans.order_type == ORDER_TYPE_BUY_STOP)
      {
         // Check if this is our buy order
         HistoryDealSelect(trans.deal);
         if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) == InpMagicNumber)
         {
            if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
            {
               g_buyTriggered = true;
               g_buyOrderPlaced = false;
               
               if(!InpTradeBothDirections || InpDeleteOnFirstFill)
               {
                  DeleteSellOrder();
               }
            }
         }
      }
      else if(trans.order_type == ORDER_TYPE_SELL || trans.order_type == ORDER_TYPE_SELL_STOP)
      {
         // Check if this is our sell order
         HistoryDealSelect(trans.deal);
         if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) == InpMagicNumber)
         {
            if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
            {
               g_sellTriggered = true;
               g_sellOrderPlaced = false;
               
               if(!InpTradeBothDirections || InpDeleteOnFirstFill)
               {
                  DeleteBuyOrder();
               }
            }
         }
      }
   }
}
//+------------------------------------------------------------------++
