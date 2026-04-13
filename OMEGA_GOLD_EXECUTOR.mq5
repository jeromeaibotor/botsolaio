//+------------------------------------------------------------------+
//|  OMEGA GOLD EXECUTOR v1.0                                        |
//|  EA MQL5 - Récepteur ZMQ + Exécution intelligente XAUUSD         |
//|                                                                  |
//|  Connexions ZMQ :                                                |
//|    Port 5555 PULL → reçoit commandes depuis agent Python         |
//|    Port 5556 PUSH → envoie positions ouvertes vers Python        |
//+------------------------------------------------------------------+
#property copyright "OMEGA GOLD"
#property version   "1.00"
#property strict

// ZeroMQ - à installer via MQL5 ZeroMQ wrapper
// https://github.com/dingmaotu/mql-zmq
#include <Zmq/Zmq.mqh>

// Trade
#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

//--- Inputs
input int    InpZmqPullPort  = 5555;   // Port réception commandes
input int    InpZmqPushPort  = 5556;   // Port envoi positions
input int    InpPushInterval = 2;      // Envoi positions toutes les N secondes
input double InpMaxLot       = 0.30;   // Lot maximum autorisé
input int    InpMagicNumber  = 20250101;
input bool   InpVerbose      = true;

//--- Objets globaux
CTrade         trade;
CPositionInfo  posInfo;
Context        zmqContext(1);
Socket         pullSocket(zmqContext, ZMQ_PULL);
Socket         pushSocket(zmqContext, ZMQ_PUSH);
datetime       lastPushTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Bind PULL socket (reçoit commandes)
   string pullAddr = StringFormat("tcp://localhost:%d", InpZmqPullPort);
   if(!pullSocket.bind(pullAddr))
   {
      Print("ERREUR: Impossible de bind PULL sur ", pullAddr);
      return INIT_FAILED;
   }
   pullSocket.setLinger(0);
   pullSocket.setReceiveHighWaterMark(10);

   // Connect PUSH socket (envoie positions)
   string pushAddr = StringFormat("tcp://localhost:%d", InpZmqPushPort);
   if(!pushSocket.connect(pushAddr))
   {
      Print("ERREUR: Impossible de connect PUSH sur ", pushAddr);
      return INIT_FAILED;
   }

   Print("OMEGA GOLD EXECUTOR démarré. PULL:", pullAddr, " PUSH:", pushAddr);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   pullSocket.unbind(StringFormat("tcp://localhost:%d", InpZmqPullPort));
   pushSocket.disconnect(StringFormat("tcp://localhost:%d", InpZmqPushPort));
   Print("OMEGA GOLD EXECUTOR arrêté.");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. Réception et traitement des commandes
   ProcessIncomingCommands();

   // 2. Envoi périodique des positions vers Python
   if(TimeCurrent() - lastPushTime >= InpPushInterval)
   {
      PushPositions();
      lastPushTime = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| Traitement des commandes ZMQ entrantes                           |
//+------------------------------------------------------------------+
void ProcessIncomingCommands()
{
   ZmqMsg message;
   // Non-bloquant : on vide la queue
   while(pullSocket.recv(message, ZMQ_DONTWAIT))
   {
      string raw = message.getData();
      if(InpVerbose) Print("CMD reçue: ", raw);
      ExecuteCommand(raw);
   }
}

//+------------------------------------------------------------------+
//| Parse et exécute une commande JSON                               |
//+------------------------------------------------------------------+
void ExecuteCommand(string json)
{
   string action     = JsonGetString(json, "action");
   double lot        = JsonGetDouble(json, "lot");
   double sl         = JsonGetDouble(json, "sl");
   double tp         = JsonGetDouble(json, "tp");
   long   ticket     = (long)JsonGetDouble(json, "ticket");
   double partialPct = JsonGetDouble(json, "partial_pct");
   double newSl      = JsonGetDouble(json, "new_sl");
   double newTp      = JsonGetDouble(json, "new_tp");
   string reason     = JsonGetString(json, "reason");

   Print("EXEC: action=", action, " lot=", lot,
         " sl=", sl, " tp=", tp, " | ", reason);

   if(action == "BUY")        CmdBuy(lot, sl, tp);
   else if(action == "SELL")  CmdSell(lot, sl, tp);
   else if(action == "CLOSE_PARTIAL") CmdClosePartial((ulong)ticket, partialPct);
   else if(action == "BREAKEVEN")     CmdBreakeven((ulong)ticket);
   else if(action == "MOVE_SL")       CmdModifySL((ulong)ticket, newSl);
   else if(action == "MOVE_TP")       CmdModifyTP((ulong)ticket, newTp);
   else if(action == "TRAIL")         CmdTrail((ulong)ticket, newSl);
   else if(action == "CLOSE_ALL")     CmdCloseAll();
   else Print("Action inconnue: ", action);
}

//+------------------------------------------------------------------+
//| BUY Market                                                       |
//+------------------------------------------------------------------+
void CmdBuy(double lot, double sl, double tp)
{
   if(lot <= 0 || lot > InpMaxLot) { Print("Lot invalide: ", lot); return; }
   NormalizeSlTp(sl, tp);

   if(!trade.Buy(lot, _Symbol, 0, sl, tp, "OMEGA_BUY"))
      Print("BUY ERREUR: ", trade.ResultRetcodeDescription());
   else
      Print("BUY OK | lot=", lot, " SL=", sl, " TP=", tp);
}

//+------------------------------------------------------------------+
//| SELL Market                                                      |
//+------------------------------------------------------------------+
void CmdSell(double lot, double sl, double tp)
{
   if(lot <= 0 || lot > InpMaxLot) { Print("Lot invalide: ", lot); return; }
   NormalizeSlTp(sl, tp);

   if(!trade.Sell(lot, _Symbol, 0, sl, tp, "OMEGA_SELL"))
      Print("SELL ERREUR: ", trade.ResultRetcodeDescription());
   else
      Print("SELL OK | lot=", lot, " SL=", sl, " TP=", tp);
}

//+------------------------------------------------------------------+
//| Fermeture partielle d'une position (% du lot)                    |
//+------------------------------------------------------------------+
void CmdClosePartial(ulong ticket, double pct)
{
   if(!PositionSelectByTicket(ticket)) { Print("Position introuvable: ", ticket); return; }
   double originalLot = PositionGetDouble(POSITION_VOLUME);
   double lotToClose  = NormalizeLot(originalLot * pct / 100.0);
   if(lotToClose <= 0) { Print("Lot partiel invalide"); return; }

   if(!trade.PositionClosePartial(ticket, lotToClose))
      Print("CLOSE_PARTIAL ERREUR: ", trade.ResultRetcodeDescription());
   else
      Print("CLOSE_PARTIAL OK | ticket=", ticket, " lot=", lotToClose, " (", pct, "%)");
}

//+------------------------------------------------------------------+
//| Breakeven : déplace SL au prix d'entrée + spread                 |
//+------------------------------------------------------------------+
void CmdBreakeven(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) { Print("Position introuvable: ", ticket); return; }
   double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSL  = PositionGetDouble(POSITION_SL);
   double currentTP  = PositionGetDouble(POSITION_TP);
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double spread     = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double newSL;
   if(posType == POSITION_TYPE_BUY)
      newSL = openPrice + spread * 1.5;   // légèrement au dessus de l'entrée
   else
      newSL = openPrice - spread * 1.5;

   newSL = NormalizeDouble(newSL, _Digits);

   // Ne pas reculer le SL
   if(posType == POSITION_TYPE_BUY  && newSL <= currentSL) { Print("BE ignoré: SL déjà meilleur"); return; }
   if(posType == POSITION_TYPE_SELL && newSL >= currentSL) { Print("BE ignoré: SL déjà meilleur"); return; }

   if(!trade.PositionModify(ticket, newSL, currentTP))
      Print("BREAKEVEN ERREUR: ", trade.ResultRetcodeDescription());
   else
      Print("BREAKEVEN OK | ticket=", ticket, " newSL=", newSL);
}

//+------------------------------------------------------------------+
//| Modifier uniquement le SL                                        |
//+------------------------------------------------------------------+
void CmdModifySL(ulong ticket, double newSL)
{
   if(!PositionSelectByTicket(ticket)) { Print("Position introuvable: ", ticket); return; }
   double currentTP = PositionGetDouble(POSITION_TP);
   newSL = NormalizeDouble(newSL, _Digits);

   if(!trade.PositionModify(ticket, newSL, currentTP))
      Print("MOVE_SL ERREUR: ", trade.ResultRetcodeDescription());
   else
      Print("MOVE_SL OK | ticket=", ticket, " newSL=", newSL);
}

//+------------------------------------------------------------------+
//| Modifier uniquement le TP                                        |
//+------------------------------------------------------------------+
void CmdModifyTP(ulong ticket, double newTP)
{
   if(!PositionSelectByTicket(ticket)) { Print("Position introuvable: ", ticket); return; }
   double currentSL = PositionGetDouble(POSITION_SL);
   newTP = NormalizeDouble(newTP, _Digits);

   if(!trade.PositionModify(ticket, currentSL, newTP))
      Print("MOVE_TP ERREUR: ", trade.ResultRetcodeDescription());
   else
      Print("MOVE_TP OK | ticket=", ticket, " newTP=", newTP);
}

//+------------------------------------------------------------------+
//| Trail : déplace le SL vers newSL si meilleur que l'actuel        |
//+------------------------------------------------------------------+
void CmdTrail(ulong ticket, double newSL)
{
   if(!PositionSelectByTicket(ticket)) { Print("Position introuvable: ", ticket); return; }
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   newSL = NormalizeDouble(newSL, _Digits);

   // Vérification : le trail ne doit pas reculer le SL
   if(posType == POSITION_TYPE_BUY  && newSL <= currentSL) return;
   if(posType == POSITION_TYPE_SELL && newSL >= currentSL) return;

   if(!trade.PositionModify(ticket, newSL, currentTP))
      Print("TRAIL ERREUR: ", trade.ResultRetcodeDescription());
   else
      Print("TRAIL OK | ticket=", ticket, " newSL=", newSL);
}

//+------------------------------------------------------------------+
//| Ferme toutes les positions du symbole                            |
//+------------------------------------------------------------------+
void CmdCloseAll()
{
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
      {
         if(!trade.PositionClose(ticket))
            Print("CLOSE_ALL ERREUR ticket=", ticket, ": ", trade.ResultRetcodeDescription());
         else
            Print("CLOSE_ALL OK ticket=", ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Envoie les positions ouvertes vers l'agent Python                |
//+------------------------------------------------------------------+
void PushPositions()
{
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickVal= SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   string posArray = "";
   int count = 0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
      double lot        = PositionGetDouble(POSITION_VOLUME);
      double positionSL = PositionGetDouble(POSITION_SL);
      double positionTP = PositionGetDouble(POSITION_TP);
      double profit     = PositionGetDouble(POSITION_PROFIT);

      double currentPrice = (pType == POSITION_TYPE_BUY) ? bid : ask;
      double priceDiff    = (pType == POSITION_TYPE_BUY)
                            ? (currentPrice - openPrice)
                            : (openPrice - currentPrice);
      double profitPips   = (point > 0) ? priceDiff / point / 10.0 : 0;

      string typeStr = (pType == POSITION_TYPE_BUY) ? "BUY" : "SELL";

      string posJson = StringFormat(
         "{\"ticket\":%llu,\"type\":\"%s\",\"lot\":%.2f,"
         "\"open_price\":%.5f,\"sl\":%.5f,\"tp\":%.5f,"
         "\"profit\":%.2f,\"profit_pips\":%.1f}",
         ticket, typeStr, lot, openPrice,
         positionSL, positionTP, profit, profitPips
      );

      if(count > 0) posArray += ",";
      posArray += posJson;
      count++;
   }

   string fullJson = StringFormat(
      "{\"symbol\":\"%s\",\"ask\":%.5f,\"bid\":%.5f,"
      "\"timestamp\":%d,\"positions\":[%s]}",
      _Symbol, ask, bid, (int)TimeCurrent(), posArray
   );

   ZmqMsg msg(fullJson);
   if(!pushSocket.send(msg, ZMQ_DONTWAIT))
      if(InpVerbose) Print("PushPositions: send failed (agent pas encore connecté?)");
}

//+------------------------------------------------------------------+
//| Helpers JSON minimalistes                                        |
//+------------------------------------------------------------------+
string JsonGetString(string json, string key)
{
   string search = "\"" + key + "\"";
   int pos = StringFind(json, search);
   if(pos < 0) return "";
   pos = StringFind(json, ":", pos);
   if(pos < 0) return "";
   pos++;
   while(pos < StringLen(json) && StringGetCharacter(json, pos) == 32) pos++;
   if(StringGetCharacter(json, pos) != 34) return "";  // 34 = '"'
   pos++;
   int end = StringFind(json, "\"", pos);
   if(end < 0) return "";
   return StringSubstr(json, pos, end - pos);
}

double JsonGetDouble(string json, string key)
{
   string search = "\"" + key + "\"";
   int pos = StringFind(json, search);
   if(pos < 0) return 0.0;
   pos = StringFind(json, ":", pos);
   if(pos < 0) return 0.0;
   pos++;
   while(pos < StringLen(json) && StringGetCharacter(json, pos) == 32) pos++;
   // Lire jusqu'à , ou } ou ]
   int end = pos;
   int len = StringLen(json);
   while(end < len)
   {
      ushort c = StringGetCharacter(json, end);
      if(c == 44 || c == 125 || c == 93) break;  // , } ]
      end++;
   }
   string val = StringSubstr(json, pos, end - pos);
   StringTrimRight(val);
   return StringToDouble(val);
}

//+------------------------------------------------------------------+
//| Normalise lot selon contraintes broker                           |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / stepLot) * stepLot;
   lot = MathMax(minLot, MathMin(maxLot, MathMin(lot, InpMaxLot)));
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Normalise SL/TP selon digits du symbole                          |
//+------------------------------------------------------------------+
void NormalizeSlTp(double &sl, double &tp)
{
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);
}
//+------------------------------------------------------------------+
