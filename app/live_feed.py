"""Optional live feed: Binance public aggregate trades -> PostgreSQL.

Every received trade goes through the database function ingest_tick(...)
with source 'BINANCE', the same path the offline replay uses. The database
does the locking, duplicate detection, late-tick rule, alert crossing and
cooldown. Nothing here computes alerts or inserts rows directly.

Only instruments stored with exchange 'BINANCE' can be live (seed:
BTCUSDT, ETHUSDT). NSE prices are NOT live; use the replay for those.

Protocol (official docs: github.com/binance/binance-spot-api-docs,
web-socket-streams.md, checked 2026-09-25):
  endpoint  wss://data-stream.binance.vision  (market data only, no API key)
  stream    <symbol lowercase>@aggTrade, combined: /stream?streams=a/b
  message   {"stream": "...", "data": {"e": "aggTrade", "s": "BTCUSDT",
             "a": <agg trade id>, "p": "<price>", "q": "<qty>",
             "T": <trade time ms>, ...}}

Usage (project root, virtual environment active):
    python -m app.live_feed --symbols ETHUSDT --max-events 20
    python -m app.live_feed --symbols BTCUSDT ETHUSDT --duration-seconds 60
    Ctrl+C stops it cleanly at any time.

Exit codes: 0 finished/stopped, 1 invalid arguments or symbol,
2 database error or unsafe timeline, 3 network gave up after retries.
"""

import argparse
import json
import re
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from zoneinfo import ZoneInfo

import psycopg
from websockets.exceptions import ConnectionClosed, InvalidHandshake
from websockets.sync.client import connect as ws_connect

from app.config import conninfo

SOURCE = "BINANCE"
EXCHANGE = "BINANCE"
OFFICIAL_BASE_URL = "wss://data-stream.binance.vision"
SYMBOL_PATTERN = re.compile(r"^[A-Z0-9]{2,20}$")
DISPLAY_TZ = ZoneInfo("Asia/Kolkata")
EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)

MAX_RECONNECTS = 5          # consecutive failed attempts before giving up
MAX_BACKOFF_SECONDS = 30    # waits: 1, 2, 4, 8, 16 s
CLOCK_SKEW_SECONDS = 5      # stored ticks may be this far "ahead" (clock differences)
RECV_POLL_SECONDS = 1       # recv timeout, so limits and Ctrl+C are checked often

EXIT_OK = 0
EXIT_BAD_INPUT = 1
EXIT_DB_ERROR = 2
EXIT_NETWORK = 3


class MalformedEvent(ValueError):
    """The message is not a usable aggTrade event; it is skipped, never stored."""


class UnsupportedSymbol(ValueError):
    """The event is for a symbol we did not subscribe to."""


class ServerShutdown(Exception):
    """Binance announced it will close this connection; reconnect."""


@dataclass(frozen=True)
class LiveTrade:
    symbol: str
    price: Decimal
    volume: Decimal
    observed_at: datetime       # Binance trade time "T", timezone-aware UTC
    agg_trade_id: int           # Binance aggregate trade id "a"

    @property
    def source_event_id(self) -> str:
        # deterministic: the same provider event always gets the same id,
        # so a re-received event is a DUPLICATE in PostgreSQL
        return f"aggTrade:{self.agg_trade_id}"


# ---------------------------------------------------------------------
# parsing one WebSocket message
# ---------------------------------------------------------------------
def millis_to_datetime(ms: int) -> datetime:
    """Exact integer arithmetic (no float): 1672515782136 -> ...02.136+00:00."""
    return EPOCH + timedelta(milliseconds=ms)


def _decimal(value, name: str) -> Decimal:
    if not isinstance(value, str):               # Binance sends numbers as strings
        raise MalformedEvent(f"{name} must be a decimal string, got {type(value).__name__}")
    try:
        number = Decimal(value)
    except InvalidOperation:
        raise MalformedEvent(f"{name} {value!r} is not a number") from None
    if not number.is_finite():
        raise MalformedEvent(f"{name} {value!r} is not finite")
    return number


def _integer(data: dict, key: str, name: str) -> int:
    value = data.get(key)
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise MalformedEvent(f"{name} ({key!r}) must be a non-negative integer")
    return value


def parse_message(raw: str | bytes, allowed_symbols: set[str]) -> LiveTrade:
    """Turn one combined-stream message into a LiveTrade, or raise."""
    try:
        message = json.loads(raw)
    except (ValueError, TypeError):
        raise MalformedEvent("message is not valid JSON") from None
    if not isinstance(message, dict):
        raise MalformedEvent("message is not a JSON object")
    data = message.get("data", message)          # combined stream wraps the event
    if not isinstance(data, dict):
        raise MalformedEvent("'data' is not a JSON object")

    event_type = data.get("e")
    if event_type == "serverShutdown":
        raise ServerShutdown()
    if event_type != "aggTrade":
        raise MalformedEvent(f"unexpected event type {event_type!r}")

    symbol = data.get("s")
    if not isinstance(symbol, str) or not symbol:
        raise MalformedEvent("missing symbol ('s')")
    if symbol not in allowed_symbols:
        raise UnsupportedSymbol(f"event for {symbol}, which was not requested")

    price = _decimal(data.get("p"), "price ('p')")
    volume = _decimal(data.get("q"), "quantity ('q')")
    if price <= 0:
        raise MalformedEvent("price must be > 0")
    if volume < 0:
        raise MalformedEvent("quantity must be >= 0")
    trade_time = _integer(data, "T", "trade time")
    if trade_time == 0:
        raise MalformedEvent("trade time ('T') must be > 0")
    return LiveTrade(symbol, price, volume, millis_to_datetime(trade_time),
                     _integer(data, "a", "aggregate trade id"))


def stream_url(base_url: str, symbols: list[str]) -> str:
    streams = "/".join(f"{s.lower()}@aggTrade" for s in symbols)
    return f"{base_url.rstrip('/')}/stream?streams={streams}"


# ---------------------------------------------------------------------
# checks before subscribing
# ---------------------------------------------------------------------
class StartupError(Exception):
    def __init__(self, message: str, exit_code: int):
        super().__init__(message)
        self.exit_code = exit_code


def check_instruments(cur, symbols: list[str]) -> dict[str, int]:
    """Each symbol must be an ACTIVE (exchange='BINANCE', symbol) instrument.
    Returns {symbol: instrument_id}. Nothing is ever created here."""
    cur.execute("""SELECT symbol, instrument_id, is_active FROM instruments
                   WHERE exchange = %s AND symbol = ANY(%s)""", (EXCHANGE, symbols))
    found = {symbol: (iid, active) for symbol, iid, active in cur.fetchall()}
    unknown = [s for s in symbols if s not in found]
    if unknown:
        raise StartupError(
            f"not a BINANCE instrument in the database: {', '.join(unknown)}.\n"
            "  Only instruments stored with exchange 'BINANCE' can be live "
            "(seed data: BTCUSDT, ETHUSDT).\n"
            "  NSE/BSE instruments are not live; use the offline replay for them.",
            EXIT_BAD_INPUT)
    inactive = [s for s in symbols if not found[s][1]]
    if inactive:
        raise StartupError(f"instrument is inactive (is_active = false): {', '.join(inactive)}",
                           EXIT_BAD_INPUT)
    return {s: found[s][0] for s in symbols}


def check_timeline(cur, instrument_ids: list[int], now: datetime) -> None:
    """Refuse to start if stored ticks are ahead of real time (typically from
    a replay, whose timestamps can run minutes into the future). Live ticks
    carry real trade times, so they would all be LATE and fire no alerts."""
    cur.execute("SELECT max(observed_at) FROM price_ticks WHERE instrument_id = ANY(%s)",
                (instrument_ids,))
    latest = cur.fetchone()[0]
    if latest is not None and latest > now + timedelta(seconds=CLOCK_SKEW_SECONDS):
        raise StartupError(
            "Stored replay data is ahead of real time. Reset the demo database before "
            "starting live mode.\n"
            f"  latest stored tick: {fmt_time(latest)}\n"
            f"  current time:       {fmt_time(now)}\n"
            "  Live ticks would be older than that tick, so PostgreSQL would treat them "
            "as LATE\n  (stored, but no alerts). Nothing was deleted. "
            "Reset command: see docs/LIVE_FEED.md",
            EXIT_DB_ERROR)


# ---------------------------------------------------------------------
# database ingestion (one transaction per event)
# ---------------------------------------------------------------------
def ingest(conn, trade: LiveTrade):
    """ingest_tick(...) and read the alert_events PostgreSQL created for it."""
    with conn.transaction():
        with conn.cursor() as cur:
            cur.execute("SELECT status, tick_id FROM ingest_tick(%s, %s, %s, %s, %s, %s, %s)",
                        (EXCHANGE, trade.symbol, trade.observed_at, trade.price, trade.volume,
                         SOURCE, trade.source_event_id))
            status, tick_id = cur.fetchone()
            alerts = []
            if status == "INSERTED":
                cur.execute("""SELECT e.event_id, u.username, r.direction, r.threshold
                               FROM alert_events e
                               JOIN alert_rules r ON r.rule_id = e.rule_id
                               JOIN users u ON u.user_id = r.user_id
                               WHERE e.tick_id = %s ORDER BY e.event_id""", (tick_id,))
                alerts = cur.fetchall()
    return status, tick_id, alerts


# ---------------------------------------------------------------------
# output
# ---------------------------------------------------------------------
def fmt_time(ts: datetime) -> str:
    return ts.astimezone(DISPLAY_TZ).strftime("%Y-%m-%d %H:%M:%S IST")


def describe(trade: LiveTrade) -> str:
    t = trade.observed_at.astimezone(DISPLAY_TZ)
    return (f"{t:%H:%M:%S}.{t.microsecond // 1000:03d} {trade.symbol:<8} "
            f"{trade.price.normalize():>12f} vol={trade.volume.normalize():<12f} "
            f"{trade.source_event_id}")


# ---------------------------------------------------------------------
# the stream loop with bounded reconnects
# ---------------------------------------------------------------------
class Feed:
    """Reads the stream and ingests every event. connect / sleep / clock can
    be replaced in tests, so reconnects are tested without a network."""

    def __init__(self, conn, symbols, args, connect=ws_connect, sleep=time.sleep,
                 clock=time.monotonic, out=None):
        self.conn, self.symbols, self.args = conn, symbols, args
        self.connect, self.sleep, self.clock, self.out = connect, sleep, clock, out
        self.url = stream_url(args.base_url, symbols)
        self.allowed = set(symbols)
        self.counts = {"INSERTED": 0, "DUPLICATE": 0, "SKIPPED": 0, "ALERTS": 0, "RECONNECTS": 0}
        self.deadline = None if args.duration_seconds is None else clock() + args.duration_seconds
        self.stop_reason = None

    def say(self, text: str) -> None:
        print(text, file=self.out, flush=True)

    @property
    def handled(self) -> int:
        return self.counts["INSERTED"] + self.counts["DUPLICATE"]

    def limit_reached(self) -> bool:
        if self.args.max_events is not None and self.handled >= self.args.max_events:
            self.stop_reason = f"--max-events {self.args.max_events} reached"
        elif self.deadline is not None and self.clock() >= self.deadline:
            self.stop_reason = f"--duration-seconds {self.args.duration_seconds} reached"
        return self.stop_reason is not None

    def run(self) -> int:
        failures = 0
        while not self.limit_reached():
            self.got_event = False
            try:
                self.say(f"Connecting to {self.url}")
                with self.connect(self.url, open_timeout=10, close_timeout=1) as ws:
                    self.say("Connected. Waiting for trades...")
                    self.read(ws)             # returns only when a limit is reached
                    return EXIT_OK
            except ServerShutdown:
                reason = "Binance sent serverShutdown"
            except (ConnectionClosed, InvalidHandshake, OSError, TimeoutError) as e:
                reason = f"{type(e).__name__}: {e}" if str(e) else type(e).__name__
            if self.got_event:
                failures = 0                  # that connection worked: start counting again
            failures += 1
            self.counts["RECONNECTS"] += 1
            if failures > MAX_RECONNECTS:
                self.say(f"ERROR: network problem ({reason}); gave up after "
                         f"{MAX_RECONNECTS} reconnect attempts.\n"
                         "  The offline replay still works: "
                         "python -m app.replay data/replay_prices.csv")
                return EXIT_NETWORK
            wait = min(2 ** (failures - 1), MAX_BACKOFF_SECONDS)
            self.say(f"Connection lost ({reason}). Reconnecting in {wait} s "
                     f"(attempt {failures}/{MAX_RECONNECTS})...")
            self.sleep(wait)
        return EXIT_OK

    def read(self, ws) -> None:
        """Handle messages until a limit is reached; connection errors propagate."""
        while not self.limit_reached():
            try:
                raw = ws.recv(timeout=RECV_POLL_SECONDS)
            except TimeoutError:
                continue                       # quiet second: re-check the limits
            if self.args.verbose:
                self.say(f"  raw: {raw}")
            try:
                trade = parse_message(raw, self.allowed)
            except (MalformedEvent, UnsupportedSymbol) as e:
                self.counts["SKIPPED"] += 1
                self.say(f"  skipped message: {e}")
                continue
            self.got_event = True
            status, tick_id, alerts = ingest(self.conn, trade)   # psycopg.Error propagates
            self.counts[status] += 1
            self.counts["ALERTS"] += len(alerts)
            if not self.args.quiet or alerts:
                result = f"INSERTED tick={tick_id}" if status == "INSERTED" else "DUPLICATE"
                self.say(f"{describe(trade)} -> {result}")
            for event_id, username, direction, threshold in alerts:
                self.say(f"        ALERT event={event_id}: {username} {trade.symbol} "
                         f"{direction} {threshold.normalize():f}")

    def summary(self) -> None:
        c = self.counts
        self.say("")
        self.say(f"Stopped: {self.stop_reason or 'see above'}")
        self.say(f"Inserted:   {c['INSERTED']}")
        self.say(f"Duplicates: {c['DUPLICATE']}")
        self.say(f"Skipped:    {c['SKIPPED']} (malformed/unexpected messages, never stored)")
        self.say(f"Alerts:     {c['ALERTS']} (created by PostgreSQL)")
        self.say(f"Reconnects: {c['RECONNECTS']}")


# ---------------------------------------------------------------------
# command line
# ---------------------------------------------------------------------
def positive_int(text: str) -> int:
    value = int(text)
    if value <= 0:
        raise argparse.ArgumentTypeError("must be a whole number > 0")
    return value


def parse_args(argv):
    p = argparse.ArgumentParser(
        prog="python -m app.live_feed",
        description="Stream Binance public aggregate trades into PostgreSQL through "
                    "ingest_tick(). No API key; market data only.")
    p.add_argument("--symbols", nargs="+", required=True, metavar="SYMBOL",
                   help="BINANCE instruments from the database, e.g. BTCUSDT ETHUSDT")
    p.add_argument("--max-events", type=positive_int,
                   help="stop after this many events are stored or reported DUPLICATE")
    p.add_argument("--duration-seconds", type=positive_int,
                   help="stop after this many seconds")
    p.add_argument("--quiet", action="store_true", help="print only alerts and the summary")
    p.add_argument("--verbose", action="store_true", help="also print each raw message")
    p.add_argument("--base-url", default=OFFICIAL_BASE_URL,
                   help=f"WebSocket base URL (default: {OFFICIAL_BASE_URL})")
    args = p.parse_args(argv)
    args.symbols = list(dict.fromkeys(s.strip().upper() for s in args.symbols))
    bad = [s for s in args.symbols if not SYMBOL_PATTERN.match(s)]
    if bad:
        p.error(f"invalid symbol(s): {', '.join(bad)} (letters and digits only, e.g. BTCUSDT)")
    if not args.base_url.startswith(("wss://", "ws://")):
        p.error("--base-url must start with wss:// or ws://")
    return args


def main(argv=None, connect=ws_connect, sleep=time.sleep, clock=time.monotonic,
         now=lambda: datetime.now(timezone.utc)) -> int:
    args = parse_args(argv)
    try:
        conn = psycopg.connect(conninfo(), autocommit=True)
    except psycopg.Error as e:
        print(f"ERROR: cannot connect to the database: {e}", file=sys.stderr)
        return EXIT_DB_ERROR

    with conn:
        try:
            with conn.cursor() as cur:
                ids = check_instruments(cur, args.symbols)
                check_timeline(cur, list(ids.values()), now())
        except StartupError as e:
            print(f"ERROR: {e}", file=sys.stderr)
            return e.exit_code

        print(f"Database:  {conn.info.dbname}")
        print(f"Symbols:   {', '.join(args.symbols)} (exchange BINANCE, source {SOURCE})")
        limits = [f"max {args.max_events} events" if args.max_events else "",
                  f"max {args.duration_seconds} s" if args.duration_seconds else ""]
        print(f"Limits:    {', '.join(x for x in limits if x) or 'none'}  "
              "(Ctrl+C to stop)")
        feed = Feed(conn, args.symbols, args, connect=connect, sleep=sleep, clock=clock)
        try:
            code = feed.run()
        except KeyboardInterrupt:
            feed.stop_reason = "Ctrl+C"
            code = EXIT_OK
        except psycopg.Error as e:
            feed.stop_reason = "database error"
            print(f"ERROR: database error [{e.sqlstate}] "
                  f"{(e.diag.message_primary if e.diag else None) or e} (event rolled back)",
                  file=sys.stderr)
            code = EXIT_DB_ERROR
        feed.summary()
        return code


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:          # Ctrl+C before the stream started
        sys.exit(EXIT_OK)
