# OMEGA GOLD BRAIN v3.0 — Guide Complet
# Architecture Multi-Agents | SQLite | Backtest | Dashboard

## ARCHITECTURE COMPLÈTE

```
┌─────────────────────────────────────────────────────────────────┐
│                    OMEGA GOLD BRAIN v3.0                        │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │ TWELVE DATA  │  │  X/TWITTER   │  │ FOREX FACTORY CAL.   │  │
│  │ M1+M5+H1     │  │  Gold news   │  │ FOMC/NFP/CPI/PPI...  │  │
│  └──────┬───────┘  └──────┬───────┘  └──────────┬───────────┘  │
│         │                 │                      │              │
│  ┌──────▼───────┐  ┌──────▼───────┐  ┌──────────▼───────────┐  │
│  │ AGENT        │  │ AGENT        │  │ AGENT RISK MANAGER   │  │
│  │ TECHNIQUE    │  │ NEWS         │  │ Drawdown+KillSwitch  │  │
│  │ Multi-TF     │  │ Sentiment    │  │ Daily Loss Limit     │  │
│  │ Patterns     │  │ Macro Bias   │  │ Sizing dynamique     │  │
│  └──────┬───────┘  └──────┬───────┘  └──────────┬───────────┘  │
│         │                 │                      │              │
│         └─────────────────▼──────────────────────┘              │
│                    ┌──────────────────────┐                     │
│                    │   ORCHESTRATEUR IA   │                     │
│                    │   Score pondéré      │                     │
│                    │   Conviction 0-100%  │                     │
│                    │   Décision finale    │                     │
│                    └──────────┬───────────┘                     │
│                               │                                 │
│  ┌───────────────┐   ┌────────▼────────┐  ┌──────────────────┐  │
│  │ SQLite MEMORY │◄──│  TradeCommand   │  │  BacktestEngine  │  │
│  │ Patterns      │   │  JSON → ZMQ     │  │  7j M5 auto      │  │
│  │ Decisions     │   │  Port 5555      │  │  toutes 6h       │  │
│  │ Performance   │   └────────┬────────┘  └──────────────────┘  │
│  └───────────────┘            │                                 │
│                               │ ZMQ PUSH                        │
│  ┌────────────────────────────▼────────────────────────────┐    │
│  │          EA MT5 : OMEGA_GOLD_EXECUTOR.mq5               │    │
│  │  BUY/SELL/BREAKEVEN/TRAIL/CLOSE_PARTIAL/CLOSE_ALL       │    │
│  │  Positions → ZMQ PUSH port 5556 → PositionTracker       │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
│  ┌────────────────────────────────────────────────────────┐     │
│  │  ZMQ PUB port 5557 → dashboard_server.py → WS:5558     │     │
│  │  dashboard.html (navigateur VPS ou remote)              │     │
│  └────────────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────────┘
```

---

## FICHIERS

| Fichier                    | Rôle                                          |
|----------------------------|-----------------------------------------------|
| `agent_brain_v3.py`        | Agent principal — tout le cerveau IA          |
| `OMEGA_GOLD_EXECUTOR.mq5`  | EA MT5 (inchangé depuis v2)                   |
| `dashboard.html`           | Interface web temps réel                      |
| `dashboard_server.py`      | Proxy ZMQ → WebSocket pour le dashboard       |
| `omega_gold_v3.db`         | SQLite auto-créé au premier lancement         |

---

## INSTALLATION

### 1. Dépendances Python
```
pip install pyzmq anthropic requests websockets
```

### 2. Lancer les 3 processus (3 terminaux)

**Terminal 1 — Brain principal :**
```
python agent_brain_v3.py
```

**Terminal 2 — Serveur dashboard :**
```
python dashboard_server.py
```

**Terminal 3 — MT5 :**
Attacher OMEGA_GOLD_EXECUTOR.mq5 sur XAUUSD M5

**Navigateur :**
Ouvrir `dashboard.html` (double-clic ou via navigateur)

---

## AGENTS SPÉCIALISÉS

### AgentTechnique
- Analyse M1 + M5 + H1 en parallèle
- Calcule EMA20/50/200, RSI, MACD, ATR par timeframe
- Détermine tendance (UP/DOWN/SIDEWAYS) par TF
- Score de confluence -100 → +100
- Intègre mémoire des patterns SQLite
- Intègre résultats backtest

### AgentNews
- Analyse tweets récents sur gold/XAUUSD/Fed
- Évalue le calendrier économique (post/pre news)
- Sentiment macro : hawkish/dovish Fed, géopolitique
- News risk : LOW | MEDIUM | HIGH

### AgentRiskManager
- Kill switch si daily loss ≤ -200$
- Lot réduit si pertes journalières > -50$
- Maximum 2 positions simultanées
- Lot max selon mode (0.10 réduit / 0.30 normal)

### AgentOrchestrator
- Pondération : Technique 60% + News 40%
- Conviction minimale 40% pour ouvrir
- Score global |x| < 30 = NEUTRAL = no trade
- Breakeven automatique si position > +20 pips
- Partial close 50% si position > +35 pips

---

## MÉMOIRE SQLite

Tables auto-créées dans `omega_gold_v3.db` :

| Table               | Contenu                                       |
|---------------------|-----------------------------------------------|
| `trades`            | Tous les trades avec indicateurs à l'ouverture|
| `agent_decisions`   | Chaque décision IA avec scores                |
| `patterns`          | Win rate par configuration (type+RSI+confluence)|
| `performance_stats` | Stats journalières agrégées                   |

Visualiser avec DB Browser for SQLite (gratuit) :
https://sqlitebrowser.org/

---

## BACKTEST INTÉGRÉ

Lance automatiquement toutes les 6 heures sur les 200 dernières bougies M5.
Stratégie testée : EMA croisement + filtre RSI.
Résultats injectés dans le prompt AgentTechnique pour ajuster le biais.

---

## KILL SWITCH

Conditions d'activation automatique :
- PnL journalier ≤ -200$ (configurable : `DAILY_LOSS_LIMIT`)

Réinitialisation manuelle dans le code :
```python
risk_agent.reset_kill_switch()
```
Ou redémarrer le script (le compteur repart de 0 chaque jour).

---

## PARAMÈTRES CLÉS À AJUSTER

Dans `agent_brain_v3.py` :

```python
LOOP_INTERVAL_SEC    = 30    # Fréquence analyse
PRE_NEWS_SILENCE_MIN = 30    # Silence avant news
POST_NEWS_TRADE_MIN  = 15    # Fenêtre post-news
```

Dans `RiskManagerAgent` :
```python
DAILY_LOSS_LIMIT  = -200.0   # Kill switch $
MAX_DRAWDOWN_PCT  = 5.0      # Drawdown max %
MAX_LOT_NORMAL    = 0.30     # Lot max normal
MAX_LOT_REDUCED   = 0.10     # Lot max réduit
ACCOUNT_BALANCE   = 10000.0  # Balance $ (à connecter à l'EA)
```

---

## DASHBOARD

Sections :
- **Prix hero** : prix live, conviction globale, dernier signal, PnL jour
- **Agents** : biais + score de chaque agent avec barre visuelle
- **Confluence** : tendances M1/M5/H1 + score global
- **Risk Manager** : mode actif, exposition, lot max
- **Positions ouvertes** : tableau complet avec PnL live
- **Calendrier** : prochaines news avec code couleur
- **Terminal** : log des décisions en temps réel
- **Backtest** : résultats 7j M5 automatiques
- **Indicateurs** : RSI, EMA20/50/200, ATR, MACD M5
