//+------------------------------------------------------------------+
//|                                         GoldAI_ClaudeBot.mq5     |
//|          XAUUSD Trading Bot powered by Claude AI (Haiku)         |
//|                               Version 2.0 - 2025                 |
//+------------------------------------------------------------------+
//
// SETUP INSTRUCTIONS:
// 1. In MetaTrader 5: Tools > Options > Expert Advisors
// 2. Enable "Allow WebRequest for listed URL"
// 3. Add URL: https://api.anthropic.com
// 4. Fill in your Claude API key in InpApiKey parameter
// 5. Attach to XAUUSD M1 chart
//
#property copyright "GoldAI Bot - Claude Haiku Powered"
#property version   "2.00"
#property description "XAUUSD AI Trading Bot using Claude Haiku"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Input Parameters
input group "=== API Configuration ==="
input string   InpApiKey           = "sk-ant-YOUR-KEY-HERE";  // Anthropic API Key
input string   InpModel            = "claude-haiku-4-5-20251001"; // Claude Model
input int      InpAnalysisInterval = 12;              // Analysis interval (seconds)

input group "=== Risk Management ==="
input double   InpRiskPercent       = 1.0;            // Base risk per trade (% balance)
input double   InpMaxRiskPercent    = 2.5;            // Max risk at 100% confidence
input double   InpMinConfidence     = 55;             // Minimum confidence to trade (0-100)
input int      InpMaxPositions      = 3;              // Max simultaneous positions
input int      InpMaxSpreadPoints   = 80;             // Max spread in points

input group "=== Stop Loss / Take Profit ==="
input int      InpDefaultSL         = 30;             // Default SL in pips
input int      InpDefaultTP         = 60;             // Default TP in pips (2:1 R/R)
input bool     InpUseClaudeSLTP     = true;           // Use Claude SL/TP suggestions
input double   InpMinSLPips         = 15;             // Minimum SL distance (pips)
input double   InpMaxSLPips         = 80;             // Maximum SL distance (pips)

input group "=== Trailing Stop & Break-Even ==="
input bool     InpUseTrailingStop   = true;           // Enable adaptive trailing stop
input int      InpTrailingStart     = 20;             // Activate trailing at (pips profit)
input int      InpTrailingStep      = 15;             // Trailing stop distance (pips)
input bool     InpUseBreakEven      = true;           // Enable break-even
input int      InpBreakEvenAt       = 15;             // Move to break-even at (pips profit)
input int      InpBreakEvenBonus    = 3;              // Break-even buffer (pips above entry)

input group "=== Market Sessions ==="
input bool     InpTradeSydney       = true;           // Trade Sydney session
input bool     InpTradeTokyo        = true;           // Trade Tokyo session
input bool     InpTradeLondon       = true;           // Trade London session
input bool     InpTradeNewYork      = true;           // Trade New York session
input bool     InpTradeOverlap      = true;           // Trade session overlaps (high vol)

input group "=== EA Settings ==="
input int      InpMagicNumber       = 20250401;       // Magic number
input bool     InpEnableLogging     = true;           // Detailed logging
input bool     InpShowDashboard     = true;           // Show chart dashboard

//--- Global Objects
CTrade         g_trade;
CPositionInfo  g_position;

//--- Global State
datetime       g_lastAnalysisTime  = 0;
string         g_lastAction        = "HOLD";
int            g_lastConfidence    = 0;
double         g_lastSLPips        = 30;
double         g_lastTPPips        = 60;
string         g_lastReasoning     = "";
int            g_totalAnalyses     = 0;
int            g_totalTrades       = 0;
double         g_totalPnL          = 0;
double         g_pipSize           = 0.1; // XAUUSD: 1 pip = $0.1
int            g_apiErrors         = 0;


//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(30);
   g_trade.SetTypeFilling(ORDER_FILLING_FOK);

   // XAUUSD pip = 0.1 price unit
   g_pipSize = 0.1;

   if(StringFind(_Symbol, "XAU") < 0 && StringFind(_Symbol, "GOLD") < 0)
      Print("WARNING: EA optimized for XAUUSD. Current: ", _Symbol);

   Print("========================================");
   Print("  GoldAI Claude Bot v2.0 - STARTED");
   Print("========================================");
   Print("Model     : ", InpModel);
   Print("Interval  : ", InpAnalysisInterval, " seconds");
   Print("Risk      : ", InpRiskPercent, "% - ", InpMaxRiskPercent, "% (confidence-scaled)");
   Print("MinConf   : ", InpMinConfidence, "%");
   Print("Trailing  : ", InpUseTrailingStop ? "ON" : "OFF");
   Print("BreakEven : ", InpUseBreakEven ? "ON" : "OFF");
   Print("Sessions  : ",
      (InpTradeSydney  ? "Sydney " : ""),
      (InpTradeTokyo   ? "Tokyo " : ""),
      (InpTradeLondon  ? "London " : ""),
      (InpTradeNewYork ? "New York " : ""));
   Print("IMPORTANT : Add https://api.anthropic.com to MT5 Allowed URLs");
   Print("========================================");

   EventSetTimer(1);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
   Print("=== GoldAI Bot STOPPED ===");
   Print("Analyses: ", g_totalAnalyses, " | Trades: ", g_totalTrades, " | Net PnL: $", DoubleToString(g_totalPnL, 2));
}

//+------------------------------------------------------------------+
//| Timer function - manages trailing/BE on every second              |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(InpUseTrailingStop || InpUseBreakEven)
      ManagePositions();
   UpdateDashboard();
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check API call interval
   datetime currentTime = TimeCurrent();
   if(currentTime - g_lastAnalysisTime < InpAnalysisInterval) return;
   g_lastAnalysisTime = currentTime;

   // Trade conditions check
   if(!IsTradeAllowed()) return;

   long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spreadPoints > InpMaxSpreadPoints)
   {
      if(InpEnableLogging)
         Print("[SKIP] Spread too high: ", spreadPoints, " pts (max=", InpMaxSpreadPoints, ")");
      return;
   }

   if(!IsSessionAllowed())
   {
      if(InpEnableLogging)
         Print("[SKIP] Outside allowed trading sessions. Current: ", GetCurrentSession());
      return;
   }

   // Build market context
   string marketData = BuildMarketData();

   // Query Claude Haiku
   if(InpEnableLogging)
      Print("[API] Sending analysis request #", g_totalAnalyses + 1, " | Session: ", GetCurrentSession());

   bool success = QueryClaude(marketData);
   g_totalAnalyses++;

   if(!success)
   {
      g_apiErrors++;
      Print("[ERROR] Claude query failed (total errors: ", g_apiErrors, ")");
      return;
   }

   g_apiErrors = 0;

   Print("[SIGNAL] ", g_lastAction,
         " | Confidence: ", g_lastConfidence, "%",
         " | SL: ", g_lastSLPips, " pips",
         " | TP: ", g_lastTPPips, " pips",
         " | ", g_lastReasoning);

   // Execute trade if signal is strong enough
   if(g_lastAction != "HOLD" && g_lastConfidence >= InpMinConfidence)
   {
      int currentPositions = CountPositions();
      if(currentPositions < InpMaxPositions)
      {
         ExecuteSignal();
      }
      else
      {
         if(InpEnableLogging)
            Print("[SKIP] Max positions reached (", currentPositions, "/", InpMaxPositions, ")");
      }
   }
}


//+------------------------------------------------------------------+
//| Build comprehensive market data string for Claude                  |
//+------------------------------------------------------------------+
string BuildMarketData()
{
   string data = "";
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   string timeStr = StringFormat("%04d-%02d-%02d %02d:%02d UTC",
      dt.year, dt.mon, dt.day, dt.hour, dt.min);

   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double spread = ask - bid;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   int    openPos  = CountPositions();
   double drawdown = balance > 0 ? (balance - equity) / balance * 100.0 : 0;

   //--- Header
   data += "=== XAUUSD MARKET ANALYSIS ===\n";
   data += "Time: " + timeStr + " | Session: " + GetCurrentSession() + "\n";
   data += StringFormat("Account: Balance=%.2f Equity=%.2f FreeMargin=%.2f Drawdown=%.1f%%\n",
      balance, equity, freeMargin, drawdown);
   data += StringFormat("Price: Bid=%.2f Ask=%.2f Spread=%.2f\n", bid, ask, spread);
   data += StringFormat("OpenPositions: %d/%d\n\n", openPos, InpMaxPositions);

   //--- ATR (volatility measure)
   int atrH1 = iATR(_Symbol, PERIOD_H1, 14);
   int atrM15 = iATR(_Symbol, PERIOD_M15, 14);
   double atrH1Buf[], atrM15Buf[];
   ArraySetAsSeries(atrH1Buf, true);
   ArraySetAsSeries(atrM15Buf, true);
   if(atrH1 != INVALID_HANDLE)
   {
      CopyBuffer(atrH1, 0, 0, 1, atrH1Buf);
      IndicatorRelease(atrH1);
   }
   if(atrM15 != INVALID_HANDLE)
   {
      CopyBuffer(atrM15, 0, 0, 1, atrM15Buf);
      IndicatorRelease(atrM15);
   }
   double atrH1Val  = ArraySize(atrH1Buf) > 0  ? atrH1Buf[0]  : 0;
   double atrM15Val = ArraySize(atrM15Buf) > 0 ? atrM15Buf[0] : 0;
   data += StringFormat("Volatility: ATR(14,H1)=%.2f ATR(14,M15)=%.2f\n\n", atrH1Val, atrM15Val);

   //--- M5 candles (last 20, for short-term momentum)
   MqlRates ratesM5[];
   ArraySetAsSeries(ratesM5, true);
   int copiedM5 = CopyRates(_Symbol, PERIOD_M5, 0, 20, ratesM5);
   if(copiedM5 > 0)
   {
      data += "M5 Candles (20 newest, O/H/L/C/Vol):\n";
      for(int i = 0; i < MathMin(copiedM5, 20); i++)
         data += StringFormat("%.2f,%.2f,%.2f,%.2f,%lld\n",
            ratesM5[i].open, ratesM5[i].high, ratesM5[i].low,
            ratesM5[i].close, ratesM5[i].tick_volume);
      data += "\n";
   }

   //--- M15 candles (last 15)
   MqlRates ratesM15[];
   ArraySetAsSeries(ratesM15, true);
   int copiedM15 = CopyRates(_Symbol, PERIOD_M15, 0, 15, ratesM15);
   if(copiedM15 > 0)
   {
      data += "M15 Candles (15 newest, O/H/L/C):\n";
      for(int i = 0; i < MathMin(copiedM15, 15); i++)
         data += StringFormat("%.2f,%.2f,%.2f,%.2f\n",
            ratesM15[i].open, ratesM15[i].high, ratesM15[i].low, ratesM15[i].close);
      data += "\n";
   }

   //--- H1 candles (last 8, for trend context)
   MqlRates ratesH1[];
   ArraySetAsSeries(ratesH1, true);
   int copiedH1 = CopyRates(_Symbol, PERIOD_H1, 0, 8, ratesH1);
   if(copiedH1 > 0)
   {
      data += "H1 Candles (8 newest, O/H/L/C):\n";
      for(int i = 0; i < MathMin(copiedH1, 8); i++)
         data += StringFormat("%.2f,%.2f,%.2f,%.2f\n",
            ratesH1[i].open, ratesH1[i].high, ratesH1[i].low, ratesH1[i].close);
      data += "\n";
   }

   //--- Technical Indicators
   data += "=== INDICATORS ===\n";

   // RSI M5 and M15
   int rsiM5  = iRSI(_Symbol, PERIOD_M5,  14, PRICE_CLOSE);
   int rsiM15 = iRSI(_Symbol, PERIOD_M15, 14, PRICE_CLOSE);
   double rsiM5Buf[], rsiM15Buf[];
   ArraySetAsSeries(rsiM5Buf,  true);
   ArraySetAsSeries(rsiM15Buf, true);
   if(rsiM5 != INVALID_HANDLE)
   {
      CopyBuffer(rsiM5, 0, 0, 3, rsiM5Buf);
      IndicatorRelease(rsiM5);
   }
   if(rsiM15 != INVALID_HANDLE)
   {
      CopyBuffer(rsiM15, 0, 0, 3, rsiM15Buf);
      IndicatorRelease(rsiM15);
   }
   if(ArraySize(rsiM5Buf) >= 2)
      data += StringFormat("RSI(14,M5)=%.1f prev=%.1f\n", rsiM5Buf[0], rsiM5Buf[1]);
   if(ArraySize(rsiM15Buf) >= 2)
      data += StringFormat("RSI(14,M15)=%.1f prev=%.1f\n", rsiM15Buf[0], rsiM15Buf[1]);

   // MACD M15
   int macdH = iMACD(_Symbol, PERIOD_M15, 12, 26, 9, PRICE_CLOSE);
   double macdMain[], macdSig[];
   ArraySetAsSeries(macdMain, true);
   ArraySetAsSeries(macdSig,  true);
   if(macdH != INVALID_HANDLE)
   {
      CopyBuffer(macdH, 0, 0, 3, macdMain);
      CopyBuffer(macdH, 1, 0, 3, macdSig);
      IndicatorRelease(macdH);
      if(ArraySize(macdMain) >= 2)
         data += StringFormat("MACD(12,26,9,M15): main=%.4f sig=%.4f hist=%.4f prevHist=%.4f\n",
            macdMain[0], macdSig[0], macdMain[0]-macdSig[0], macdMain[1]-macdSig[1]);
   }

   // Bollinger Bands M15
   int bbH = iBands(_Symbol, PERIOD_M15, 20, 0, 2.0, PRICE_CLOSE);
   double bbUp[], bbMid[], bbLow[];
   ArraySetAsSeries(bbUp,  true);
   ArraySetAsSeries(bbMid, true);
   ArraySetAsSeries(bbLow, true);
   if(bbH != INVALID_HANDLE)
   {
      CopyBuffer(bbH, 1, 0, 1, bbUp);
      CopyBuffer(bbH, 0, 0, 1, bbMid);
      CopyBuffer(bbH, 2, 0, 1, bbLow);
      IndicatorRelease(bbH);
      if(ArraySize(bbUp) > 0)
      {
         double bbPos = (bbUp[0] - bbLow[0]) > 0
            ? (bid - bbLow[0]) / (bbUp[0] - bbLow[0]) * 100.0 : 50;
         data += StringFormat("BB(20,M15): U=%.2f M=%.2f L=%.2f BandPos=%.0f%%\n",
            bbUp[0], bbMid[0], bbLow[0], bbPos);
      }
   }

   // EMAs
   int ema20M5H  = iMA(_Symbol, PERIOD_M5,  20,  0, MODE_EMA, PRICE_CLOSE);
   int ema20M15H = iMA(_Symbol, PERIOD_M15, 20,  0, MODE_EMA, PRICE_CLOSE);
   int ema50M15H = iMA(_Symbol, PERIOD_M15, 50,  0, MODE_EMA, PRICE_CLOSE);
   int ema200H1H = iMA(_Symbol, PERIOD_H1,  200, 0, MODE_EMA, PRICE_CLOSE);
   double ema20M5Buf[], ema20M15Buf[], ema50M15Buf[], ema200H1Buf[];
   ArraySetAsSeries(ema20M5Buf,  true);
   ArraySetAsSeries(ema20M15Buf, true);
   ArraySetAsSeries(ema50M15Buf, true);
   ArraySetAsSeries(ema200H1Buf, true);
   double ema20M5=0, ema20M15=0, ema50M15=0, ema200H1=0;
   if(ema20M5H  != INVALID_HANDLE){ CopyBuffer(ema20M5H,  0,0,1,ema20M5Buf);  ema20M5=ema20M5Buf[0];   IndicatorRelease(ema20M5H);  }
   if(ema20M15H != INVALID_HANDLE){ CopyBuffer(ema20M15H, 0,0,1,ema20M15Buf); ema20M15=ema20M15Buf[0]; IndicatorRelease(ema20M15H); }
   if(ema50M15H != INVALID_HANDLE){ CopyBuffer(ema50M15H, 0,0,1,ema50M15Buf); ema50M15=ema50M15Buf[0]; IndicatorRelease(ema50M15H); }
   if(ema200H1H != INVALID_HANDLE){ CopyBuffer(ema200H1H, 0,0,1,ema200H1Buf); ema200H1=ema200H1Buf[0]; IndicatorRelease(ema200H1H); }
   data += StringFormat("EMA: 20M5=%.2f 20M15=%.2f 50M15=%.2f 200H1=%.2f\n",
      ema20M5, ema20M15, ema50M15, ema200H1);

   // Stochastic M15
   int stochH = iStochastic(_Symbol, PERIOD_M15, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
   double stochK[], stochD[];
   ArraySetAsSeries(stochK, true);
   ArraySetAsSeries(stochD, true);
   if(stochH != INVALID_HANDLE)
   {
      CopyBuffer(stochH, 0, 0, 3, stochK);
      CopyBuffer(stochH, 1, 0, 3, stochD);
      IndicatorRelease(stochH);
      if(ArraySize(stochK) >= 2)
         data += StringFormat("Stoch(5,3,3,M15): K=%.1f D=%.1f prevK=%.1f\n",
            stochK[0], stochD[0], stochK[1]);
   }

   // ADX M15
   int adxH = iADX(_Symbol, PERIOD_M15, 14);
   double adxBuf[], diPlus[], diMinus[];
   ArraySetAsSeries(adxBuf,   true);
   ArraySetAsSeries(diPlus,   true);
   ArraySetAsSeries(diMinus,  true);
   if(adxH != INVALID_HANDLE)
   {
      CopyBuffer(adxH, 0, 0, 1, adxBuf);
      CopyBuffer(adxH, 1, 0, 1, diPlus);
      CopyBuffer(adxH, 2, 0, 1, diMinus);
      IndicatorRelease(adxH);
      if(ArraySize(adxBuf) > 0)
         data += StringFormat("ADX(14,M15)=%.1f DI+=%.1f DI-=%.1f Trend=%s\n",
            adxBuf[0], diPlus[0], diMinus[0],
            adxBuf[0] > 25 ? (diPlus[0] > diMinus[0] ? "UP" : "DOWN") : "WEAK");
   }

   // CCI M15
   int cciH = iCCI(_Symbol, PERIOD_M15, 20, PRICE_TYPICAL);
   double cciBuf[];
   ArraySetAsSeries(cciBuf, true);
   if(cciH != INVALID_HANDLE)
   {
      CopyBuffer(cciH, 0, 0, 2, cciBuf);
      IndicatorRelease(cciH);
      if(ArraySize(cciBuf) > 0)
         data += StringFormat("CCI(20,M15)=%.1f\n", cciBuf[0]);
   }

   //--- Market structure
   data += "\n=== MARKET STRUCTURE ===\n";
   string h1Trend = bid > ema200H1 ? "BULLISH (above EMA200H1)" : "BEARISH (below EMA200H1)";
   string m15Trend = ema20M15 > ema50M15 ? "BULLISH (EMA20>EMA50)" : "BEARISH (EMA20<EMA50)";
   data += "H1 Trend: " + h1Trend + "\n";
   data += "M15 Trend: " + m15Trend + "\n";

   // Support/Resistance from recent H1 highs/lows
   if(copiedH1 >= 8)
   {
      double highH = ratesH1[0].high;
      double lowL  = ratesH1[0].low;
      for(int i = 1; i < MathMin(copiedH1, 8); i++)
      {
         if(ratesH1[i].high > highH) highH = ratesH1[i].high;
         if(ratesH1[i].low  < lowL)  lowL  = ratesH1[i].low;
      }
      data += StringFormat("H1 Range (8 bars): High=%.2f Low=%.2f\n", highH, lowL);
   }

   //--- Open positions summary
   if(openPos > 0)
   {
      data += "\n=== OPEN POSITIONS ===\n";
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(g_position.SelectByIndex(i) &&
            g_position.Symbol() == _Symbol &&
            g_position.Magic()  == InpMagicNumber)
         {
            double posProfitPips = g_position.PositionType() == POSITION_TYPE_BUY
               ? (bid - g_position.PriceOpen()) / g_pipSize
               : (g_position.PriceOpen() - ask) / g_pipSize;
            data += StringFormat("%s %.2flots @%.2f SL=%.2f TP=%.2f Profit=%.1fpips $%.1f\n",
               g_position.PositionType() == POSITION_TYPE_BUY ? "BUY" : "SELL",
               g_position.Volume(),
               g_position.PriceOpen(),
               g_position.StopLoss(),
               g_position.TakeProfit(),
               posProfitPips,
               g_position.Profit());
         }
      }
   }

   return data;
}


//+------------------------------------------------------------------+
//| Query Claude Haiku API via WebRequest                              |
//+------------------------------------------------------------------+
bool QueryClaude(string marketData)
{
   string systemPrompt = "You are an expert XAUUSD (Gold) scalp and swing trader. "
      "Analyze the provided multi-timeframe market data and technical indicators. "
      "Be DECISIVE. When conditions align (RSI, MACD, EMA alignment, ADX trend strength), "
      "give a clear BUY or SELL signal. Trade ALL sessions including Asian and off-hours. "
      "Look for: momentum breakouts, RSI divergence, MACD crossovers, EMA bounces, "
      "BB squeezes, CCI extremes. Set tight SL (15-40 pips) and generous TP (30-80 pips). "
      "Only output HOLD if conditions are genuinely mixed. Be aggressive when aligned.";

   string userContent = marketData
      + "\n\nProvide your trading decision. "
      + "Respond ONLY with this exact JSON (no markdown, no extra text):\n"
      + "{\"action\":\"BUY\",\"confidence\":75,\"sl_pips\":25,\"tp_pips\":55,"
      + "\"reasoning\":\"brief reason under 60 chars\"}";

   // Escape for JSON payload
   string escapedSystem = EscapeJSON(systemPrompt);
   string escapedUser   = EscapeJSON(userContent);

   string payload = "{";
   payload += "\"model\":\"" + InpModel + "\",";
   payload += "\"max_tokens\":180,";
   payload += "\"system\":\"" + escapedSystem + "\",";
   payload += "\"messages\":[{\"role\":\"user\",\"content\":\"" + escapedUser + "\"}]";
   payload += "}";

   string headers = "Content-Type: application/json\r\n"
      + "x-api-key: " + InpApiKey + "\r\n"
      + "anthropic-version: 2023-06-01\r\n";

   uchar postData[];
   uchar responseData[];
   string responseHeaders;

   int payloadLen = StringToCharArray(payload, postData, 0, StringLen(payload));
   ArrayResize(postData, payloadLen);

   int timeout = 15000; // 15 second timeout
   int httpCode = WebRequest(
      "POST",
      "https://api.anthropic.com/v1/messages",
      headers,
      timeout,
      postData,
      responseData,
      responseHeaders
   );

   if(httpCode == -1)
   {
      int err = GetLastError();
      Print("[API ERROR] WebRequest failed. Error=", err,
         ". Ensure https://api.anthropic.com is in MT5 Allowed URLs (Tools>Options>Expert Advisors).");
      return false;
   }

   if(httpCode != 200)
   {
      string errResp = CharArrayToString(responseData);
      Print("[API ERROR] HTTP ", httpCode, ": ", StringSubstr(errResp, 0, 300));
      return false;
   }

   string response = CharArrayToString(responseData);
   if(InpEnableLogging)
      Print("[API] Response: ", StringSubstr(response, 0, 600));

   return ParseClaudeResponse(response);
}

//+------------------------------------------------------------------+
//| Parse Claude API JSON response                                     |
//+------------------------------------------------------------------+
bool ParseClaudeResponse(string response)
{
   // Find the "text" field in the Anthropic API response
   // Format: {..., "content": [{"type": "text", "text": "{...json...}"}], ...}
   int textStart = StringFind(response, "\"text\":\"");
   if(textStart < 0)
   {
      Print("[PARSE ERROR] No 'text' field found in response");
      return false;
   }
   textStart += 8;

   // Find closing unescaped quote
   int textEnd = textStart;
   int respLen = StringLen(response);
   while(textEnd < respLen)
   {
      ushort ch   = StringGetCharacter(response, textEnd);
      ushort prev = textEnd > 0 ? StringGetCharacter(response, textEnd - 1) : 0;
      if(ch == '"' && prev != '\\') break;
      textEnd++;
   }

   string rawText = StringSubstr(response, textStart, textEnd - textStart);
   rawText = UnescapeJSON(rawText);

   if(InpEnableLogging)
      Print("[PARSE] Claude text: ", rawText);

   // Find the JSON object within Claude's text response
   int jsonStart = StringFind(rawText, "{");
   int jsonEnd   = StringFind(rawText, "}", jsonStart);
   if(jsonStart < 0 || jsonEnd < 0)
   {
      Print("[PARSE ERROR] No JSON object found in: ", rawText);
      return false;
   }

   string jsonStr = StringSubstr(rawText, jsonStart, jsonEnd - jsonStart + 1);

   // Extract fields
   g_lastAction = ExtractJSONString(jsonStr, "action");
   if(g_lastAction == "") g_lastAction = "HOLD";
   StringToUpper(g_lastAction);

   string confStr = ExtractJSONNumber(jsonStr, "confidence");
   g_lastConfidence = (int)StringToInteger(confStr);
   if(g_lastConfidence <= 0 || g_lastConfidence > 100) g_lastConfidence = 50;

   string slStr = ExtractJSONNumber(jsonStr, "sl_pips");
   g_lastSLPips = StringToDouble(slStr);
   if(g_lastSLPips < InpMinSLPips) g_lastSLPips = InpMinSLPips;
   if(g_lastSLPips > InpMaxSLPips) g_lastSLPips = InpMaxSLPips;

   string tpStr = ExtractJSONNumber(jsonStr, "tp_pips");
   g_lastTPPips = StringToDouble(tpStr);
   if(g_lastTPPips <= 0) g_lastTPPips = g_lastSLPips * 2;

   g_lastReasoning = ExtractJSONString(jsonStr, "reasoning");

   return true;
}

//+------------------------------------------------------------------+
//| Execute trade based on Claude's signal                             |
//+------------------------------------------------------------------+
void ExecuteSignal()
{
   if(g_lastAction != "BUY" && g_lastAction != "SELL") return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double lots    = CalculateLots(g_lastConfidence, g_lastSLPips);
   double slPips  = InpUseClaudeSLTP ? g_lastSLPips : InpDefaultSL;
   double tpPips  = InpUseClaudeSLTP ? g_lastTPPips : InpDefaultTP;

   string comment = StringFormat("GoldAI|c=%d|%s", g_lastConfidence, g_lastReasoning);

   if(g_lastAction == "BUY")
   {
      double slPrice = NormalizeDouble(ask - slPips * g_pipSize, _Digits);
      double tpPrice = NormalizeDouble(ask + tpPips * g_pipSize, _Digits);

      if(g_trade.Buy(lots, _Symbol, ask, slPrice, tpPrice, comment))
      {
         g_totalTrades++;
         Print("[TRADE] BUY opened | lots=", lots, " @ ", ask,
               " | SL=", slPrice, " TP=", tpPrice,
               " | Risk=", DoubleToString(g_lastSLPips, 1), "p",
               " | Reward=", DoubleToString(g_lastTPPips, 1), "p",
               " | conf=", g_lastConfidence, "%");
      }
      else
      {
         Print("[TRADE ERROR] BUY failed: ", g_trade.ResultRetcodeDescription(),
               " (", g_trade.ResultRetcode(), ")");
      }
   }
   else // SELL
   {
      double slPrice = NormalizeDouble(bid + slPips * g_pipSize, _Digits);
      double tpPrice = NormalizeDouble(bid - tpPips * g_pipSize, _Digits);

      if(g_trade.Sell(lots, _Symbol, bid, slPrice, tpPrice, comment))
      {
         g_totalTrades++;
         Print("[TRADE] SELL opened | lots=", lots, " @ ", bid,
               " | SL=", slPrice, " TP=", tpPrice,
               " | Risk=", DoubleToString(g_lastSLPips, 1), "p",
               " | Reward=", DoubleToString(g_lastTPPips, 1), "p",
               " | conf=", g_lastConfidence, "%");
      }
      else
      {
         Print("[TRADE ERROR] SELL failed: ", g_trade.ResultRetcodeDescription(),
               " (", g_trade.ResultRetcode(), ")");
      }
   }
}

//+------------------------------------------------------------------+
//| Dynamic lot sizing: risk-based with confidence multiplier          |
//+------------------------------------------------------------------+
double CalculateLots(int confidence, double slPips)
{
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double minLot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   // Scale risk linearly from InpRiskPercent (conf=0) to InpMaxRiskPercent (conf=100)
   double confFactor  = MathMax(0.0, MathMin(1.0, (double)confidence / 100.0));
   double riskPercent = InpRiskPercent + (InpMaxRiskPercent - InpRiskPercent) * confFactor;
   double riskAmount  = balance * riskPercent / 100.0;

   // Pip value per standard lot (for XAUUSD on USD account)
   double pipValuePerLot = 10.0; // Default: 1 pip on XAUUSD = $10 per standard lot
   if(tickSize > 0.0 && tickValue > 0.0)
      pipValuePerLot = (g_pipSize / tickSize) * tickValue;

   double lots = riskAmount / (slPips * pipValuePerLot);

   // Normalize to lot step
   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));

   if(InpEnableLogging)
      Print("[LOTS] conf=", confidence, "% riskPct=", DoubleToString(riskPercent, 2),
            "% riskAmt=$", DoubleToString(riskAmount, 2), " lots=", DoubleToString(lots, 2));

   return NormalizeDouble(lots, 2);
}


//+------------------------------------------------------------------+
//| Manage open positions: adaptive trailing stop & break-even        |
//+------------------------------------------------------------------+
void ManagePositions()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!g_position.SelectByIndex(i))   continue;
      if(g_position.Symbol() != _Symbol) continue;
      if(g_position.Magic()  != InpMagicNumber) continue;

      ulong  ticket     = g_position.Ticket();
      double openPrice  = g_position.PriceOpen();
      double currentSL  = g_position.StopLoss();
      double currentTP  = g_position.TakeProfit();
      bool   modified   = false;
      double newSL      = currentSL;

      if(g_position.PositionType() == POSITION_TYPE_BUY)
      {
         double profitPips = (bid - openPrice) / g_pipSize;

         // --- Break-even ---
         if(InpUseBreakEven && profitPips >= InpBreakEvenAt)
         {
            double beSL = NormalizeDouble(openPrice + InpBreakEvenBonus * g_pipSize, _Digits);
            if(currentSL < beSL - _Point * 5)
            {
               newSL = beSL;
               modified = true;
               if(InpEnableLogging)
                  Print("[BE] BUY ticket=", ticket, " SL -> BE=", newSL,
                        " profit=", DoubleToString(profitPips, 1), "p");
            }
         }

         // --- Trailing Stop ---
         if(InpUseTrailingStop && profitPips >= InpTrailingStart)
         {
            double trailSL = NormalizeDouble(bid - InpTrailingStep * g_pipSize, _Digits);
            if(trailSL > newSL + _Point * 5)
            {
               newSL = trailSL;
               modified = true;
               if(InpEnableLogging)
                  Print("[TRAIL] BUY ticket=", ticket, " SL -> ", newSL,
                        " profit=", DoubleToString(profitPips, 1), "p");
            }
         }

         if(modified)
            g_trade.PositionModify(ticket, newSL, currentTP);
      }
      else // POSITION_TYPE_SELL
      {
         double profitPips = (openPrice - ask) / g_pipSize;

         // --- Break-even ---
         if(InpUseBreakEven && profitPips >= InpBreakEvenAt)
         {
            double beSL = NormalizeDouble(openPrice - InpBreakEvenBonus * g_pipSize, _Digits);
            if(currentSL == 0 || currentSL > beSL + _Point * 5)
            {
               newSL = beSL;
               modified = true;
               if(InpEnableLogging)
                  Print("[BE] SELL ticket=", ticket, " SL -> BE=", newSL,
                        " profit=", DoubleToString(profitPips, 1), "p");
            }
         }

         // --- Trailing Stop ---
         if(InpUseTrailingStop && profitPips >= InpTrailingStart)
         {
            double trailSL = NormalizeDouble(ask + InpTrailingStep * g_pipSize, _Digits);
            if(currentSL == 0 || trailSL < newSL - _Point * 5)
            {
               newSL = trailSL;
               modified = true;
               if(InpEnableLogging)
                  Print("[TRAIL] SELL ticket=", ticket, " SL -> ", newSL,
                        " profit=", DoubleToString(profitPips, 1), "p");
            }
         }

         if(modified)
            g_trade.PositionModify(ticket, newSL, currentTP);
      }
   }
}

//+------------------------------------------------------------------+
//| Update chart dashboard with live info                              |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   if(!InpShowDashboard) return;

   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double floatPL = equity - balance;

   // Calculate open position PnL
   double openPL = 0;
   int    nPos   = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(g_position.SelectByIndex(i) &&
         g_position.Symbol() == _Symbol &&
         g_position.Magic()  == InpMagicNumber)
      {
         openPL += g_position.Profit();
         nPos++;
      }
   }

   datetime nextCall = g_lastAnalysisTime + InpAnalysisInterval;
   int secsToNext    = (int)(nextCall - TimeCurrent());
   if(secsToNext < 0) secsToNext = 0;

   string dash = "";
   dash += "╔══════════════════════════════╗\n";
   dash += "║   GoldAI Claude Bot v2.0     ║\n";
   dash += "╠══════════════════════════════╣\n";
   dash += StringFormat("║ Price    : %.2f            ║\n", bid);
   dash += StringFormat("║ Session  : %-18s║\n", GetCurrentSession());
   dash += StringFormat("║ Balance  : $%-17.2f║\n", balance);
   dash += StringFormat("║ Equity   : $%-17.2f║\n", equity);
   dash += StringFormat("║ Float PL : $%-17.2f║\n", floatPL);
   dash += "╠══════════════════════════════╣\n";
   dash += StringFormat("║ Last Signal : %-15s║\n",
      g_lastAction + " (" + IntegerToString(g_lastConfidence) + "%)");
   dash += StringFormat("║ Next Call : %-4ds                ║\n", secsToNext);
   dash += StringFormat("║ Analyses  : %-17d║\n", g_totalAnalyses);
   dash += StringFormat("║ Trades    : %-17d║\n", g_totalTrades);
   dash += StringFormat("║ Positions : %d/%-15d║\n", nPos, InpMaxPositions);
   dash += StringFormat("║ Open PnL  : $%-17.2f║\n", openPL);
   if(g_lastReasoning != "")
      dash += StringFormat("║ Reason: %-22s║\n", StringSubstr(g_lastReasoning, 0, 22));
   dash += "╚══════════════════════════════╝";

   Comment(dash);
}

//+------------------------------------------------------------------+
//| Count EA positions for this symbol                                 |
//+------------------------------------------------------------------+
int CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(g_position.SelectByIndex(i) &&
         g_position.Symbol() == _Symbol &&
         g_position.Magic()  == InpMagicNumber)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Check if current session is allowed                                |
//+------------------------------------------------------------------+
bool IsSessionAllowed()
{
   // If all disabled by user → always trade
   if(!InpTradeSydney && !InpTradeTokyo && !InpTradeLondon && !InpTradeNewYork)
      return true;

   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int h = dt.hour;

   // Sydney  : 22:00 - 07:00 UTC
   if(InpTradeSydney && (h >= 22 || h < 7))    return true;
   // Tokyo   : 00:00 - 09:00 UTC
   if(InpTradeTokyo  && h >= 0 && h < 9)        return true;
   // London  : 07:00 - 16:00 UTC
   if(InpTradeLondon && h >= 7 && h < 16)       return true;
   // New York: 13:00 - 22:00 UTC
   if(InpTradeNewYork && h >= 13 && h < 22)     return true;
   // Overlaps (high volatility)
   if(InpTradeOverlap && h >= 13 && h < 16)     return true; // London/NY overlap

   return false;
}

//+------------------------------------------------------------------+
//| Get current session name(s)                                        |
//+------------------------------------------------------------------+
string GetCurrentSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int h = dt.hour;

   string s = "";
   if(h >= 22 || h < 7)    s += "Sydney/";
   if(h >= 0  && h < 9)    s += "Tokyo/";
   if(h >= 7  && h < 16)   s += "London/";
   if(h >= 13 && h < 22)   s += "NewYork/";
   if(s == "") s = "OffHours/";

   // Remove trailing slash
   if(StringLen(s) > 0 && StringGetCharacter(s, StringLen(s)-1) == '/')
      s = StringSubstr(s, 0, StringLen(s)-1);
   return s;
}

//+------------------------------------------------------------------+
//| Check trading permissions                                          |
//+------------------------------------------------------------------+
bool IsTradeAllowed()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      Print("[WARN] Trading disabled in terminal.");
      return false;
   }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      Print("[WARN] Trading disabled for this EA (check algo trading button).");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Extract string value from a flat JSON object                       |
//+------------------------------------------------------------------+
string ExtractJSONString(const string json, const string key)
{
   string searchKey = "\"" + key + "\":\"";
   int start = StringFind(json, searchKey);
   if(start < 0) return "";
   start += StringLen(searchKey);
   int end = start;
   int len = StringLen(json);
   while(end < len)
   {
      ushort ch   = StringGetCharacter(json, end);
      ushort prev = end > 0 ? StringGetCharacter(json, end - 1) : 0;
      if(ch == '"' && prev != '\\') break;
      end++;
   }
   return StringSubstr(json, start, end - start);
}

//+------------------------------------------------------------------+
//| Extract numeric value from a flat JSON object                      |
//+------------------------------------------------------------------+
string ExtractJSONNumber(const string json, const string key)
{
   string searchKey = "\"" + key + "\":";
   int start = StringFind(json, searchKey);
   if(start < 0) return "0";
   start += StringLen(searchKey);
   int len = StringLen(json);
   // Skip whitespace
   while(start < len && StringGetCharacter(json, start) == ' ') start++;
   int end = start;
   while(end < len)
   {
      ushort ch = StringGetCharacter(json, end);
      if((ch >= '0' && ch <= '9') || ch == '.' || ch == '-') end++;
      else break;
   }
   return StringSubstr(json, start, end - start);
}

//+------------------------------------------------------------------+
//| Escape string for JSON payload                                     |
//+------------------------------------------------------------------+
string EscapeJSON(string text)
{
   StringReplace(text, "\\", "\\\\");
   StringReplace(text, "\"", "\\\"");
   StringReplace(text, "\n", "\\n");
   StringReplace(text, "\r", "\\r");
   StringReplace(text, "\t", "\\t");
   return text;
}

//+------------------------------------------------------------------+
//| Unescape JSON encoded string                                       |
//+------------------------------------------------------------------+
string UnescapeJSON(string text)
{
   StringReplace(text, "\\n",  "\n");
   StringReplace(text, "\\r",  "\r");
   StringReplace(text, "\\t",  "\t");
   StringReplace(text, "\\\"", "\"");
   StringReplace(text, "\\\\", "\\");
   return text;
}

//+------------------------------------------------------------------+
//| Trade transaction callback (log closed trade PnL)                  |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult  &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong dealTicket = trans.deal;
      if(dealTicket > 0 && HistoryDealSelect(dealTicket))
      {
         long magic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
         if(magic == InpMagicNumber)
         {
            double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
            double comm   = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
            double swap   = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
            double net    = profit + comm + swap;
            if(profit != 0.0)
            {
               g_totalPnL += net;
               Print("[CLOSED] Profit=", DoubleToString(profit, 2),
                     " Comm=", DoubleToString(comm, 2),
                     " Net=", DoubleToString(net, 2),
                     " | TotalPnL=$", DoubleToString(g_totalPnL, 2));
            }
         }
      }
   }
}
//+------------------------------------------------------------------+
