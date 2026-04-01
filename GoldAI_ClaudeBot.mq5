//+------------------------------------------------------------------+
//|                                         GoldAI_ClaudeBot.mq5     |
//|       XAUUSD AI Scalp/Swing Bot - Claude Haiku v3.0 ULTIMATE     |
//|                  Multi-position | Exponential Lots | Full Mgmt    |
//+------------------------------------------------------------------+
//
// SETUP:
// 1. Tools > Options > Expert Advisors > Allow WebRequest
//    Add: https://api.anthropic.com
// 2. Renseigner InpApiKey avec votre clé Anthropic
// 3. Attacher sur XAUUSD M1
// 4. Activer "Algo Trading" (bouton vert MT5)
//
#property copyright "GoldAI Bot v3.0 - Claude Haiku ULTIMATE"
#property version   "3.00"
#property description "XAUUSD Scalp/Swing AI Bot | 8 positions | Exp Lots | Portfolio Mgmt"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//=== API ===
input group "=== API Configuration ==="
input string   InpApiKey            = "sk-ant-YOUR-KEY-HERE"; // Cle API Anthropic
input string   InpModel             = "claude-haiku-4-5-20251001"; // Modele Claude
input int      InpAnalysisInterval  = 12;   // Intervalle analyse (secondes)

//=== RISK ===
input group "=== Risk & Lot Management ==="
input double   InpBaseLot           = 0.01; // Lot de base (confidence minimale)
input double   InpMaxLot            = 2.0;  // Lot maximum absolu
input double   InpMaxRiskPct        = 2.0;  // Risque max par trade (% balance)
input bool     InpExponentialLots   = true; // Lots exponentiels selon confiance
input double   InpExpBase           = 2.2;  // Base exponentielle (2.2 = agressif)
input double   InpMinConfidence     = 55;   // Confiance minimale pour trader
input int      InpMaxPositions      = 8;    // Positions simultanees max
input int      InpMaxSpreadPoints   = 80;   // Spread max en points

//=== SL/TP ===
input group "=== Stop Loss / Take Profit ==="
input int      InpDefaultSL         = 25;   // SL par defaut (pips)
input int      InpDefaultTP         = 45;   // TP par defaut (pips)
input bool     InpUseClaudeSLTP     = true; // Utiliser SL/TP de Claude
input double   InpMinSLPips         = 10;   // SL minimum (pips scalp)
input double   InpMaxSLPips         = 80;   // SL maximum (pips)

//=== TRAILING ===
input group "=== Trailing Stop & Break-Even ==="
input bool     InpUseTrailing       = true; // Trailing stop adaptatif
input int      InpTrailingStart     = 18;   // Activer trailing apres (pips)
input int      InpTrailingStep      = 12;   // Distance trailing (pips)
input bool     InpUseBreakEven      = true; // Break-even
input int      InpBreakEvenAt       = 12;   // Break-even a (pips profit)
input int      InpBreakEvenBonus    = 2;    // Bonus BE (pips au-dessus entree)

//=== PORTFOLIO MGMT ===
input group "=== Portfolio Management (Claude) ==="
input bool     InpCloseOnSignalFlip = true; // Fermer positions contraires sur signal fort
input bool     InpAllowHedge        = false;// Autoriser hedging (BUY+SELL simultane)
input double   InpMaxLossToClose    = -50;  // PnL seuil fermeture position perdante ($)
input bool     InpCloseLosersOnSig  = true; // Fermer perdantes sur signal opposé fort
input int      InpMinConfToCloseBad = 80;   // Confiance min pour forcer fermeture

//=== SESSIONS ===
input group "=== Market Sessions ==="
input bool     InpTradeSydney       = true;
input bool     InpTradeTokyo        = true;
input bool     InpTradeLondon       = true;
input bool     InpTradeNewYork      = true;

//=== EA ===
input group "=== EA Settings ==="
input int      InpMagicNumber       = 20250401;
input bool     InpEnableLogging     = true;
input bool     InpShowDashboard     = true;

//--- Objects
CTrade         g_trade;
CPositionInfo  g_position;

//--- State
datetime g_lastAnalysisTime  = 0;
string   g_lastAction        = "HOLD";
int      g_lastConfidence    = 0;
double   g_lastSLPips        = 25;
double   g_lastTPPips        = 45;
string   g_lastReasoning     = "";
bool     g_lastCloseLosers   = false;
bool     g_lastAddWinner     = false;
int      g_totalAnalyses     = 0;
int      g_totalTrades       = 0;
double   g_sessionPnL        = 0;
double   g_totalPnL          = 0;
int      g_winCount          = 0;
int      g_lossCount         = 0;
double   g_pipSize           = 0.1;  // XAUUSD 1 pip = 0.1
int      g_apiErrors         = 0;
double   g_peakEquity        = 0;
double   g_maxDrawdown       = 0;


//+------------------------------------------------------------------+
//| OnInit                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(30);
   g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   g_pipSize  = 0.1;
   g_peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(StringFind(_Symbol,"XAU")<0 && StringFind(_Symbol,"GOLD")<0)
      Print("WARNING: EA optimise pour XAUUSD. Symbole actuel: ", _Symbol);

   Print("========================================================");
   Print("   GoldAI Claude Bot v3.0 ULTIMATE - STARTED");
   Print("========================================================");
   Print("Model      : ", InpModel);
   Print("Interval   : ", InpAnalysisInterval, "s");
   Print("Lots       : ", InpExponentialLots ? "EXPONENTIELS" : "Lineaires",
         " base=", InpBaseLot, " max=", InpMaxLot);
   Print("MaxPos     : ", InpMaxPositions, " | MinConf: ", InpMinConfidence, "%");
   Print("Trailing   : ", InpUseTrailing ? "ON" : "OFF",
         " | BE: ", InpUseBreakEven ? "ON" : "OFF");
   Print("Portfolio  : CloseLosers=", InpCloseLosersOnSig ? "ON" : "OFF",
         " | Hedge=", InpAllowHedge ? "ON" : "OFF");
   Print("========================================================");
   Print("IMPORTANT: Ajouter https://api.anthropic.com aux URLs autorises MT5");

   EventSetTimer(1);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
   double winRate = (g_winCount + g_lossCount) > 0
      ? (double)g_winCount / (g_winCount + g_lossCount) * 100.0 : 0;
   Print("========================================================");
   Print("   GoldAI Bot STOPPED");
   Print("   Analyses: ", g_totalAnalyses, " | Trades: ", g_totalTrades);
   Print("   Win: ", g_winCount, " | Loss: ", g_lossCount,
         " | WinRate: ", DoubleToString(winRate, 1), "%");
   Print("   Session PnL: $", DoubleToString(g_sessionPnL, 2));
   Print("   Total PnL  : $", DoubleToString(g_totalPnL, 2));
   Print("   Max Drawdown: ", DoubleToString(g_maxDrawdown, 2), "%");
   Print("========================================================");
}

//+------------------------------------------------------------------+
//| Timer: trailing/BE chaque seconde + dashboard                     |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(InpUseTrailing || InpUseBreakEven) ManagePositions();
   TrackDrawdown();
   if(InpShowDashboard) UpdateDashboard();
}

//+------------------------------------------------------------------+
//| OnTick: cycle principal                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime now = TimeCurrent();
   if(now - g_lastAnalysisTime < InpAnalysisInterval) return;
   g_lastAnalysisTime = now;

   if(!IsTradeAllowed()) return;

   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpreadPoints)
   {
      if(InpEnableLogging)
         Print("[SKIP] Spread=", spread, " pts > max=", InpMaxSpreadPoints);
      return;
   }

   if(!IsSessionAllowed())
   {
      if(InpEnableLogging) Print("[SKIP] Hors sessions. Session: ", GetCurrentSession());
      return;
   }

   string marketData = BuildMarketData();

   if(InpEnableLogging)
      Print("[API] Requete #", g_totalAnalyses+1, " | Session: ", GetCurrentSession(),
            " | Positions: ", CountPositions(), "/", InpMaxPositions);

   bool ok = QueryClaude(marketData);
   g_totalAnalyses++;

   if(!ok) { g_apiErrors++; return; }
   g_apiErrors = 0;

   Print("[SIGNAL] ", g_lastAction,
         " conf=", g_lastConfidence, "%",
         " SL=", g_lastSLPips, "p TP=", g_lastTPPips, "p",
         " | ", g_lastReasoning);

   // 1. Portfolio management: fermeture intelligente
   ManagePortfolio();

   // 2. Ouverture si signal assez fort
   if(g_lastAction != "HOLD" && g_lastConfidence >= InpMinConfidence)
   {
      if(CountPositions() < InpMaxPositions)
         ExecuteSignal();
      else
         Print("[SKIP] Positions max atteint (", InpMaxPositions, "/", InpMaxPositions, ")");
   }
}


//+------------------------------------------------------------------+
//| BuildMarketData: analyse profonde multi-timeframe                  |
//+------------------------------------------------------------------+
string BuildMarketData()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   string ts = StringFormat("%04d-%02d-%02d %02d:%02d:%02d UTC",
      dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec);

   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bal   = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
   double marg  = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   int    nPos  = CountPositions();
   double floatPL = eq - bal;

   string d = "";
   d += "=== XAUUSD SCALP ANALYSIS v3 ===\n";
   d += "Time: " + ts + " | Session: " + GetCurrentSession() + "\n";
   d += StringFormat("Account: Bal=%.2f Eq=%.2f FreeMargin=%.2f FloatPL=%.2f\n",
      bal, eq, marg, floatPL);
   d += StringFormat("Price: Bid=%.2f Ask=%.2f Spread=%.2fpips\n",
      bid, ask, (ask-bid)/g_pipSize);
   d += StringFormat("Positions: %d/%d | MaxDD: %.1f%%\n\n", nPos, InpMaxPositions, g_maxDrawdown);

   // --- Volatilite ATR ---
   int atrM1H  = iATR(_Symbol, PERIOD_M1,  14);
   int atrM5H  = iATR(_Symbol, PERIOD_M5,  14);
   int atrM15H = iATR(_Symbol, PERIOD_M15, 14);
   int atrH1H  = iATR(_Symbol, PERIOD_H1,  14);
   double a1[],a5[],a15[],a60[];
   ArraySetAsSeries(a1,true); ArraySetAsSeries(a5,true);
   ArraySetAsSeries(a15,true); ArraySetAsSeries(a60,true);
   double atrM1=0,atrM5=0,atrM15=0,atrH1=0;
   if(atrM1H!=INVALID_HANDLE){CopyBuffer(atrM1H,0,0,1,a1);atrM1=a1[0];IndicatorRelease(atrM1H);}
   if(atrM5H!=INVALID_HANDLE){CopyBuffer(atrM5H,0,0,1,a5);atrM5=a5[0];IndicatorRelease(atrM5H);}
   if(atrM15H!=INVALID_HANDLE){CopyBuffer(atrM15H,0,0,1,a15);atrM15=a15[0];IndicatorRelease(atrM15H);}
   if(atrH1H!=INVALID_HANDLE){CopyBuffer(atrH1H,0,0,1,a60);atrH1=a60[0];IndicatorRelease(atrH1H);}
   d += StringFormat("ATR: M1=%.2f M5=%.2f M15=%.2f H1=%.2f\n\n", atrM1, atrM5, atrM15, atrH1);

   // --- M1 candles (scalp signal, 25 bougies) ---
   MqlRates rm1[]; ArraySetAsSeries(rm1,true);
   int cm1 = CopyRates(_Symbol, PERIOD_M1, 0, 25, rm1);
   if(cm1 > 0)
   {
      d += "M1 Candles (25 newest, O/H/L/C/Vol):\n";
      for(int i=0; i<MathMin(cm1,25); i++)
         d += StringFormat("%.2f,%.2f,%.2f,%.2f,%lld\n",
            rm1[i].open,rm1[i].high,rm1[i].low,rm1[i].close,rm1[i].tick_volume);
      d += "\n";
   }

   // --- M5 candles (20 bougies) ---
   MqlRates rm5[]; ArraySetAsSeries(rm5,true);
   int cm5 = CopyRates(_Symbol, PERIOD_M5, 0, 20, rm5);
   if(cm5 > 0)
   {
      d += "M5 Candles (20 newest, O/H/L/C):\n";
      for(int i=0; i<MathMin(cm5,20); i++)
         d += StringFormat("%.2f,%.2f,%.2f,%.2f\n",
            rm5[i].open,rm5[i].high,rm5[i].low,rm5[i].close);
      d += "\n";
   }

   // --- M15 candles (15 bougies) ---
   MqlRates rm15[]; ArraySetAsSeries(rm15,true);
   int cm15 = CopyRates(_Symbol, PERIOD_M15, 0, 15, rm15);
   if(cm15 > 0)
   {
      d += "M15 Candles (15 newest, O/H/L/C):\n";
      for(int i=0; i<MathMin(cm15,15); i++)
         d += StringFormat("%.2f,%.2f,%.2f,%.2f\n",
            rm15[i].open,rm15[i].high,rm15[i].low,rm15[i].close);
      d += "\n";
   }

   // --- H1 candles (8 bougies, contexte macro) ---
   MqlRates rh1[]; ArraySetAsSeries(rh1,true);
   int ch1 = CopyRates(_Symbol, PERIOD_H1, 0, 8, rh1);
   if(ch1 > 0)
   {
      d += "H1 Candles (8 newest, O/H/L/C):\n";
      for(int i=0; i<MathMin(ch1,8); i++)
         d += StringFormat("%.2f,%.2f,%.2f,%.2f\n",
            rh1[i].open,rh1[i].high,rh1[i].low,rh1[i].close);
      d += "\n";
   }

   // --- INDICATEURS ---
   d += "=== INDICATORS ===\n";

   // RSI M1, M5, M15
   int rM1=iRSI(_Symbol,PERIOD_M1,14,PRICE_CLOSE);
   int rM5=iRSI(_Symbol,PERIOD_M5,14,PRICE_CLOSE);
   int rM15=iRSI(_Symbol,PERIOD_M15,14,PRICE_CLOSE);
   double rb1[],rb5[],rb15[];
   ArraySetAsSeries(rb1,true); ArraySetAsSeries(rb5,true); ArraySetAsSeries(rb15,true);
   if(rM1!=INVALID_HANDLE){CopyBuffer(rM1,0,0,3,rb1);IndicatorRelease(rM1);}
   if(rM5!=INVALID_HANDLE){CopyBuffer(rM5,0,0,3,rb5);IndicatorRelease(rM5);}
   if(rM15!=INVALID_HANDLE){CopyBuffer(rM15,0,0,3,rb15);IndicatorRelease(rM15);}
   if(ArraySize(rb1)>=2)  d+=StringFormat("RSI(14,M1)=%.1f prev=%.1f\n",rb1[0],rb1[1]);
   if(ArraySize(rb5)>=2)  d+=StringFormat("RSI(14,M5)=%.1f prev=%.1f\n",rb5[0],rb5[1]);
   if(ArraySize(rb15)>=2) d+=StringFormat("RSI(14,M15)=%.1f prev=%.1f\n",rb15[0],rb15[1]);

   // MACD M5 et M15
   int mM5=iMACD(_Symbol,PERIOD_M5,12,26,9,PRICE_CLOSE);
   int mM15=iMACD(_Symbol,PERIOD_M15,12,26,9,PRICE_CLOSE);
   double mm5[],ms5[],mm15[],ms15[];
   ArraySetAsSeries(mm5,true);ArraySetAsSeries(ms5,true);
   ArraySetAsSeries(mm15,true);ArraySetAsSeries(ms15,true);
   if(mM5!=INVALID_HANDLE)
   {
      CopyBuffer(mM5,0,0,3,mm5); CopyBuffer(mM5,1,0,3,ms5);
      IndicatorRelease(mM5);
      if(ArraySize(mm5)>=2)
         d+=StringFormat("MACD(M5): main=%.4f sig=%.4f hist=%.4f prevHist=%.4f\n",
            mm5[0],ms5[0],mm5[0]-ms5[0],mm5[1]-ms5[1]);
   }
   if(mM15!=INVALID_HANDLE)
   {
      CopyBuffer(mM15,0,0,3,mm15); CopyBuffer(mM15,1,0,3,ms15);
      IndicatorRelease(mM15);
      if(ArraySize(mm15)>=2)
         d+=StringFormat("MACD(M15): main=%.4f sig=%.4f hist=%.4f prevHist=%.4f\n",
            mm15[0],ms15[0],mm15[0]-ms15[0],mm15[1]-ms15[1]);
   }

   // Bollinger Bands M5 et M15
   int bM5=iBands(_Symbol,PERIOD_M5,20,0,2.0,PRICE_CLOSE);
   int bM15=iBands(_Symbol,PERIOD_M15,20,0,2.0,PRICE_CLOSE);
   double bu5[],bm5[],bl5[],bu15[],bm15[],bl15[];
   ArraySetAsSeries(bu5,true);ArraySetAsSeries(bm5,true);ArraySetAsSeries(bl5,true);
   ArraySetAsSeries(bu15,true);ArraySetAsSeries(bm15,true);ArraySetAsSeries(bl15,true);
   if(bM5!=INVALID_HANDLE)
   {
      CopyBuffer(bM5,1,0,1,bu5);CopyBuffer(bM5,0,0,1,bm5);CopyBuffer(bM5,2,0,1,bl5);
      IndicatorRelease(bM5);
      if(ArraySize(bu5)>0)
      {
         double bw5=(bu5[0]-bl5[0]);
         double bp5=bw5>0?(bid-bl5[0])/bw5*100:50;
         d+=StringFormat("BB(20,M5): U=%.2f M=%.2f L=%.2f Pos=%.0f%% Width=%.2f\n",
            bu5[0],bm5[0],bl5[0],bp5,bw5);
      }
   }
   if(bM15!=INVALID_HANDLE)
   {
      CopyBuffer(bM15,1,0,1,bu15);CopyBuffer(bM15,0,0,1,bm15);CopyBuffer(bM15,2,0,1,bl15);
      IndicatorRelease(bM15);
      if(ArraySize(bu15)>0)
      {
         double bw15=(bu15[0]-bl15[0]);
         double bp15=bw15>0?(bid-bl15[0])/bw15*100:50;
         d+=StringFormat("BB(20,M15): U=%.2f M=%.2f L=%.2f Pos=%.0f%% Width=%.2f\n",
            bu15[0],bm15[0],bl15[0],bp15,bw15);
      }
   }

   // EMA multi-TF
   double ema8M1=0,ema21M1=0,ema8M5=0,ema21M5=0,ema50M15=0,ema200H1=0;
   int e1=iMA(_Symbol,PERIOD_M1,8,0,MODE_EMA,PRICE_CLOSE);
   int e2=iMA(_Symbol,PERIOD_M1,21,0,MODE_EMA,PRICE_CLOSE);
   int e3=iMA(_Symbol,PERIOD_M5,8,0,MODE_EMA,PRICE_CLOSE);
   int e4=iMA(_Symbol,PERIOD_M5,21,0,MODE_EMA,PRICE_CLOSE);
   int e5=iMA(_Symbol,PERIOD_M15,50,0,MODE_EMA,PRICE_CLOSE);
   int e6=iMA(_Symbol,PERIOD_H1,200,0,MODE_EMA,PRICE_CLOSE);
   double eb[1]; ArraySetAsSeries(eb,true);
   if(e1!=INVALID_HANDLE){CopyBuffer(e1,0,0,1,eb);ema8M1=eb[0];IndicatorRelease(e1);}
   if(e2!=INVALID_HANDLE){CopyBuffer(e2,0,0,1,eb);ema21M1=eb[0];IndicatorRelease(e2);}
   if(e3!=INVALID_HANDLE){CopyBuffer(e3,0,0,1,eb);ema8M5=eb[0];IndicatorRelease(e3);}
   if(e4!=INVALID_HANDLE){CopyBuffer(e4,0,0,1,eb);ema21M5=eb[0];IndicatorRelease(e4);}
   if(e5!=INVALID_HANDLE){CopyBuffer(e5,0,0,1,eb);ema50M15=eb[0];IndicatorRelease(e5);}
   if(e6!=INVALID_HANDLE){CopyBuffer(e6,0,0,1,eb);ema200H1=eb[0];IndicatorRelease(e6);}
   d+=StringFormat("EMA: 8M1=%.2f 21M1=%.2f | 8M5=%.2f 21M5=%.2f | 50M15=%.2f | 200H1=%.2f\n",
      ema8M1,ema21M1,ema8M5,ema21M5,ema50M15,ema200H1);

   // Stochastique M1 et M5
   int stM1=iStochastic(_Symbol,PERIOD_M1,5,3,3,MODE_SMA,STO_LOWHIGH);
   int stM5=iStochastic(_Symbol,PERIOD_M5,5,3,3,MODE_SMA,STO_LOWHIGH);
   double sk1[],sd1[],sk5[],sd5[];
   ArraySetAsSeries(sk1,true);ArraySetAsSeries(sd1,true);
   ArraySetAsSeries(sk5,true);ArraySetAsSeries(sd5,true);
   if(stM1!=INVALID_HANDLE)
   {
      CopyBuffer(stM1,0,0,3,sk1);CopyBuffer(stM1,1,0,3,sd1);IndicatorRelease(stM1);
      if(ArraySize(sk1)>=2) d+=StringFormat("Stoch(M1): K=%.1f D=%.1f prevK=%.1f\n",sk1[0],sd1[0],sk1[1]);
   }
   if(stM5!=INVALID_HANDLE)
   {
      CopyBuffer(stM5,0,0,3,sk5);CopyBuffer(stM5,1,0,3,sd5);IndicatorRelease(stM5);
      if(ArraySize(sk5)>=2) d+=StringFormat("Stoch(M5): K=%.1f D=%.1f prevK=%.1f\n",sk5[0],sd5[0],sk5[1]);
   }

   // ADX M15
   int adxH=iADX(_Symbol,PERIOD_M15,14);
   double adxV[],dip[],dim[];
   ArraySetAsSeries(adxV,true);ArraySetAsSeries(dip,true);ArraySetAsSeries(dim,true);
   if(adxH!=INVALID_HANDLE)
   {
      CopyBuffer(adxH,0,0,1,adxV);CopyBuffer(adxH,1,0,1,dip);CopyBuffer(adxH,2,0,1,dim);
      IndicatorRelease(adxH);
      if(ArraySize(adxV)>0)
         d+=StringFormat("ADX(14,M15)=%.1f DI+=%.1f DI-=%.1f TrendStr=%s\n",
            adxV[0],dip[0],dim[0],
            adxV[0]>30?"FORT":(adxV[0]>20?"MODERE":"FAIBLE"));
   }

   // CCI M5
   int cciH=iCCI(_Symbol,PERIOD_M5,20,PRICE_TYPICAL);
   double cciv[];
   ArraySetAsSeries(cciv,true);
   if(cciH!=INVALID_HANDLE)
   {
      CopyBuffer(cciH,0,0,2,cciv);IndicatorRelease(cciH);
      if(ArraySize(cciv)>=2)
         d+=StringFormat("CCI(20,M5)=%.1f prev=%.1f\n",cciv[0],cciv[1]);
   }

   // Momentum M1 (Williams %R)
   int wrH=iWPR(_Symbol,PERIOD_M1,14);
   double wrV[];
   ArraySetAsSeries(wrV,true);
   if(wrH!=INVALID_HANDLE)
   {
      CopyBuffer(wrH,0,0,2,wrV);IndicatorRelease(wrH);
      if(ArraySize(wrV)>0)
         d+=StringFormat("WilliamsR(14,M1)=%.1f\n",wrV[0]);
   }

   // --- Structure de marche ---
   d += "\n=== MARKET STRUCTURE ===\n";
   string h1trend = bid>ema200H1 ? "HAUSSIER (>EMA200H1)" : "BAISSIER (<EMA200H1)";
   string m5trend = ema8M5>ema21M5 ? "HAUSSIER (EMA8>EMA21)" : "BAISSIER (EMA8<EMA21)";
   string m1mom   = ema8M1>ema21M1 ? "UP" : "DOWN";
   d += "H1 Tendance: " + h1trend + "\n";
   d += "M5 Tendance: " + m5trend + "\n";
   d += "M1 Momentum: EMA8 " + (ema8M1>ema21M1?"au-dessus":"en-dessous") + " EMA21\n";

   // Support/resistance H1
   if(ch1>=8)
   {
      double hh=rh1[0].high, ll=rh1[0].low;
      for(int i=1;i<MathMin(ch1,8);i++){if(rh1[i].high>hh)hh=rh1[i].high;if(rh1[i].low<ll)ll=rh1[i].low;}
      d+=StringFormat("H1 Range(8bars): Resistance=%.2f Support=%.2f\n",hh,ll);
   }

   // --- Positions ouvertes (gestion portfolio) ---
   if(nPos > 0)
   {
      d += "\n=== OPEN POSITIONS (Portfolio Management) ===\n";
      d += "Indique si certaines positions doivent etre fermees.\n";
      double totalFloat=0;
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         if(!g_position.SelectByIndex(i)) continue;
         if(g_position.Symbol()!=_Symbol || g_position.Magic()!=InpMagicNumber) continue;
         double pp = g_position.PositionType()==POSITION_TYPE_BUY
            ? (bid - g_position.PriceOpen())/g_pipSize
            : (g_position.PriceOpen() - ask)/g_pipSize;
         totalFloat += g_position.Profit();
         d += StringFormat("#%llu %s %.2flots @%.2f SL=%.2f TP=%.2f P&L=%.1fpips $%.1f\n",
            g_position.Ticket(),
            g_position.PositionType()==POSITION_TYPE_BUY?"BUY":"SELL",
            g_position.Volume(),
            g_position.PriceOpen(),
            g_position.StopLoss(),
            g_position.TakeProfit(),
            pp,
            g_position.Profit());
      }
      d += StringFormat("Total Float P&L: $%.2f\n", totalFloat);
   }

   return d;
}


//+------------------------------------------------------------------+
//| QueryClaude: appel API avec prompt portfolio complet               |
//+------------------------------------------------------------------+
bool QueryClaude(string marketData)
{
   string sys = "Tu es un trader expert XAUUSD (Gold) specialise dans le scalp et le swing. "
      "Analyse les donnees multi-timeframe M1/M5/M15/H1 et tous les indicateurs. "
      "SOIS OFFENSIF: cherche des signaux sur toutes les sessions (Sydney, Tokyo, London, NY). "
      "Strategies: breakouts sur M1/M5, rebonds EMA, divergences RSI, MACD crossovers, "
      "squeeze BB, extremes CCI/Stoch, tendance ADX. "
      "Pour le portfolio: recommande close_losers=true si les positions perdantes vont contre "
      "un nouveau signal fort. Recommande add_to_winner=true pour pyramider sur les gagnantes. "
      "SL tight (10-25 pips scalp) ou moyen (25-50 swing). TP 2x SL minimum. "
      "Ne dis HOLD que si le marche est vraiment indecis.";

   string usr = marketData
      + "\n\nDonne ta decision de trading. "
      + "Reponds UNIQUEMENT avec ce JSON exact (pas de markdown):\n"
      + "{\"action\":\"BUY\",\"confidence\":82,\"sl_pips\":20,\"tp_pips\":42,"
      + "\"close_losers\":false,\"add_to_winner\":false,"
      + "\"reasoning\":\"raison courte max 70 chars\"}";

   string payload = "{";
   payload += "\"model\":\"" + InpModel + "\",";
   payload += "\"max_tokens\":200,";
   payload += "\"system\":\"" + EscapeJSON(sys) + "\",";
   payload += "\"messages\":[{\"role\":\"user\",\"content\":\"" + EscapeJSON(usr) + "\"}]";
   payload += "}";

   string headers = "Content-Type: application/json\r\n"
      + "x-api-key: " + InpApiKey + "\r\n"
      + "anthropic-version: 2023-06-01\r\n";

   uchar postArr[], respArr[];
   string respHeaders;
   int payLen = StringToCharArray(payload, postArr, 0, StringLen(payload));
   ArrayResize(postArr, payLen);

   int code = WebRequest("POST",
      "https://api.anthropic.com/v1/messages",
      headers, 15000, postArr, respArr, respHeaders);

   if(code == -1)
   {
      Print("[API ERROR] code=-1 err=", GetLastError(),
         " -> Ajouter https://api.anthropic.com aux URLs MT5 (Outils>Options>Experts)");
      return false;
   }
   if(code != 200)
   {
      Print("[API ERROR] HTTP ", code, ": ", StringSubstr(CharArrayToString(respArr),0,400));
      return false;
   }

   string resp = CharArrayToString(respArr);
   if(InpEnableLogging) Print("[API] Raw: ", StringSubstr(resp,0,700));
   return ParseClaudeResponse(resp);
}

//+------------------------------------------------------------------+
//| ParseClaudeResponse                                                |
//+------------------------------------------------------------------+
bool ParseClaudeResponse(string response)
{
   int ts = StringFind(response, "\"text\":\"");
   if(ts < 0){ Print("[PARSE] Pas de champ 'text'"); return false; }
   ts += 8;
   int te = ts;
   int rl = StringLen(response);
   while(te < rl)
   {
      ushort c = StringGetCharacter(response, te);
      ushort p = te > 0 ? StringGetCharacter(response, te-1) : 0;
      if(c=='"' && p!='\\') break;
      te++;
   }
   string rawText = UnescapeJSON(StringSubstr(response, ts, te-ts));
   if(InpEnableLogging) Print("[PARSE] Text: ", rawText);

   int js = StringFind(rawText, "{");
   int je = StringFind(rawText, "}", js);
   if(js<0||je<0){ Print("[PARSE] Pas de JSON dans: ", rawText); return false; }
   string j = StringSubstr(rawText, js, je-js+1);

   g_lastAction = ExtractJSONString(j, "action");
   if(g_lastAction=="") g_lastAction="HOLD";
   StringToUpper(g_lastAction);

   string cs = ExtractJSONNumber(j, "confidence");
   g_lastConfidence = (int)StringToInteger(cs);
   if(g_lastConfidence<=0||g_lastConfidence>100) g_lastConfidence=50;

   string ss = ExtractJSONNumber(j, "sl_pips");
   g_lastSLPips = StringToDouble(ss);
   if(g_lastSLPips < InpMinSLPips) g_lastSLPips = InpMinSLPips;
   if(g_lastSLPips > InpMaxSLPips) g_lastSLPips = InpMaxSLPips;

   string ts2 = ExtractJSONNumber(j, "tp_pips");
   g_lastTPPips = StringToDouble(ts2);
   if(g_lastTPPips <= 0) g_lastTPPips = g_lastSLPips * 2.0;

   g_lastReasoning   = ExtractJSONString(j, "reasoning");
   g_lastCloseLosers = (StringFind(j, "\"close_losers\":true")>=0);
   g_lastAddWinner   = (StringFind(j, "\"add_to_winner\":true")>=0);

   return true;
}

//+------------------------------------------------------------------+
//| ManagePortfolio: gestion intelligente des positions par Claude    |
//+------------------------------------------------------------------+
void ManagePortfolio()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int closedCount = 0;

   // 1. Fermer positions perdantes si Claude le demande
   if(InpCloseLosersOnSig && g_lastCloseLosers && g_lastConfidence >= InpMinConfToCloseBad)
   {
      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         if(!g_position.SelectByIndex(i)) continue;
         if(g_position.Symbol()!=_Symbol || g_position.Magic()!=InpMagicNumber) continue;

         bool isLosing  = g_position.Profit() < 0;
         bool isOpposed = (g_lastAction=="BUY"  && g_position.PositionType()==POSITION_TYPE_SELL)
                       || (g_lastAction=="SELL" && g_position.PositionType()==POSITION_TYPE_BUY);

         if(isLosing && isOpposed)
         {
            if(g_trade.PositionClose(g_position.Ticket()))
            {
               closedCount++;
               Print("[PORTFOLIO] Ferme position perdante opposee #", g_position.Ticket(),
                     " P&L=$", DoubleToString(g_position.Profit(),2));
            }
         }
      }
   }

   // 2. Fermer si perte depasse seuil absolu ($)
   if(InpMaxLossToClose < 0)
   {
      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         if(!g_position.SelectByIndex(i)) continue;
         if(g_position.Symbol()!=_Symbol || g_position.Magic()!=InpMagicNumber) continue;
         if(g_position.Profit() < InpMaxLossToClose)
         {
            if(g_trade.PositionClose(g_position.Ticket()))
            {
               closedCount++;
               Print("[PORTFOLIO] Stop-loss dollar declenche #", g_position.Ticket(),
                     " P&L=$", DoubleToString(g_position.Profit(),2));
            }
         }
      }
   }

   // 3. Fermer positions contraires si signal fort (InpCloseOnSignalFlip)
   if(InpCloseOnSignalFlip && !InpAllowHedge && g_lastConfidence >= 80)
   {
      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         if(!g_position.SelectByIndex(i)) continue;
         if(g_position.Symbol()!=_Symbol || g_position.Magic()!=InpMagicNumber) continue;
         bool isOpposed = (g_lastAction=="BUY"  && g_position.PositionType()==POSITION_TYPE_SELL)
                       || (g_lastAction=="SELL" && g_position.PositionType()==POSITION_TYPE_BUY);
         if(isOpposed)
         {
            if(g_trade.PositionClose(g_position.Ticket()))
            {
               closedCount++;
               Print("[PORTFOLIO] Flip signal fort (conf=", g_lastConfidence,
                     "%) ferme #", g_position.Ticket());
            }
         }
      }
   }

   // 4. Pyramide sur gagnante si Claude recommande add_to_winner
   if(g_lastAddWinner && CountPositions() < InpMaxPositions)
   {
      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         if(!g_position.SelectByIndex(i)) continue;
         if(g_position.Symbol()!=_Symbol || g_position.Magic()!=InpMagicNumber) continue;
         bool isSameDir = (g_lastAction=="BUY"  && g_position.PositionType()==POSITION_TYPE_BUY)
                       || (g_lastAction=="SELL" && g_position.PositionType()==POSITION_TYPE_SELL);
         if(isSameDir && g_position.Profit() > 0)
         {
            Print("[PORTFOLIO] Pyramide sur gagnante #", g_position.Ticket());
            ExecuteSignal();
            break; // Une seule addition
         }
      }
   }

   if(closedCount>0) Print("[PORTFOLIO] Positions fermees: ", closedCount);
}

//+------------------------------------------------------------------+
//| ExecuteSignal: ouvrir un trade                                     |
//+------------------------------------------------------------------+
void ExecuteSignal()
{
   if(g_lastAction!="BUY" && g_lastAction!="SELL") return;

   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double lots = CalculateLots(g_lastConfidence, g_lastSLPips);
   double sl   = InpUseClaudeSLTP ? g_lastSLPips : InpDefaultSL;
   double tp   = InpUseClaudeSLTP ? g_lastTPPips : InpDefaultTP;
   string cmt  = StringFormat("GoldAI|c=%d|%s", g_lastConfidence, g_lastReasoning);

   if(g_lastAction == "BUY")
   {
      double slP = NormalizeDouble(ask - sl*g_pipSize, _Digits);
      double tpP = NormalizeDouble(ask + tp*g_pipSize, _Digits);
      if(g_trade.Buy(lots, _Symbol, ask, slP, tpP, cmt))
      {
         g_totalTrades++;
         Print("[TRADE] BUY lots=",lots," @",ask," SL=",slP," TP=",tpP," conf=",g_lastConfidence,"%");
      }
      else Print("[TRADE ERROR] BUY: ", g_trade.ResultRetcodeDescription());
   }
   else
   {
      double slP = NormalizeDouble(bid + sl*g_pipSize, _Digits);
      double tpP = NormalizeDouble(bid - tp*g_pipSize, _Digits);
      if(g_trade.Sell(lots, _Symbol, bid, slP, tpP, cmt))
      {
         g_totalTrades++;
         Print("[TRADE] SELL lots=",lots," @",bid," SL=",slP," TP=",tpP," conf=",g_lastConfidence,"%");
      }
      else Print("[TRADE ERROR] SELL: ", g_trade.ResultRetcodeDescription());
   }
}


//+------------------------------------------------------------------+
//| CalculateLots: lots EXPONENTIELS selon confiance                   |
//+------------------------------------------------------------------+
double CalculateLots(int confidence, double slPips)
{
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double minLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLotSym= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double maxLot   = MathMin(InpMaxLot, maxLotSym);

   double pipVal = 10.0; // XAUUSD: ~$10 par pip par lot standard
   if(tickSz > 0.0 && tickVal > 0.0)
      pipVal = (g_pipSize / tickSz) * tickVal;

   double lots;

   if(InpExponentialLots)
   {
      // Formule exponentielle:
      // lots = BaseLot * ExpBase^((conf - MinConf) / NormFactor)
      // calibre pour atteindre MaxLot a conf=100
      double minConf  = (double)InpMinConfidence;
      double confRange = 100.0 - minConf;
      if(confRange <= 0) confRange = 45.0;

      double confAbove = MathMax(0.0, (double)confidence - minConf);
      double exponent  = confAbove / confRange; // 0.0 a 1.0

      // lots(min) = BaseLot, lots(max) = MaxLot
      // lots = BaseLot * (MaxLot/BaseLot)^exponent
      double ratio = InpMaxLot / InpBaseLot;
      lots = InpBaseLot * MathPow(ratio, exponent);
   }
   else
   {
      // Lineaire base risque
      double confFactor  = MathMax(0.0, MathMin(1.0, (double)confidence/100.0));
      double riskPct     = 0.5 + confFactor * (InpMaxRiskPct - 0.5);
      double riskAmt     = balance * riskPct / 100.0;
      lots = riskAmt / (slPips * pipVal);
   }

   // Plafonner par risque max absolu (securite)
   double maxRiskAmt = balance * InpMaxRiskPct / 100.0;
   double maxByRisk  = maxRiskAmt / (slPips * pipVal);
   lots = MathMin(lots, maxByRisk);

   // Normaliser au step
   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));

   if(InpEnableLogging)
      Print("[LOTS] conf=", confidence, "% exp=", InpExponentialLots?"OUI":"NON",
            " lots=", DoubleToString(lots,2),
            " (min=", minLot, " max=", DoubleToString(maxLot,2), ")");

   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| ManagePositions: trailing + break-even                             |
//+------------------------------------------------------------------+
void ManagePositions()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      if(!g_position.SelectByIndex(i)) continue;
      if(g_position.Symbol()!=_Symbol || g_position.Magic()!=InpMagicNumber) continue;

      ulong  tkt   = g_position.Ticket();
      double op    = g_position.PriceOpen();
      double csl   = g_position.StopLoss();
      double ctp   = g_position.TakeProfit();
      double newSL = csl;
      bool   mod   = false;

      if(g_position.PositionType() == POSITION_TYPE_BUY)
      {
         double pp = (bid - op) / g_pipSize;
         // Break-even
         if(InpUseBreakEven && pp >= InpBreakEvenAt)
         {
            double beSL = NormalizeDouble(op + InpBreakEvenBonus*g_pipSize, _Digits);
            if(newSL < beSL - _Point*3){ newSL=beSL; mod=true;
               if(InpEnableLogging) Print("[BE] BUY #",tkt," SL->",newSL," pp=",DoubleToString(pp,1)); }
         }
         // Trailing
         if(InpUseTrailing && pp >= InpTrailingStart)
         {
            double trSL = NormalizeDouble(bid - InpTrailingStep*g_pipSize, _Digits);
            if(trSL > newSL + _Point*3){ newSL=trSL; mod=true;
               if(InpEnableLogging) Print("[TRAIL] BUY #",tkt," SL->",newSL," pp=",DoubleToString(pp,1)); }
         }
         if(mod) g_trade.PositionModify(tkt, newSL, ctp);
      }
      else
      {
         double pp = (op - ask) / g_pipSize;
         // Break-even
         if(InpUseBreakEven && pp >= InpBreakEvenAt)
         {
            double beSL = NormalizeDouble(op - InpBreakEvenBonus*g_pipSize, _Digits);
            if(newSL==0||newSL > beSL+_Point*3){ newSL=beSL; mod=true;
               if(InpEnableLogging) Print("[BE] SELL #",tkt," SL->",newSL," pp=",DoubleToString(pp,1)); }
         }
         // Trailing
         if(InpUseTrailing && pp >= InpTrailingStart)
         {
            double trSL = NormalizeDouble(ask + InpTrailingStep*g_pipSize, _Digits);
            if(newSL==0||trSL < newSL-_Point*3){ newSL=trSL; mod=true;
               if(InpEnableLogging) Print("[TRAIL] SELL #",tkt," SL->",newSL," pp=",DoubleToString(pp,1)); }
         }
         if(mod) g_trade.PositionModify(tkt, newSL, ctp);
      }
   }
}

//+------------------------------------------------------------------+
//| Dashboard ULTIMATE                                                  |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   if(!InpShowDashboard) return;

   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double bal   = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
   int    nPos  = CountPositions();
   double winR  = (g_winCount+g_lossCount)>0
      ? (double)g_winCount/(g_winCount+g_lossCount)*100.0 : 0;

   // Calcul PnL flottant + positions
   double floatPL = 0;
   string posLines = "";
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      if(!g_position.SelectByIndex(i)) continue;
      if(g_position.Symbol()!=_Symbol || g_position.Magic()!=InpMagicNumber) continue;
      floatPL += g_position.Profit();
      double pp = g_position.PositionType()==POSITION_TYPE_BUY
         ? (bid - g_position.PriceOpen())/g_pipSize
         : (g_position.PriceOpen() - bid)/g_pipSize;
      posLines += StringFormat("  %s %.2flot @%.2f | %.1fp | $%.1f\n",
         g_position.PositionType()==POSITION_TYPE_BUY?"BUY ":"SELL",
         g_position.Volume(), g_position.PriceOpen(), pp, g_position.Profit());
   }

   datetime nxt     = g_lastAnalysisTime + InpAnalysisInterval;
   int      secsNxt = (int)MathMax(0, (double)(nxt - TimeCurrent()));

   string s = "";
   s += "╔══════════════════════════════════╗\n";
   s += "║   GoldAI Claude Bot v3.0 ULTIMATE║\n";
   s += "╠══════════════════════════════════╣\n";
   s += StringFormat("║ Prix     : %-22.2f║\n", bid);
   s += StringFormat("║ Session  : %-22s║\n", GetCurrentSession());
   s += "╠══════════════════════════════════╣\n";
   s += StringFormat("║ Balance  : $%-21.2f║\n", bal);
   s += StringFormat("║ Equity   : $%-21.2f║\n", eq);
   s += StringFormat("║ Float PL : $%-21.2f║\n", floatPL);
   s += StringFormat("║ Session  : $%-21.2f║\n", g_sessionPnL);
   s += StringFormat("║ Total PnL: $%-21.2f║\n", g_totalPnL);
   s += StringFormat("║ Max DD   : %-21s║\n", DoubleToString(g_maxDrawdown,1)+"%");
   s += "╠══════════════════════════════════╣\n";
   s += StringFormat("║ Signal   : %-5s conf=%-3d%%       ║\n", g_lastAction, g_lastConfidence);
   s += StringFormat("║ Prochaine: %-3ds                   ║\n", secsNxt);
   s += StringFormat("║ Analyses : %-22d║\n", g_totalAnalyses);
   s += StringFormat("║ Trades   : %-22d║\n", g_totalTrades);
   s += StringFormat("║ W/L/Rate : %d/%d/%-16s║\n",
      g_winCount, g_lossCount, DoubleToString(winR,0)+"%");
   s += StringFormat("║ Lots mode: %-22s║\n", InpExponentialLots?"EXPONENTIELS":"Lineaire");
   s += "╠══════════════════════════════════╣\n";
   s += StringFormat("║ Positions: %d/%-24d║\n", nPos, InpMaxPositions);
   if(posLines != "")
      s += posLines;
   if(g_lastReasoning != "")
      s += StringFormat("║ Raison: %-26s║\n", StringSubstr(g_lastReasoning,0,26));
   if(g_apiErrors > 0)
      s += StringFormat("║ API ERRORS: %-21d║\n", g_apiErrors);
   s += "╚══════════════════════════════════╝";
   Comment(s);
}

//+------------------------------------------------------------------+
//| Suivi du drawdown                                                  |
//+------------------------------------------------------------------+
void TrackDrawdown()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > g_peakEquity) g_peakEquity = eq;
   if(g_peakEquity > 0)
   {
      double dd = (g_peakEquity - eq) / g_peakEquity * 100.0;
      if(dd > g_maxDrawdown) g_maxDrawdown = dd;
   }
}

//+------------------------------------------------------------------+
//| Count positions EA                                                 |
//+------------------------------------------------------------------+
int CountPositions()
{
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(g_position.SelectByIndex(i)&&g_position.Symbol()==_Symbol&&g_position.Magic()==InpMagicNumber)
         n++;
   return n;
}

//+------------------------------------------------------------------+
//| Session check                                                      |
//+------------------------------------------------------------------+
bool IsSessionAllowed()
{
   if(!InpTradeSydney&&!InpTradeTokyo&&!InpTradeLondon&&!InpTradeNewYork) return true;
   MqlDateTime dt; TimeToStruct(TimeGMT(),dt); int h=dt.hour;
   if(InpTradeSydney  && (h>=22||h<7))   return true;
   if(InpTradeTokyo   && h>=0 && h<9)    return true;
   if(InpTradeLondon  && h>=7 && h<16)   return true;
   if(InpTradeNewYork && h>=13 && h<22)  return true;
   return false;
}

string GetCurrentSession()
{
   MqlDateTime dt; TimeToStruct(TimeGMT(),dt); int h=dt.hour;
   string s="";
   if(h>=22||h<7)  s+="Sydney/";
   if(h>=0&&h<9)   s+="Tokyo/";
   if(h>=7&&h<16)  s+="London/";
   if(h>=13&&h<22) s+="NewYork/";
   if(s=="") s="OffHours/";
   if(StringGetCharacter(s,StringLen(s)-1)=='/') s=StringSubstr(s,0,StringLen(s)-1);
   return s;
}

bool IsTradeAllowed()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)){ Print("[WARN] Trading terminal desactive."); return false; }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)){ Print("[WARN] Bouton Algo Trading desactive."); return false; }
   return true;
}

//+------------------------------------------------------------------+
//| Helpers JSON                                                       |
//+------------------------------------------------------------------+
string ExtractJSONString(const string j, const string key)
{
   string sk="\""+key+"\":\"";
   int s=StringFind(j,sk); if(s<0) return "";
   s+=StringLen(sk);
   int e=s, l=StringLen(j);
   while(e<l){ushort c=StringGetCharacter(j,e);ushort p=e>0?StringGetCharacter(j,e-1):0;if(c=='"'&&p!='\\')break;e++;}
   return StringSubstr(j,s,e-s);
}

string ExtractJSONNumber(const string j, const string key)
{
   string sk="\""+key+"\":";
   int s=StringFind(j,sk); if(s<0) return "0";
   s+=StringLen(sk);
   int l=StringLen(j);
   while(s<l&&StringGetCharacter(j,s)==' ') s++;
   int e=s;
   while(e<l){ushort c=StringGetCharacter(j,e);if((c>='0'&&c<='9')||c=='.'||c=='-')e++;else break;}
   return StringSubstr(j,s,e-s);
}

string EscapeJSON(string t)
{
   StringReplace(t,"\\","\\\\");StringReplace(t,"\"","\\\"");
   StringReplace(t,"\n","\\n");StringReplace(t,"\r","\\r");StringReplace(t,"\t","\\t");
   return t;
}

string UnescapeJSON(string t)
{
   StringReplace(t,"\\n","\n");StringReplace(t,"\\r","\r");StringReplace(t,"\\t","\t");
   StringReplace(t,"\\\"","\"");StringReplace(t,"\\\\","\\");
   return t;
}

//+------------------------------------------------------------------+
//| Callback trades fermes                                             |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &req,
                        const MqlTradeResult  &res)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong dk = trans.deal;
      if(dk>0 && HistoryDealSelect(dk))
      {
         if(HistoryDealGetInteger(dk, DEAL_MAGIC)==InpMagicNumber)
         {
            double profit = HistoryDealGetDouble(dk, DEAL_PROFIT);
            double comm   = HistoryDealGetDouble(dk, DEAL_COMMISSION);
            double swap   = HistoryDealGetDouble(dk, DEAL_SWAP);
            double net    = profit + comm + swap;
            if(profit != 0.0)
            {
               g_totalPnL   += net;
               g_sessionPnL += net;
               if(net > 0) g_winCount++;
               else         g_lossCount++;
               Print("[CLOSED] Profit=", DoubleToString(profit,2),
                     " Net=", DoubleToString(net,2),
                     " | Total=$", DoubleToString(g_totalPnL,2),
                     " | W=", g_winCount, " L=", g_lossCount);
            }
         }
      }
   }
}
//+------------------------------------------------------------------+
