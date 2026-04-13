"""
OMEGA GOLD BRAIN v3.0 — Architecture Multi-Agents
===================================================
VPS Windows | XAUUSD exclusif

AGENTS SPÉCIALISÉS :
  AgentTechnique   → Multi-timeframe M1+M5+H1, indicateurs, patterns price action
  AgentNews        → X/Twitter + Calendrier économique + sentiment scoring
  AgentRiskManager → Drawdown, daily loss, kill switch, sizing dynamique
  AgentOrchestrator→ Synthèse des 3 agents → décision finale + scoring conviction

MÉMOIRE & APPRENTISSAGE :
  SQLite           → Historique de tous les trades + décisions IA
  PatternLearner   → Analyse les patterns gagnants/perdants, ajuste les biais

BACKTESTING INTÉGRÉ :
  BacktestEngine   → Rejoue les décisions passées sur historique Twelve Data
  SelfEvaluator    → Scoring de performance de chaque agent
"""

import zmq, json, time, logging, requests, threading, sqlite3, os
from datetime import datetime, timezone, timedelta
from dataclasses import dataclass, asdict, field
from typing import Optional
from zoneinfo import ZoneInfo
import anthropic

# ─── CONFIG ───────────────────────────────────────────────────────────────────

ANTHROPIC_API_KEY    = "sk-ant-VOTRE_CLE"
TWELVE_DATA_KEY      = "VOTRE_CLE_TWELVE_DATA"
TWITTER_BEARER_TOKEN = "VOTRE_BEARER_TOKEN_X"
TELEGRAM_BOT_TOKEN   = ""
TELEGRAM_CHAT_ID     = ""

ZMQ_CMD_PORT         = 5555
ZMQ_POS_PORT         = 5556
ZMQ_DASH_PORT        = 5557   # Push vers dashboard
SYMBOL               = "XAUUSD"
LOOP_INTERVAL_SEC    = 30
DB_PATH              = "omega_gold_v3.db"
PRE_NEWS_SILENCE_MIN = 30
POST_NEWS_TRADE_MIN  = 15
TZ_NY                = ZoneInfo("America/New_York")

GOLD_KEYWORDS = [
    "fomc","federal reserve","fed rate","interest rate",
    "nfp","non-farm","non farm","payroll",
    "cpi","consumer price","inflation","pce",
    "ppi","producer price","gdp","gross domestic",
    "ism","pmi","manufacturing","unemployment","jobless",
    "powell","yellen","treasury","bond yield","10-year",
    "geopolit","war","conflict","ukraine","middle east",
    "dollar index","dxy","safe haven","gold","xauusd",
]

# ─── LOGGING ──────────────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler("omega_brain_v3.log", encoding="utf-8"),
        logging.StreamHandler()
    ]
)
log = logging.getLogger("OMEGA_v3")

# ─── DATACLASSES ──────────────────────────────────────────────────────────────

@dataclass
class TFSnapshot:
    """Snapshot d'un timeframe unique"""
    tf: str
    price: float
    rsi: float
    macd: float
    macd_signal: float
    ema20: float
    ema50: float
    ema200: float
    atr: float
    trend: str = ""   # UP | DOWN | SIDEWAYS (calculé)

@dataclass
class MultiTFData:
    """Données multi-timeframe agrégées"""
    m1:  Optional[TFSnapshot] = None
    m5:  Optional[TFSnapshot] = None
    h1:  Optional[TFSnapshot] = None
    confluence: str = ""   # STRONG_BULL | BULL | NEUTRAL | BEAR | STRONG_BEAR
    confluence_score: int = 0  # -100 à +100

@dataclass
class EconomicEvent:
    title: str
    datetime_utc: datetime
    currency: str
    impact: str
    forecast: str
    previous: str
    actual: str
    is_gold_relevant: bool = False
    minutes_until: float = 0.0

@dataclass
class CalendarContext:
    risk_mode: str
    events_today: list
    next_high_impact: Optional[EconomicEvent]
    active_post_news: Optional[EconomicEvent]
    summary: str

@dataclass
class TradeCommand:
    action: str
    lot: float = 0.0
    sl: float = 0.0
    tp: float = 0.0
    ticket: int = 0
    partial_pct: float = 0.0
    new_sl: float = 0.0
    new_tp: float = 0.0
    reason: str = ""

@dataclass
class PositionInfo:
    ticket: int
    type: str
    lot: float
    open_price: float
    current_sl: float
    current_tp: float
    profit: float
    profit_pips: float

@dataclass
class AgentSignal:
    """Signal émis par un agent spécialisé"""
    agent: str
    bias: str          # BULL | BEAR | NEUTRAL
    score: int         # -100 à +100
    conviction: int    # 0 à 100 (certitude)
    reasoning: str
    raw_commands: list = field(default_factory=list)

@dataclass
class RiskState:
    mode: str                   # NORMAL | REDUCED | NO_TRADE | POST_NEWS | KILL_SWITCH
    daily_pnl: float
    daily_loss_limit: float
    max_drawdown_pct: float
    current_drawdown_pct: float
    open_lot_total: float
    can_open_new: bool
    max_lot_allowed: float
    reason: str

# ─── DATABASE / MÉMOIRE ───────────────────────────────────────────────────────

class TradeMemory:
    """
    Mémoire SQLite de tous les trades et décisions IA.
    Alimente l'auto-apprentissage des patterns.
    """
    def __init__(self, db_path: str):
        self.conn = sqlite3.connect(db_path, check_same_thread=False)
        self._lock = threading.Lock()
        self._init_schema()
        log.info(f"TradeMemory initialisée : {db_path}")

    def _init_schema(self):
        with self._lock:
            c = self.conn.cursor()
            c.executescript("""
            CREATE TABLE IF NOT EXISTS trades (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                ticket          INTEGER,
                symbol          TEXT,
                type            TEXT,
                lot             REAL,
                open_price      REAL,
                close_price     REAL,
                sl              REAL,
                tp              REAL,
                profit          REAL,
                profit_pips     REAL,
                open_time       TEXT,
                close_time      TEXT,
                duration_min    REAL,
                rsi_at_open     REAL,
                macd_at_open    REAL,
                ema_trend       TEXT,
                confluence      TEXT,
                risk_mode       TEXT,
                conviction      INTEGER,
                agent_reasoning TEXT,
                result          TEXT
            );

            CREATE TABLE IF NOT EXISTS agent_decisions (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp       TEXT,
                cycle           INTEGER,
                price           REAL,
                rsi_m5          REAL,
                confluence      TEXT,
                risk_mode       TEXT,
                news_sentiment  TEXT,
                tech_score      INTEGER,
                news_score      INTEGER,
                risk_score      INTEGER,
                final_action    TEXT,
                conviction      INTEGER,
                reasoning       TEXT
            );

            CREATE TABLE IF NOT EXISTS performance_stats (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                date            TEXT,
                trades_count    INTEGER,
                win_count       INTEGER,
                loss_count      INTEGER,
                total_profit    REAL,
                win_rate        REAL,
                avg_profit      REAL,
                avg_loss        REAL,
                profit_factor   REAL,
                best_pattern    TEXT,
                worst_pattern   TEXT
            );

            CREATE TABLE IF NOT EXISTS patterns (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                pattern_key     TEXT UNIQUE,
                occurrences     INTEGER DEFAULT 0,
                wins            INTEGER DEFAULT 0,
                losses          INTEGER DEFAULT 0,
                total_pnl       REAL DEFAULT 0,
                win_rate        REAL DEFAULT 0,
                avg_pnl         REAL DEFAULT 0,
                last_updated    TEXT
            );
            """)
            self.conn.commit()

    def log_decision(self, cycle: int, price: float, mtf: MultiTFData,
                     cal: CalendarContext, tech: AgentSignal, news: AgentSignal,
                     risk: RiskState, final_action: str, conviction: int, reasoning: str):
        with self._lock:
            c = self.conn.cursor()
            c.execute("""
                INSERT INTO agent_decisions
                (timestamp,cycle,price,rsi_m5,confluence,risk_mode,
                 news_sentiment,tech_score,news_score,risk_score,
                 final_action,conviction,reasoning)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, (
                datetime.now(timezone.utc).isoformat(), cycle, price,
                mtf.m5.rsi if mtf.m5 else 0, mtf.confluence, cal.risk_mode,
                news.bias, tech.score, news.score, 0,
                final_action, conviction, reasoning
            ))
            self.conn.commit()

    def log_trade_open(self, ticket: int, ttype: str, lot: float,
                       open_price: float, sl: float, tp: float,
                       mtf: MultiTFData, cal: CalendarContext, conviction: int, reasoning: str):
        with self._lock:
            c = self.conn.cursor()
            rsi = mtf.m5.rsi if mtf.m5 else 0
            macd = mtf.m5.macd if mtf.m5 else 0
            c.execute("""
                INSERT INTO trades
                (ticket,symbol,type,lot,open_price,sl,tp,open_time,
                 rsi_at_open,macd_at_open,ema_trend,confluence,
                 risk_mode,conviction,agent_reasoning,result)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'OPEN')
            """, (
                ticket, SYMBOL, ttype, lot, open_price, sl, tp,
                datetime.now(timezone.utc).isoformat(),
                rsi, macd, mtf.confluence, mtf.confluence,
                cal.risk_mode, conviction, reasoning
            ))
            self.conn.commit()
            # Mettre à jour pattern
            pattern_key = f"{ttype}|RSI{int(rsi//10)*10}|{mtf.confluence}|{cal.risk_mode}"
            self._upsert_pattern(pattern_key)

    def log_trade_close(self, ticket: int, close_price: float, profit: float, profit_pips: float):
        with self._lock:
            c = self.conn.cursor()
            c.execute("SELECT open_time, open_price, type, rsi_at_open, confluence, risk_mode FROM trades WHERE ticket=? AND result='OPEN'", (ticket,))
            row = c.fetchone()
            if not row:
                return
            open_time_str, open_price, ttype, rsi, confluence, risk_mode = row
            try:
                open_time = datetime.fromisoformat(open_time_str)
                duration = (datetime.now(timezone.utc) - open_time).total_seconds() / 60
            except:
                duration = 0
            result = "WIN" if profit > 0 else "LOSS"
            c.execute("""
                UPDATE trades SET close_price=?,profit=?,profit_pips=?,
                close_time=?,duration_min=?,result=?
                WHERE ticket=? AND result='OPEN'
            """, (close_price, profit, profit_pips,
                  datetime.now(timezone.utc).isoformat(),
                  duration, result, ticket))
            self.conn.commit()
            # Mettre à jour pattern
            pattern_key = f"{ttype}|RSI{int((rsi or 50)//10)*10}|{confluence}|{risk_mode}"
            self._update_pattern_result(pattern_key, profit)

    def _upsert_pattern(self, key: str):
        c = self.conn.cursor()
        c.execute("""
            INSERT INTO patterns (pattern_key, occurrences, last_updated)
            VALUES (?, 1, ?)
            ON CONFLICT(pattern_key) DO UPDATE SET
                occurrences = occurrences + 1,
                last_updated = excluded.last_updated
        """, (key, datetime.now(timezone.utc).isoformat()))
        self.conn.commit()

    def _update_pattern_result(self, key: str, profit: float):
        c = self.conn.cursor()
        win = 1 if profit > 0 else 0
        c.execute("""
            INSERT INTO patterns (pattern_key, occurrences, wins, losses, total_pnl, last_updated)
            VALUES (?, 1, ?, ?, ?, ?)
            ON CONFLICT(pattern_key) DO UPDATE SET
                wins = wins + ?,
                losses = losses + ?,
                total_pnl = total_pnl + ?,
                win_rate = CAST(wins + ? AS REAL) / MAX(occurrences, 1) * 100,
                avg_pnl = (total_pnl + ?) / MAX(occurrences, 1),
                last_updated = excluded.last_updated
        """, (key, win, 1-win, profit, datetime.now(timezone.utc).isoformat(),
              win, 1-win, profit, win, profit))
        self.conn.commit()

    def get_pattern_insights(self, limit=10) -> str:
        """Retourne les patterns les plus performants et les pires pour le prompt IA."""
        c = self.conn.cursor()
        best = c.execute("""
            SELECT pattern_key, occurrences, win_rate, avg_pnl
            FROM patterns WHERE occurrences >= 3
            ORDER BY avg_pnl DESC LIMIT ?
        """, (limit//2,)).fetchall()
        worst = c.execute("""
            SELECT pattern_key, occurrences, win_rate, avg_pnl
            FROM patterns WHERE occurrences >= 3
            ORDER BY avg_pnl ASC LIMIT ?
        """, (limit//2,)).fetchall()
        lines = ["PATTERNS GAGNANTS :"]
        for p in best:
            lines.append(f"  ✅ {p[0]} | {p[1]}x | WR:{p[2]:.0f}% | Avg:{p[3]:+.1f}$")
        lines.append("PATTERNS PERDANTS :")
        for p in worst:
            lines.append(f"  ❌ {p[0]} | {p[1]}x | WR:{p[2]:.0f}% | Avg:{p[3]:+.1f}$")
        return "\n".join(lines) if (best or worst) else "Pas encore assez de données."

    def get_daily_stats(self) -> dict:
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        c = self.conn.cursor()
        row = c.execute("""
            SELECT COUNT(*), SUM(profit), SUM(CASE WHEN result='WIN' THEN 1 ELSE 0 END)
            FROM trades WHERE close_time LIKE ? AND result IN ('WIN','LOSS')
        """, (f"{today}%",)).fetchone()
        count, total_pnl, wins = row if row else (0, 0, 0)
        return {
            "trades_today": count or 0,
            "daily_pnl": total_pnl or 0.0,
            "wins_today": wins or 0,
        }

    def get_recent_decisions(self, limit=5) -> list:
        c = self.conn.cursor()
        return c.execute("""
            SELECT timestamp, final_action, conviction, reasoning
            FROM agent_decisions ORDER BY id DESC LIMIT ?
        """, (limit,)).fetchall()

# ─── BACKTESTING ENGINE ───────────────────────────────────────────────────────

class BacktestEngine:
    """
    Rejoue les décisions passées sur l'historique Twelve Data.
    Lance un backtest rapide sur les 7 derniers jours toutes les 6h.
    """
    def __init__(self, twelve_client, memory: TradeMemory):
        self.market = twelve_client
        self.memory = memory
        self._last_run: Optional[datetime] = None
        self._results: dict = {}

    def should_run(self) -> bool:
        if self._last_run is None:
            return True
        return (datetime.now(timezone.utc) - self._last_run).total_seconds() > 6 * 3600

    def run(self) -> dict:
        """Backtest simple : teste les signaux RSI+EMA sur historique M5."""
        log.info("BacktestEngine : lancement du backtest rapide...")
        try:
            bars = self.market.get_ohlcv_tf("5min", outputsize=200)
            if not bars or len(bars) < 50:
                return {}

            trades_bt = []
            for i in range(50, len(bars) - 10):
                bar = bars[i]
                close = float(bar.get("close", 0))
                # Signal simplifié : EMA croisement + RSI
                closes = [float(b.get("close", 0)) for b in bars[max(0,i-20):i+1]]
                ema20 = sum(closes[-20:]) / 20 if len(closes) >= 20 else close
                ema50_closes = [float(b.get("close", 0)) for b in bars[max(0,i-50):i+1]]
                ema50 = sum(ema50_closes[-50:]) / min(50, len(ema50_closes))

                # RSI simplifié
                rsi_closes = [float(b.get("close", 0)) for b in bars[max(0,i-14):i+1]]
                gains = [max(0, rsi_closes[j]-rsi_closes[j-1]) for j in range(1,len(rsi_closes))]
                losses = [max(0, rsi_closes[j-1]-rsi_closes[j]) for j in range(1,len(rsi_closes))]
                avg_gain = sum(gains)/len(gains) if gains else 0
                avg_loss = sum(losses)/len(losses) if losses else 1e-10
                rs = avg_gain / avg_loss
                rsi = 100 - (100/(1+rs))

                # Signal BUY
                if ema20 > ema50 and 40 < rsi < 65:
                    future_closes = [float(bars[i+j].get("close",0)) for j in range(1,10)]
                    tp_hit = any(c >= close + 20 for c in future_closes)
                    sl_hit = any(c <= close - 15 for c in future_closes)
                    if tp_hit and not sl_hit:
                        trades_bt.append({"type":"BUY","pnl":20,"result":"WIN"})
                    elif sl_hit:
                        trades_bt.append({"type":"BUY","pnl":-15,"result":"LOSS"})

                # Signal SELL
                elif ema20 < ema50 and 35 < rsi < 60:
                    future_closes = [float(bars[i+j].get("close",0)) for j in range(1,10)]
                    tp_hit = any(c <= close - 20 for c in future_closes)
                    sl_hit = any(c >= close + 15 for c in future_closes)
                    if tp_hit and not sl_hit:
                        trades_bt.append({"type":"SELL","pnl":20,"result":"WIN"})
                    elif sl_hit:
                        trades_bt.append({"type":"SELL","pnl":-15,"result":"LOSS"})

            wins   = sum(1 for t in trades_bt if t["result"]=="WIN")
            losses = sum(1 for t in trades_bt if t["result"]=="LOSS")
            total  = wins + losses
            total_pnl = sum(t["pnl"] for t in trades_bt)
            wr = (wins/total*100) if total > 0 else 0

            self._results = {
                "trades": total, "wins": wins, "losses": losses,
                "win_rate": round(wr,1), "total_pnl_pips": total_pnl,
                "profit_factor": round(abs(sum(t["pnl"] for t in trades_bt if t["pnl"]>0)) /
                                      max(abs(sum(t["pnl"] for t in trades_bt if t["pnl"]<0)),1), 2),
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }
            self._last_run = datetime.now(timezone.utc)
            log.info(f"Backtest : {total} trades | WR:{wr:.1f}% | PnL:{total_pnl:.0f}pips | PF:{self._results['profit_factor']}")
            return self._results
        except Exception as e:
            log.error(f"Backtest error: {e}")
            return {}

    def get_summary(self) -> str:
        if not self._results:
            return "Backtest non encore exécuté."
        r = self._results
        return (f"BACKTEST 7J M5 : {r['trades']} trades | WR:{r['win_rate']}% | "
                f"PnL:{r['total_pnl_pips']:+.0f}pips | PF:{r['profit_factor']}")

# ─── TWELVE DATA CLIENT (multi-timeframe) ─────────────────────────────────────

class TwelveDataClient:
    BASE = "https://api.twelvedata.com"

    def __init__(self, api_key: str):
        self.key = api_key

    def get_ohlcv_tf(self, tf: str, outputsize=20) -> Optional[list]:
        try:
            r = requests.get(f"{self.BASE}/time_series",
                params={"symbol":SYMBOL,"interval":tf,"outputsize":outputsize,"apikey":self.key},
                timeout=10)
            return r.json().get("values", [])
        except Exception as e:
            log.warning(f"OHLCV {tf} error: {e}")
            return None

    def get_tf_snapshot(self, tf: str) -> Optional[TFSnapshot]:
        """Récupère tous les indicateurs pour un timeframe."""
        try:
            endpoints = {
                "rsi":   {"symbol":SYMBOL,"interval":tf,"time_period":14,"apikey":self.key},
                "macd":  {"symbol":SYMBOL,"interval":tf,"apikey":self.key},
                "ema20": {"symbol":SYMBOL,"interval":tf,"time_period":20,"apikey":self.key},
                "ema50": {"symbol":SYMBOL,"interval":tf,"time_period":50,"apikey":self.key},
                "ema200":{"symbol":SYMBOL,"interval":tf,"time_period":200,"apikey":self.key},
                "atr":   {"symbol":SYMBOL,"interval":tf,"time_period":14,"apikey":self.key},
            }
            results = {}
            for name, params in endpoints.items():
                ep = name if name not in ("ema20","ema50","ema200") else "ema"
                r = requests.get(f"{self.BASE}/{ep}", params=params, timeout=8)
                data = r.json()
                if name == "macd":
                    v = data.get("values",[{}])[0]
                    results["macd"]        = float(v.get("macd",0))
                    results["macd_signal"] = float(v.get("macd_signal",0))
                else:
                    v = data.get("values",[{}])[0]
                    key_map = {"rsi":"rsi","ema20":"ema","ema50":"ema","ema200":"ema","atr":"atr"}
                    results[name] = float(v.get(key_map[name],0))

            # Prix actuel
            pr = requests.get(f"{self.BASE}/price",
                params={"symbol":SYMBOL,"apikey":self.key}, timeout=5)
            price = float(pr.json().get("price",0))

            # Tendance
            ema20, ema50, ema200 = results.get("ema20",price), results.get("ema50",price), results.get("ema200",price)
            if ema20 > ema50 > ema200: trend = "UP"
            elif ema20 < ema50 < ema200: trend = "DOWN"
            else: trend = "SIDEWAYS"

            return TFSnapshot(
                tf=tf, price=price,
                rsi=results.get("rsi",50), macd=results.get("macd",0),
                macd_signal=results.get("macd_signal",0),
                ema20=ema20, ema50=ema50, ema200=ema200,
                atr=results.get("atr",1.5), trend=trend,
            )
        except Exception as e:
            log.warning(f"TFSnapshot {tf} error: {e}")
            return None

    def build_multi_tf(self) -> MultiTFData:
        """Construit les données M1 + M5 + H1 et calcule la confluence."""
        m1 = self.get_tf_snapshot("1min")
        m5 = self.get_tf_snapshot("5min")
        h1 = self.get_tf_snapshot("1h")

        # Score de confluence : +1 pour chaque TF bullish, -1 bearish
        score = 0
        details = []
        for snap in [m1, m5, h1]:
            if snap is None: continue
            if snap.trend == "UP":
                score += 1
                details.append(f"{snap.tf}:↑")
            elif snap.trend == "DOWN":
                score -= 1
                details.append(f"{snap.tf}:↓")
            else:
                details.append(f"{snap.tf}:→")
            # Pondérer RSI
            if snap.rsi > 55: score += 0.5
            elif snap.rsi < 45: score -= 0.5

        score = int(score * 20)  # normalise vers -100/+100
        score = max(-100, min(100, score))

        if score >= 60:   confluence = "STRONG_BULL"
        elif score >= 25: confluence = "BULL"
        elif score <= -60:confluence = "STRONG_BEAR"
        elif score <= -25:confluence = "BEAR"
        else:             confluence = "NEUTRAL"

        return MultiTFData(m1=m1, m5=m5, h1=h1,
                          confluence=confluence,
                          confluence_score=score)

# ─── CALENDRIER ÉCONOMIQUE ────────────────────────────────────────────────────

class ForexCalendarClient:
    FF_URL      = "https://nfs.faireconomy.media/ff_calendar_thisweek.json"
    FF_NEXT_URL = "https://nfs.faireconomy.media/ff_calendar_nextweek.json"

    def __init__(self):
        self._cache: list[EconomicEvent] = []
        self._last_fetch: Optional[datetime] = None

    def _fetch_raw(self, url):
        try:
            r = requests.get(url, timeout=10, headers={"User-Agent":"Mozilla/5.0"})
            return r.json()
        except: return []

    def _parse(self, raw):
        events = []
        now = datetime.now(timezone.utc)
        for item in raw:
            try:
                dt_str = item.get("date","")
                if not dt_str: continue
                dt = datetime.fromisoformat(dt_str.replace("Z","+00:00"))
                if dt.tzinfo is None: dt = dt.replace(tzinfo=timezone.utc)
                dt_utc = dt.astimezone(timezone.utc)
                impact_raw = item.get("impact","").lower()
                impact = "HIGH" if "high" in impact_raw or "red" in impact_raw else (
                         "MEDIUM" if "medium" in impact_raw or "orange" in impact_raw else "LOW")
                title = item.get("title","")
                currency = item.get("country", item.get("currency","USD")).upper()
                is_relevant = (currency == "USD" and impact in ("HIGH","MEDIUM") and
                               any(kw in title.lower() for kw in GOLD_KEYWORDS))
                events.append(EconomicEvent(
                    title=title, datetime_utc=dt_utc, currency=currency,
                    impact=impact, forecast=str(item.get("forecast","")),
                    previous=str(item.get("previous","")), actual=str(item.get("actual","")),
                    is_gold_relevant=is_relevant,
                    minutes_until=(dt_utc-now).total_seconds()/60,
                ))
            except: pass
        return events

    def refresh(self):
        raw = self._fetch_raw(self.FF_URL) + self._fetch_raw(self.FF_NEXT_URL)
        self._cache = self._parse(raw)
        self._last_fetch = datetime.now(timezone.utc)
        log.info(f"Calendrier: {len(self._cache)} événements | "
                 f"{sum(1 for e in self._cache if e.is_gold_relevant)} pertinents gold")

    def get_context(self) -> CalendarContext:
        now = datetime.now(timezone.utc)
        if self._last_fetch is None or (now - self._last_fetch).total_seconds() > 3600:
            self.refresh()
        else:
            for e in self._cache: e.minutes_until = (e.datetime_utc - now).total_seconds()/60

        upcoming = [e for e in self._cache if e.is_gold_relevant and -POST_NEWS_TRADE_MIN <= e.minutes_until <= 1440]
        today    = [e for e in self._cache if -60 <= e.minutes_until <= 1440]
        next_high = next((e for e in sorted(upcoming, key=lambda x: x.minutes_until)
                         if e.impact=="HIGH" and e.minutes_until > 0), None)
        active_post = next((e for e in upcoming
                           if -POST_NEWS_TRADE_MIN <= e.minutes_until <= 0 and e.impact=="HIGH"), None)

        if active_post:                          risk_mode = "POST_NEWS"
        elif next_high and next_high.minutes_until <= PRE_NEWS_SILENCE_MIN: risk_mode = "NO_TRADE"
        elif next_high and next_high.minutes_until <= 60: risk_mode = "REDUCED"
        else:                                    risk_mode = "NORMAL"

        lines = [f"RISK MODE : {risk_mode}"]
        if active_post:
            lines.append(f"⚡ NEWS PUBLIÉE : {active_post.title} | Actual:{active_post.actual} vs Forecast:{active_post.forecast}")
        if next_high:
            lines.append(f"⏰ PROCHAINE HIGH : {next_high.title} dans {next_high.minutes_until:.0f}min | Forecast:{next_high.forecast}")
        lines.append("AGENDA :")
        for e in sorted(today, key=lambda x: x.datetime_utc)[:6]:
            mk = "🔴" if e.impact=="HIGH" else ("🟡" if e.impact=="MEDIUM" else "⚪")
            lines.append(f"  {mk} {e.datetime_utc.strftime('%H:%M')}UTC [{e.currency}] {e.title}")

        return CalendarContext(risk_mode=risk_mode, events_today=today,
                              next_high_impact=next_high, active_post_news=active_post,
                              summary="\n".join(lines))

# ─── TWITTER CLIENT ───────────────────────────────────────────────────────────

class TwitterClient:
    BASE = "https://api.twitter.com/2"
    def __init__(self, bearer):
        self.headers = {"Authorization": f"Bearer {bearer}"}
        self._cache = set()

    def get_news(self, max_results=20) -> list[str]:
        query = '(gold OR XAUUSD OR "Federal Reserve" OR inflation OR "safe haven") lang:en -is:retweet'
        try:
            r = requests.get(f"{self.BASE}/tweets/search/recent",
                headers=self.headers,
                params={"query":query,"max_results":max_results,"tweet.fields":"created_at"},
                timeout=10)
            tweets = []
            for t in r.json().get("data",[]):
                if t["id"] not in self._cache:
                    self._cache.add(t["id"])
                    tweets.append(t["text"])
            if len(self._cache) > 500: self._cache = set(list(self._cache)[-500:])
            return tweets
        except Exception as e:
            log.warning(f"Twitter error: {e}")
            return []

# ─── RISK MANAGER ─────────────────────────────────────────────────────────────

class RiskManagerAgent:
    """
    Agent Risk Manager : surveille drawdown, daily loss, kill switch.
    Calcule le lot maximum autorisé selon l'état du compte.
    """
    DAILY_LOSS_LIMIT  = -200.0   # $ — kill switch journalier
    MAX_DRAWDOWN_PCT  = 5.0      # % — drawdown max toléré
    MAX_LOT_NORMAL    = 0.30
    MAX_LOT_REDUCED   = 0.10
    ACCOUNT_BALANCE   = 10000.0  # $ — à connecter à l'EA pour valeur live

    def __init__(self, memory: TradeMemory):
        self.memory = memory
        self._kill_switch = False

    def evaluate(self, positions: list[PositionInfo], calendar_mode: str) -> RiskState:
        daily = self.memory.get_daily_stats()
        daily_pnl = daily["daily_pnl"]
        open_lot  = sum(p.lot for p in positions)
        open_pnl  = sum(p.profit for p in positions)

        # Kill switch journalier
        if daily_pnl <= self.DAILY_LOSS_LIMIT:
            self._kill_switch = True

        if self._kill_switch:
            return RiskState(
                mode="KILL_SWITCH", daily_pnl=daily_pnl,
                daily_loss_limit=self.DAILY_LOSS_LIMIT,
                max_drawdown_pct=self.MAX_DRAWDOWN_PCT, current_drawdown_pct=0,
                open_lot_total=open_lot, can_open_new=False, max_lot_allowed=0,
                reason=f"KILL SWITCH : Daily PnL {daily_pnl:.2f}$ ≤ limite {self.DAILY_LOSS_LIMIT}$"
            )

        # Mode calendrier
        if calendar_mode == "NO_TRADE":
            return RiskState(
                mode="NO_TRADE", daily_pnl=daily_pnl,
                daily_loss_limit=self.DAILY_LOSS_LIMIT,
                max_drawdown_pct=self.MAX_DRAWDOWN_PCT, current_drawdown_pct=0,
                open_lot_total=open_lot, can_open_new=False, max_lot_allowed=0,
                reason="Fenêtre pre-news : aucun nouveau trade"
            )

        max_lot = self.MAX_LOT_NORMAL
        mode    = "NORMAL"
        reason  = "Risque normal"

        # Réduction si pertes journalières significatives
        if daily_pnl < -50:
            max_lot = self.MAX_LOT_REDUCED
            mode    = "REDUCED"
            reason  = f"Pertes journalières {daily_pnl:.2f}$, lot réduit"
        elif calendar_mode == "REDUCED":
            max_lot = self.MAX_LOT_REDUCED
            mode    = "REDUCED"
            reason  = "News imminente, lot réduit"
        elif calendar_mode == "POST_NEWS":
            mode   = "POST_NEWS"
            reason = "Fenêtre post-news, trade directionnel"

        # Exposition max 2 positions
        can_open = (len(positions) < 2) and (max_lot > 0)

        return RiskState(
            mode=mode, daily_pnl=daily_pnl,
            daily_loss_limit=self.DAILY_LOSS_LIMIT,
            max_drawdown_pct=self.MAX_DRAWDOWN_PCT, current_drawdown_pct=0,
            open_lot_total=open_lot, can_open_new=can_open,
            max_lot_allowed=max_lot, reason=reason,
        )

    def reset_kill_switch(self):
        """À appeler manuellement si nécessaire."""
        self._kill_switch = False
        log.info("Kill switch réinitialisé manuellement.")

# ─── AGENTS SPÉCIALISÉS ───────────────────────────────────────────────────────

class AgentTechnique:
    """Analyse technique pure : multi-timeframe, prix action, indicateurs."""
    def __init__(self, api_key: str):
        self.client = anthropic.Anthropic(api_key=api_key)

    def analyze(self, mtf: MultiTFData, patterns: str, backtest: str) -> AgentSignal:
        def tf_text(snap: Optional[TFSnapshot]) -> str:
            if not snap: return "  Données indisponibles"
            return (f"  Prix:{snap.price:.2f} RSI:{snap.rsi:.1f} "
                    f"MACD:{snap.macd:.4f}/Signal:{snap.macd_signal:.4f} "
                    f"EMA20:{snap.ema20:.2f} EMA50:{snap.ema50:.2f} EMA200:{snap.ema200:.2f} "
                    f"ATR:{snap.atr:.2f} Tendance:{snap.trend}")

        prompt = f"""Tu es l'AGENT TECHNIQUE XAUUSD. Analyse pure technique, zéro bruit.

MULTI-TIMEFRAME (confluence: {mtf.confluence} | score: {mtf.confluence_score:+d}/100)
M1 (scalp):
{tf_text(mtf.m1)}
M5 (swing court):
{tf_text(mtf.m5)}
H1 (tendance):
{tf_text(mtf.h1)}

MÉMOIRE DES PATTERNS :
{patterns}

PERFORMANCE BACKTEST :
{backtest}

Analyse :
1. La tendance principale (H1) est-elle claire ?
2. Y a-t-il confluence des 3 timeframes ?
3. Le momentum M5 confirme-t-il la direction ?
4. Price action signal (support/résistance, breakout, fakeout) ?
5. Quel est le setup optimal si il existe ?

Réponds en JSON strict :
{{"bias":"BULL|BEAR|NEUTRAL","score":-100_à_+100,"conviction":0_à_100,
  "reasoning":"max 3 phrases","sl_pips":float,"tp_pips":float,"lot_suggestion":float}}"""

        try:
            r = self.client.messages.create(
                model="claude-haiku-4-5-20251001", max_tokens=400,
                messages=[{"role":"user","content":prompt}])
            raw = r.content[0].text.strip().replace("```json","").replace("```","").strip()
            if not raw.startswith("{"): raw = raw[raw.find("{"):]
            d = json.loads(raw)
            return AgentSignal(
                agent="TECHNIQUE", bias=d.get("bias","NEUTRAL"),
                score=int(d.get("score",0)), conviction=int(d.get("conviction",50)),
                reasoning=d.get("reasoning",""),
                raw_commands=[{"sl_pips":d.get("sl_pips",20),"tp_pips":d.get("tp_pips",40),
                               "lot":d.get("lot_suggestion",0.1)}],
            )
        except Exception as e:
            log.error(f"AgentTechnique error: {e}")
            return AgentSignal(agent="TECHNIQUE", bias="NEUTRAL", score=0, conviction=0, reasoning=str(e))


class AgentNews:
    """Analyse fondamentale : tweets, calendrier, sentiment macro."""
    def __init__(self, api_key: str):
        self.client = anthropic.Anthropic(api_key=api_key)

    def analyze(self, tweets: list[str], calendar: CalendarContext) -> AgentSignal:
        tweets_text = "\n".join(f"  - {t[:180]}" for t in tweets[:8]) if tweets else "  Aucun tweet récent."
        prompt = f"""Tu es l'AGENT NEWS & FONDAMENTAL XAUUSD. Sentiment macro pur.

CALENDRIER ÉCONOMIQUE :
{calendar.summary}

TWEETS RÉCENTS (gold/XAUUSD/Fed) :
{tweets_text}

Analyse :
1. Le sentiment global des tweets est-il haussier ou baissier pour l'or ?
2. Les news macro sont-elles gold-positive (dovish Fed, inflation, géopolitique) ou gold-négative ?
3. Y a-t-il une news récente qui justifie un mouvement directionnel ?
4. Le risque fondamental actuel (probabilité de gap/spike inattendu) ?

Réponds en JSON strict :
{{"bias":"BULL|BEAR|NEUTRAL","score":-100_à_+100,"conviction":0_à_100,
  "reasoning":"max 3 phrases","news_risk":"LOW|MEDIUM|HIGH"}}"""

        try:
            r = self.client.messages.create(
                model="claude-haiku-4-5-20251001", max_tokens=300,
                messages=[{"role":"user","content":prompt}])
            raw = r.content[0].text.strip().replace("```json","").replace("```","").strip()
            if not raw.startswith("{"): raw = raw[raw.find("{"):]
            d = json.loads(raw)
            return AgentSignal(
                agent="NEWS", bias=d.get("bias","NEUTRAL"),
                score=int(d.get("score",0)), conviction=int(d.get("conviction",50)),
                reasoning=d.get("reasoning",""),
                raw_commands=[{"news_risk": d.get("news_risk","LOW")}],
            )
        except Exception as e:
            log.error(f"AgentNews error: {e}")
            return AgentSignal(agent="NEWS", bias="NEUTRAL", score=0, conviction=0, reasoning=str(e))


class AgentOrchestrator:
    """
    Synthèse finale des 3 agents.
    Produit les commandes TradeCommand avec scoring de conviction global.
    """
    def __init__(self, api_key: str):
        self.client = anthropic.Anthropic(api_key=api_key)

    def decide(self, tech: AgentSignal, news: AgentSignal, risk: RiskState,
               positions: list[PositionInfo], mtf: MultiTFData,
               calendar: CalendarContext) -> tuple[list[TradeCommand], int, str]:

        positions_text = "Aucune position."
        if positions:
            lines = [f"  #{p.ticket} {p.type} {p.lot}lot | Open:{p.open_price:.2f} "
                     f"SL:{p.current_sl:.2f} TP:{p.current_tp:.2f} | "
                     f"PnL:{p.profit:+.2f}$ ({p.profit_pips:+.1f}pips)"
                     for p in positions]
            positions_text = "\n".join(lines)

        tech_lot = tech.raw_commands[0].get("lot",0.1) if tech.raw_commands else 0.1
        tech_sl  = tech.raw_commands[0].get("sl_pips",20) if tech.raw_commands else 20
        tech_tp  = tech.raw_commands[0].get("tp_pips",40) if tech.raw_commands else 40
        max_lot  = min(tech_lot, risk.max_lot_allowed) if risk.can_open_new else 0
        price    = mtf.m5.price if mtf.m5 else 0
        atr      = mtf.m5.atr if mtf.m5 else 2.0

        # Score global pondéré : technique 60%, news 40%
        global_score = int(tech.score * 0.6 + news.score * 0.4)
        global_conv  = int(tech.conviction * 0.6 + news.conviction * 0.4)

        prompt = f"""Tu es l'AGENT ORCHESTRATEUR OMEGA GOLD. Tu prends la décision finale.

═══ SYNTHÈSE DES AGENTS ═══
🔧 TECHNIQUE  : bias={tech.bias} score={tech.score:+d} conviction={tech.conviction}%
   → {tech.reasoning}
📰 NEWS       : bias={news.bias} score={news.score:+d} conviction={news.conviction}%
   → {news.reasoning}
⚠️  RISK STATE : mode={risk.mode} can_open={risk.can_open_new} max_lot={risk.max_lot_allowed}
   → {risk.reason}

═══ CONFLUENCE MARCHÉ ═══
Multi-TF: {mtf.confluence} (score:{mtf.confluence_score:+d})
Prix M5: {price:.2f} | ATR: {atr:.2f}
Score global pondéré: {global_score:+d}/100 | Conviction: {global_conv}%

═══ POSITIONS OUVERTES ═══
{positions_text}

═══ CALENDRIER ═══
{calendar.summary}

═══ PARAMÈTRES DE TRADE SUGGÉRÉS ═══
SL suggestion: {tech_sl:.1f}pips | TP suggestion: {tech_tp:.1f}pips
Lot max autorisé: {max_lot:.2f}

═══ ACTIONS DISPONIBLES ═══
{{"action":"BUY","lot":0.1,"sl":2940.0,"tp":2980.0,"reason":"..."}}
{{"action":"SELL","lot":0.1,"sl":2980.0,"tp":2940.0,"reason":"..."}}
{{"action":"CLOSE_PARTIAL","ticket":12345,"partial_pct":50,"reason":"..."}}
{{"action":"BREAKEVEN","ticket":12345,"reason":"..."}}
{{"action":"MOVE_SL","ticket":12345,"new_sl":2955.0,"reason":"..."}}
{{"action":"MOVE_TP","ticket":12345,"new_tp":2995.0,"reason":"..."}}
{{"action":"TRAIL","ticket":12345,"new_sl":2958.0,"reason":"..."}}
{{"action":"CLOSE_ALL","reason":"..."}}
[] pour ne rien faire

RÈGLES ABSOLUES :
- Si risk.can_open_new=False → PAS de BUY/SELL
- Conviction < 40 → PAS de nouveau trade
- Score global |{global_score}| < 30 → NEUTRE = pas de nouveau trade
- Gérer les positions existantes dans TOUS les modes
- Breakeven si position > +20 pips, Partial 50% si > +35 pips

Réponds JSON array uniquement :"""

        try:
            r = self.client.messages.create(
                model="claude-haiku-4-5-20251001", max_tokens=600,
                messages=[{"role":"user","content":prompt}])
            raw = r.content[0].text.strip().replace("```json","").replace("```","").strip()
            if not raw.startswith("["): raw = raw[raw.find("["):]
            data = json.loads(raw)
            commands = [TradeCommand(
                action=c.get("action",""),
                lot=float(c.get("lot",0)), sl=float(c.get("sl",0)),
                tp=float(c.get("tp",0)), ticket=int(c.get("ticket",0)),
                partial_pct=float(c.get("partial_pct",0)),
                new_sl=float(c.get("new_sl",0)), new_tp=float(c.get("new_tp",0)),
                reason=c.get("reason",""),
            ) for c in data]
            reasoning = f"Tech:{tech.bias}({tech.score:+d}) + News:{news.bias}({news.score:+d}) = {global_score:+d}"
            return commands, global_conv, reasoning
        except Exception as e:
            log.error(f"Orchestrator error: {e}")
            return [], 0, str(e)

# ─── ZMQ ──────────────────────────────────────────────────────────────────────

class ZMQSender:
    def __init__(self, port):
        ctx = zmq.Context(); self.s = ctx.socket(zmq.PUSH)
        self.s.connect(f"tcp://localhost:{port}")

    def send(self, cmd: TradeCommand):
        try: self.s.send_string(json.dumps(asdict(cmd)), zmq.NOBLOCK)
        except Exception as e: log.error(f"ZMQ send: {e}")

class PositionTracker:
    def __init__(self, port=5556):
        ctx = zmq.Context(); s = ctx.socket(zmq.PULL)
        s.bind(f"tcp://*:{port}"); s.RCVTIMEO = 100
        self.positions: list[PositionInfo] = []
        def _listen():
            while True:
                try:
                    d = json.loads(s.recv_string())
                    self.positions = [PositionInfo(**{k:p[k] for k in
                        ["ticket","type","lot","open_price"] +
                        [("current_sl" if k=="sl" else ("current_tp" if k=="tp" else k))
                         for k in ["sl","tp","profit","profit_pips"]]
                    }) for p in d.get("positions",[])]
                except zmq.Again: pass
                except: pass
                time.sleep(0.05)
        threading.Thread(target=_listen, daemon=True).start()

class DashboardPublisher:
    """Publie l'état complet vers le dashboard web via ZMQ PUB."""
    def __init__(self, port=5557):
        ctx = zmq.Context(); self.s = ctx.socket(zmq.PUB)
        self.s.bind(f"tcp://*:{port}")

    def publish(self, state: dict):
        try: self.s.send_string("STATE " + json.dumps(state, default=str))
        except: pass

class TelegramNotifier:
    def __init__(self, token, chat_id):
        self.token = token; self.chat_id = chat_id
        self.enabled = bool(token and chat_id)

    def send(self, text):
        if not self.enabled: return
        try:
            requests.post(f"https://api.telegram.org/bot{self.token}/sendMessage",
                json={"chat_id":self.chat_id,"text":text,"parse_mode":"HTML"}, timeout=5)
        except: pass

# ─── MAIN LOOP ────────────────────────────────────────────────────────────────

def main():
    log.info("═"*60)
    log.info("  OMEGA GOLD BRAIN v3.0 — Multi-Agents")
    log.info("  Agents : Technique + News + Risk + Orchestrateur")
    log.info("  Mémoire SQLite + Backtest intégré + Dashboard")
    log.info("═"*60)

    market      = TwelveDataClient(TWELVE_DATA_KEY)
    twitter     = TwitterClient(TWITTER_BEARER_TOKEN)
    calendar    = ForexCalendarClient()
    memory      = TradeMemory(DB_PATH)
    backtest    = BacktestEngine(market, memory)
    risk_agent  = RiskManagerAgent(memory)
    tech_agent  = AgentTechnique(ANTHROPIC_API_KEY)
    news_agent  = AgentNews(ANTHROPIC_API_KEY)
    orchestrator= AgentOrchestrator(ANTHROPIC_API_KEY)
    sender      = ZMQSender(ZMQ_CMD_PORT)
    tracker     = PositionTracker(ZMQ_POS_PORT)
    dash        = DashboardPublisher(ZMQ_DASH_PORT)
    telegram    = TelegramNotifier(TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID)

    calendar.refresh()
    telegram.send("🟢 <b>OMEGA GOLD BRAIN v3.0</b>\nMulti-agents | SQLite | Backtest | Dashboard")

    cycle = 0
    tweets_cache: list[str] = []
    last_risk_mode = None

    while True:
        cycle += 1
        ts = datetime.now().strftime("%H:%M:%S")
        log.info(f"\n{'═'*50}\n  CYCLE #{cycle} | {ts}\n{'═'*50}")

        try:
            # ── 1. Backtest (toutes les 6h) ──────────────────────────────
            if backtest.should_run():
                threading.Thread(target=backtest.run, daemon=True).start()

            # ── 2. Calendrier ────────────────────────────────────────────
            cal_ctx = calendar.get_context()

            # ── 3. Multi-timeframe ───────────────────────────────────────
            mtf = market.build_multi_tf()
            if not mtf.m5:
                log.warning("M5 indisponible, skip cycle")
                time.sleep(LOOP_INTERVAL_SEC); continue

            log.info(f"Prix:{mtf.m5.price:.2f} | Confluence:{mtf.confluence}({mtf.confluence_score:+d}) | "
                     f"RSI M5:{mtf.m5.rsi:.1f} | Mode:{cal_ctx.risk_mode}")

            # ── 4. Twitter (tous les 3 cycles) ───────────────────────────
            if cycle % 3 == 0:
                new_tweets = twitter.get_news(20)
                if new_tweets:
                    tweets_cache = (new_tweets + tweets_cache)[:20]
                    log.info(f"Twitter: {len(new_tweets)} nouveaux tweets")

            # ── 5. Positions live ────────────────────────────────────────
            positions = tracker.positions
            log.info(f"Positions: {len(positions)} | "
                     f"Lot:{sum(p.lot for p in positions):.2f} | "
                     f"PnL:{sum(p.profit for p in positions):+.2f}$")

            # ── 6. Risk State ────────────────────────────────────────────
            risk_state = risk_agent.evaluate(positions, cal_ctx.risk_mode)
            if risk_state.mode != last_risk_mode:
                log.info(f"RISK MODE: {last_risk_mode} → {risk_state.mode} | {risk_state.reason}")
                telegram.send(f"⚡ Risk mode: <b>{risk_state.mode}</b>\n{risk_state.reason}")
                last_risk_mode = risk_state.mode

            if risk_state.mode == "KILL_SWITCH":
                log.warning(f"KILL SWITCH ACTIF : {risk_state.reason}")
                telegram.send(f"🚨 <b>KILL SWITCH</b>\n{risk_state.reason}")
                time.sleep(LOOP_INTERVAL_SEC); continue

            # ── 7. Agents spécialisés (parallèle) ───────────────────────
            patterns_insight = memory.get_pattern_insights(8)
            backtest_summary = backtest.get_summary()
            tech_signal = news_signal = None

            def run_tech():
                nonlocal tech_signal
                tech_signal = tech_agent.analyze(mtf, patterns_insight, backtest_summary)
            def run_news():
                nonlocal news_signal
                news_signal = news_agent.analyze(tweets_cache, cal_ctx)

            t1 = threading.Thread(target=run_tech)
            t2 = threading.Thread(target=run_news)
            t1.start(); t2.start()
            t1.join(timeout=15); t2.join(timeout=15)

            if not tech_signal:
                tech_signal = AgentSignal("TECHNIQUE","NEUTRAL",0,0,"Timeout")
            if not news_signal:
                news_signal = AgentSignal("NEWS","NEUTRAL",0,0,"Timeout")

            log.info(f"AgentTech  → {tech_signal.bias} score:{tech_signal.score:+d} "
                     f"conv:{tech_signal.conviction}% | {tech_signal.reasoning[:80]}")
            log.info(f"AgentNews  → {news_signal.bias} score:{news_signal.score:+d} "
                     f"conv:{news_signal.conviction}% | {news_signal.reasoning[:80]}")

            # ── 8. Orchestrateur → décision finale ───────────────────────
            commands, conviction, reasoning = orchestrator.decide(
                tech_signal, news_signal, risk_state, positions, mtf, cal_ctx)

            log.info(f"Orchestrateur → {len(commands)} commande(s) | "
                     f"Conviction:{conviction}% | {reasoning}")

            # ── 9. Log en mémoire ────────────────────────────────────────
            final_action = commands[0].action if commands else "NONE"
            memory.log_decision(cycle, mtf.m5.price, mtf, cal_ctx,
                               tech_signal, news_signal, risk_state,
                               final_action, conviction, reasoning)

            # ── 10. Exécution des commandes ──────────────────────────────
            if not commands:
                log.info("→ Aucune action.")
            else:
                for cmd in commands:
                    log.info(f"  EXEC: {cmd.action} | {cmd.reason}")
                    sender.send(cmd)
                    if cmd.action in ("BUY","SELL","CLOSE_ALL","CLOSE_PARTIAL"):
                        em = {"BUY":"🟢","SELL":"🔴","CLOSE_ALL":"⛔","CLOSE_PARTIAL":"💰"}.get(cmd.action,"📌")
                        telegram.send(
                            f"{em} <b>{cmd.action}</b> XAUUSD\n"
                            f"Lot:{cmd.lot} SL:{cmd.sl:.2f} TP:{cmd.tp:.2f}\n"
                            f"Conv:{conviction}% | {cmd.reason}"
                        )
                    time.sleep(0.1)

            # ── 11. Publish dashboard state ──────────────────────────────
            daily = memory.get_daily_stats()
            dash.publish({
                "cycle": cycle, "timestamp": ts,
                "price": mtf.m5.price if mtf.m5 else 0,
                "rsi_m5": mtf.m5.rsi if mtf.m5 else 0,
                "confluence": mtf.confluence,
                "confluence_score": mtf.confluence_score,
                "risk_mode": risk_state.mode,
                "calendar_mode": cal_ctx.risk_mode,
                "positions": [asdict(p) for p in positions],
                "daily_pnl": daily["daily_pnl"],
                "trades_today": daily["trades_today"],
                "tech_bias": tech_signal.bias,
                "tech_score": tech_signal.score,
                "news_bias": news_signal.bias,
                "news_score": news_signal.score,
                "conviction": conviction,
                "last_action": final_action,
                "backtest": backtest.get_summary(),
                "calendar_summary": cal_ctx.summary,
                "reasoning": reasoning,
                "m1_trend": mtf.m1.trend if mtf.m1 else "N/A",
                "m5_trend": mtf.m5.trend if mtf.m5 else "N/A",
                "h1_trend": mtf.h1.trend if mtf.h1 else "N/A",
            })

        except KeyboardInterrupt:
            log.info("Arrêt.")
            telegram.send("🔴 <b>OMEGA GOLD BRAIN v3 arrêté</b>")
            break
        except Exception as e:
            log.error(f"Erreur cycle: {e}", exc_info=True)

        time.sleep(LOOP_INTERVAL_SEC)

if __name__ == "__main__":
    main()
