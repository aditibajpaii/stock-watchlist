"""Phase 9 tests for app/live_feed.py. They need NO internet access.

Binance messages are fixtures in the format of the official docs
(binance-spot-api-docs, web-socket-streams.md, "Aggregate Trade Streams",
combined-stream wrapper). The network is replaced by fake connections,
plus one real WebSocket server on 127.0.0.1. Ingestion tests use a
throwaway PostgreSQL database cloned per test from a template built with
sql/00, 01, 03, 06. The dev database stock_watchlist is never touched.

Seed facts used: instruments 6 BINANCE BTCUSDT, 7 BINANCE ETHUSDT, 1 NSE
RELIANCE; rule 3 arjun BTCUSDT ABOVE 100000 (cooldown 60); rule 6 kavya
ETHUSDT BELOW 3000 (cooldown 120).

Run (project root, venv active):
    python -m unittest tests.test_live_feed -v
"""

import contextlib
import io
import json
import os
import re
import subprocess
import threading
import time
import unittest
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

import psycopg
from websockets.exceptions import ConnectionClosedError
from websockets.sync.server import serve

from app import live_feed
from app.live_feed import LiveTrade, MalformedEvent, ServerShutdown, UnsupportedSymbol

ROOT = Path(__file__).resolve().parent.parent
PG_BIN = Path(os.environ.get("PG_BIN", "/opt/homebrew/opt/postgresql@18/bin"))
TEMPLATE_DB = "stock_watchlist_p9_template"
TEST_DB = "stock_watchlist_p9_test"
BOTH = {"BTCUSDT", "ETHUSDT"}
DOC_TIME_MS = 1672515782136                      # value used in the official example


def now_ms(offset_seconds=0):
    return int((time.time() + offset_seconds) * 1000)


def agg(symbol="ETHUSDT", a=12345, p="2717.72000000", q="0.01830000", t=DOC_TIME_MS, **extra):
    """One combined-stream aggTrade message, field names as documented."""
    data = {"e": "aggTrade", "E": t + 1, "s": symbol, "a": a, "p": p, "q": q,
            "f": a * 2, "l": a * 2 + 1, "T": t, "m": True, "M": True}
    data.update(extra)
    return json.dumps({"stream": f"{symbol.lower()}@aggTrade", "data": data})


def admin(sql):
    with psycopg.connect(dbname="postgres", autocommit=True) as conn:
        conn.execute(sql)


def setUpModule():
    admin(f"DROP DATABASE IF EXISTS {TEST_DB}")
    admin(f"DROP DATABASE IF EXISTS {TEMPLATE_DB}")
    admin(f"CREATE DATABASE {TEMPLATE_DB}")
    args = [str(PG_BIN / "psql"), "-X", "-q", "-d", TEMPLATE_DB, "-v", "ON_ERROR_STOP=1"]
    for f in ("00_schema.sql", "01_seed.sql", "03_functions_triggers.sql", "06_indexes.sql"):
        args += ["-f", str(ROOT / "sql" / f)]
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr)


def tearDownModule():
    admin(f"DROP DATABASE IF EXISTS {TEST_DB}")
    admin(f"DROP DATABASE IF EXISTS {TEMPLATE_DB}")


# ---------------------------------------------------------------------
# fake network
# ---------------------------------------------------------------------
class FakeSocket:
    """Stands in for a websockets connection. After the scripted messages it
    raises `end` (default: the server closed the connection)."""

    def __init__(self, messages, end=None):
        self.messages = list(messages)
        self.end = end if end is not None else ConnectionClosedError(None, None)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def recv(self, timeout=None):
        if self.messages:
            item = self.messages.pop(0)
            if isinstance(item, BaseException):
                raise item
            return item
        raise self.end


class FakeConnect:
    """connect() replacement: each call uses the next scripted item, which is
    a FakeSocket or an exception to raise (a failed connection attempt)."""

    def __init__(self, *script):
        self.script = list(script)
        self.urls = []

    def __call__(self, url, **kwargs):
        self.urls.append(url)
        if not self.script:
            raise AssertionError("unexpected extra connection attempt")
        item = self.script.pop(0)
        if isinstance(item, BaseException):
            raise item
        return item


def never_connect(url, **kwargs):
    raise AssertionError("must not connect to the network")


class FakeClock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        self.t += 1.0            # every look at the clock = one second later
        return self.t


# =====================================================================
# 1-8: parsing (no database)
# =====================================================================
class ParseTests(unittest.TestCase):

    def test_01_valid_event_parses(self):
        trade = live_feed.parse_message(agg(), BOTH)
        self.assertEqual(trade, LiveTrade("ETHUSDT", Decimal("2717.72000000"), Decimal("0.01830000"),
                                          live_feed.millis_to_datetime(DOC_TIME_MS), 12345))
        # an unwrapped raw-stream event is accepted too
        raw = json.loads(agg())["data"]
        self.assertEqual(live_feed.parse_message(json.dumps(raw), BOTH), trade)
        self.assertEqual(live_feed.parse_message(agg().encode(), BOTH), trade)     # bytes

    def test_02_symbol_mapping_and_stream_url(self):
        self.assertEqual(live_feed.parse_message(agg("BTCUSDT"), BOTH).symbol, "BTCUSDT")
        self.assertEqual(live_feed.stream_url("wss://data-stream.binance.vision", ["BTCUSDT", "ETHUSDT"]),
                         "wss://data-stream.binance.vision/stream?streams=btcusdt@aggTrade/ethusdt@aggTrade")
        self.assertEqual(live_feed.OFFICIAL_BASE_URL, "wss://data-stream.binance.vision")
        self.assertEqual(live_feed.parse_args(["--symbols", "ethusdt", "ETHUSDT", " btcusdt "]).symbols,
                         ["ETHUSDT", "BTCUSDT"])                      # upper-cased, de-duplicated

    def test_03_04_price_and_volume_stay_exact_decimals(self):
        trade = live_feed.parse_message(agg(p="84321.12345678", q="0.00000001"), BOTH)
        self.assertIsInstance(trade.price, Decimal)
        self.assertIsInstance(trade.volume, Decimal)
        # exact decimal digits, never a binary float
        self.assertEqual(trade.price.as_tuple(), Decimal("84321.12345678").as_tuple())
        self.assertEqual(format(trade.volume, "f"), "0.00000001")
        self.assertEqual(live_feed.parse_message(agg(q="0.00000000"), BOTH).volume, Decimal(0))

    def test_05_trade_time_becomes_aware_utc_datetime(self):
        ts = live_feed.parse_message(agg(t=DOC_TIME_MS), BOTH).observed_at
        self.assertEqual(ts, datetime(2022, 12, 31, 19, 43, 2, 136000, tzinfo=timezone.utc))
        self.assertEqual(ts.utcoffset(), timedelta(0))
        # it is the TRADE time "T", not the event time "E"
        self.assertEqual(live_feed.parse_message(agg(t=1000, E=999999), BOTH).observed_at,
                         datetime(1970, 1, 1, 0, 0, 1, tzinfo=timezone.utc))

    def test_06_source_event_id_is_deterministic(self):
        a = live_feed.parse_message(agg(a=2089672646), BOTH)
        b = live_feed.parse_message(agg(a=2089672646, p="1.00000000"), BOTH)
        self.assertEqual(a.source_event_id, "aggTrade:2089672646")
        self.assertEqual(a.source_event_id, b.source_event_id)           # same provider id
        self.assertNotEqual(a.source_event_id,
                            live_feed.parse_message(agg(a=2089672647), BOTH).source_event_id)

    def test_07_malformed_events_are_rejected(self):
        bad = {
            "not json": "{nope",
            "json list": "[1, 2]",
            "data not object": json.dumps({"stream": "x", "data": 5}),
            "subscription reply": json.dumps({"result": None, "id": 1}),
            "trade event type": agg(e="trade"),
            "missing price": json.dumps({"data": {k: v for k, v in json.loads(agg())["data"].items() if k != "p"}}),
            "price as float": agg(p=2717.72),
            "price junk": agg(p="abc"),
            "price NaN": agg(p="NaN"),
            "price Infinity": agg(p="Infinity"),
            "price zero": agg(p="0.00000000"),
            "price negative": agg(p="-1"),
            "quantity negative": agg(q="-0.1"),
            "missing trade time": agg(T=None),
            "trade time string": agg(T="1672515782136"),
            "trade time zero": agg(t=0),
            "agg id bool": agg(a=True),
            "agg id negative": agg(a=-5),
            "symbol missing": agg(s=None),
        }
        for label, message in bad.items():
            with self.subTest(label):
                with self.assertRaises(MalformedEvent):
                    live_feed.parse_message(message, BOTH)
        with self.assertRaises(ServerShutdown):
            live_feed.parse_message(json.dumps({"stream": "!serverShutdown",
                                                "data": {"e": "serverShutdown", "E": 1}}), BOTH)

    def test_08a_unrequested_symbol_in_stream_rejected(self):
        with self.assertRaises(UnsupportedSymbol):
            live_feed.parse_message(agg("DOGEUSDT"), BOTH)
        with self.assertRaises(UnsupportedSymbol):
            live_feed.parse_message(agg("BTCUSDT"), {"ETHUSDT"})

    def test_08b_invalid_cli_arguments(self):
        for argv in (["--symbols", "BTC-USD"], ["--symbols", "ETHUSDT", "--max-events", "0"],
                     ["--symbols", "ETHUSDT", "--duration-seconds", "-3"],
                     ["--symbols", "ETHUSDT", "--base-url", "https://example.org"], []):
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as cm:
                    live_feed.parse_args(argv)
                self.assertEqual(cm.exception.code, 2)

    def test_13a_live_code_contains_no_insert_and_no_alert_logic(self):
        source = (ROOT / "app" / "live_feed.py").read_text()
        code = re.sub(r'"""[\s\S]*?"""|#[^\n]*', "", source)        # drop docstrings/comments
        self.assertNotRegex(code, r"(?i)\b(insert|update|delete)\s+(into\s+|from\s+)?\w")
        self.assertEqual(len(re.findall(r"FROM ingest_tick\(", code)), 1)       # the one SQL call
        self.assertNotRegex(code, r"(?i)threshold\s*[<>]|cooldown|previous")      # no crossing logic
        self.assertNotIn("uuid", code)                                            # ids are provider-derived


# =====================================================================
# 9-18: real PostgreSQL (throwaway DB)
# =====================================================================
class LiveDbTests(unittest.TestCase):

    def setUp(self):
        admin(f"DROP DATABASE IF EXISTS {TEST_DB}")
        admin(f"CREATE DATABASE {TEST_DB} TEMPLATE {TEMPLATE_DB}")
        self.old_db = os.environ.get("DB_NAME")
        os.environ["DB_NAME"] = TEST_DB
        self.sleeps = []

    def tearDown(self):
        if self.old_db is None:
            os.environ.pop("DB_NAME", None)
        else:
            os.environ["DB_NAME"] = self.old_db

    def run_feed(self, argv, connect, clock=None):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = live_feed.main(argv, connect=connect, sleep=self.sleeps.append,
                                  clock=clock or time.monotonic)
        return code, out.getvalue(), err.getvalue()

    def rows(self, sql, params=()):
        with psycopg.connect(dbname=TEST_DB) as conn:
            return conn.execute(sql, params).fetchall()

    def ticks(self):
        return self.rows("""SELECT i.symbol, t.source, t.source_event_id, t.observed_at, t.price, t.volume
                            FROM price_ticks t JOIN instruments i USING (instrument_id)
                            ORDER BY t.tick_id""")

    def test_08c_non_binance_or_unknown_symbol_refused_before_connecting(self):
        for symbol in ("RELIANCE", "DOGEUSDT"):
            with self.subTest(symbol=symbol):
                code, _, err = self.run_feed(["--symbols", "ETHUSDT", symbol], never_connect)
                self.assertEqual(code, live_feed.EXIT_BAD_INPUT)
                self.assertIn(f"not a BINANCE instrument in the database: {symbol}", err)
                self.assertIn("replay", err)
        self.assertEqual(self.ticks(), [])
        self.assertEqual(self.rows("SELECT count(*) FROM instruments")[0][0], 7)   # nothing created

    def test_09_inactive_instrument_refused(self):
        self.rows("UPDATE instruments SET is_active = false WHERE symbol = 'ETHUSDT' RETURNING 1")
        code, _, err = self.run_feed(["--symbols", "ETHUSDT"], never_connect)
        self.assertEqual(code, live_feed.EXIT_BAD_INPUT)
        self.assertIn("inactive", err)
        self.assertEqual(self.ticks(), [])

    def test_10_events_go_through_ingest_tick(self):
        admin(f"ALTER DATABASE {TEST_DB} SET track_functions = 'pl'")    # count function calls
        t0 = now_ms(-30)
        socket = FakeSocket([agg("ETHUSDT", 1, "2717.72000000", "0.01830000", t0),
                             agg("BTCUSDT", 7, "84321.50000000", "0.00100000", t0 + 5),
                             agg("ETHUSDT", 2, "2717.80000000", "1.50000000", t0 + 9)])
        code, out, _ = self.run_feed(["--symbols", "ETHUSDT", "BTCUSDT", "--max-events", "3"],
                                     FakeConnect(socket))
        self.assertEqual(code, live_feed.EXIT_OK, out)
        self.assertEqual(self.ticks(), [
            ("ETHUSDT", "BINANCE", "aggTrade:1", live_feed.millis_to_datetime(t0),
             Decimal("2717.72000000"), Decimal("0.01830000")),
            ("BTCUSDT", "BINANCE", "aggTrade:7", live_feed.millis_to_datetime(t0 + 5),
             Decimal("84321.50000000"), Decimal("0.00100000")),
            ("ETHUSDT", "BINANCE", "aggTrade:2", live_feed.millis_to_datetime(t0 + 9),
             Decimal("2717.80000000"), Decimal("1.50000000"))])
        self.assertIn("-> INSERTED tick=1", out)
        # PostgreSQL's own statistics: ingest_tick was called once per event
        # (the feed's backend has exited, so its statistics are flushed)
        calls = 0
        for _ in range(20):
            calls = self.rows("""SELECT coalesce(sum(calls), 0) FROM pg_stat_user_functions
                                 WHERE funcname = 'ingest_tick'""")[0][0]
            if calls:
                break
            time.sleep(0.1)
        self.assertEqual(calls, 3)

    def test_11_repeated_provider_event_is_duplicate(self):
        t0 = now_ms(-20)
        first = agg("ETHUSDT", 500, "2717.00000000", "0.1", t0)
        # the same aggTrade arrives again on a new connection after a drop
        code, out, _ = self.run_feed(
            ["--symbols", "ETHUSDT", "--max-events", "3"],
            FakeConnect(FakeSocket([first]),
                        FakeSocket([first, agg("ETHUSDT", 501, "2717.10000000", "0.2", t0 + 1)])))
        self.assertEqual(code, live_feed.EXIT_OK, out)
        self.assertEqual([t[2] for t in self.ticks()], ["aggTrade:500", "aggTrade:501"])
        self.assertIn("aggTrade:500 -> DUPLICATE", out)
        self.assertIn("Duplicates: 1", out)

    def test_12_crossing_creates_alert_through_postgresql(self):
        t0 = now_ms(-20)
        code, out, _ = self.run_feed(
            ["--symbols", "ETHUSDT", "--max-events", "3"],
            FakeConnect(FakeSocket([agg("ETHUSDT", 1, "3010.50000000", "1", t0),
                                    agg("ETHUSDT", 2, "2999.99000000", "1", t0 + 1000),     # crosses BELOW 3000
                                    agg("ETHUSDT", 3, "2998.00000000", "1", t0 + 2000)])))  # stays below
        self.assertEqual(code, live_feed.EXIT_OK, out)
        events = self.rows("""SELECT e.rule_id, t.source_event_id FROM alert_events e
                              JOIN price_ticks t USING (tick_id)""")
        self.assertEqual(events, [(6, "aggTrade:2")])
        self.assertRegex(out, r"aggTrade:2 -> INSERTED tick=2\n\s+ALERT event=1: kavya ETHUSDT BELOW 3000")
        self.assertIn("Alerts:     1", out)

    def test_13b_no_alert_without_postgresql_rule(self):
        # rule 6 disabled -> the same crossing yields no event: Python never creates one
        self.rows("UPDATE alert_rules SET is_active = false WHERE rule_id = 6 RETURNING 1")
        t0 = now_ms(-20)
        code, out, _ = self.run_feed(
            ["--symbols", "ETHUSDT", "--max-events", "2"],
            FakeConnect(FakeSocket([agg("ETHUSDT", 1, "3010.5", "1", t0),
                                    agg("ETHUSDT", 2, "2999.99", "1", t0 + 1000)])))
        self.assertEqual(code, live_feed.EXIT_OK)
        self.assertEqual(self.rows("SELECT count(*) FROM alert_events")[0][0], 0)
        self.assertNotIn("ALERT", out)

    def test_14_future_replay_data_refuses_live_start(self):
        future = datetime.now(timezone.utc) + timedelta(minutes=7)
        self.rows("SELECT * FROM ingest_tick('BINANCE', 'ETHUSDT', %s, 2700, NULL, 'REPLAY', 'run:000001')",
                  (future,))
        code, _, err = self.run_feed(["--symbols", "BTCUSDT", "ETHUSDT"], never_connect)
        self.assertEqual(code, live_feed.EXIT_DB_ERROR)
        self.assertIn("Stored replay data is ahead of real time. Reset the demo database", err)
        self.assertEqual(len(self.ticks()), 1)                        # nothing deleted
        # a different symbol without future data may start
        code, _, _ = self.run_feed(["--symbols", "BTCUSDT", "--max-events", "1"],
                                   FakeConnect(FakeSocket([agg("BTCUSDT", 1, "84000", "1", now_ms(-1))])))
        self.assertEqual(code, live_feed.EXIT_OK)

    def test_14b_small_clock_difference_is_tolerated(self):
        soon = datetime.now(timezone.utc) + timedelta(seconds=2)
        self.rows("SELECT * FROM ingest_tick('BINANCE', 'ETHUSDT', %s, 2700, NULL, 'BINANCE', 'aggTrade:1')",
                  (soon,))
        code, _, _ = self.run_feed(["--symbols", "ETHUSDT", "--max-events", "1"],
                                   FakeConnect(FakeSocket([agg("ETHUSDT", 2, "2701", "1", now_ms(3))])))
        self.assertEqual(code, live_feed.EXIT_OK)

    def test_15_max_events_and_duration_stop_the_feed(self):
        t0 = now_ms(-60)
        endless = FakeSocket([agg("BTCUSDT", i, f"84000.{i:02d}", "1", t0 + i) for i in range(1, 100)])
        code, out, _ = self.run_feed(["--symbols", "BTCUSDT", "--max-events", "5"], FakeConnect(endless))
        self.assertEqual(code, live_feed.EXIT_OK)
        self.assertEqual(len(self.ticks()), 5)
        self.assertIn("Stopped: --max-events 5 reached", out)
        # duration: a quiet connection (only recv timeouts) still stops on time
        quiet = FakeSocket([TimeoutError()] * 50)
        code, out, _ = self.run_feed(["--symbols", "BTCUSDT", "--duration-seconds", "10"],
                                     FakeConnect(quiet), clock=FakeClock())
        self.assertEqual(code, live_feed.EXIT_OK)
        self.assertIn("Stopped: --duration-seconds 10 reached", out)
        self.assertEqual(len(self.ticks()), 5)

    def test_16a_reconnects_with_backoff_and_keeps_going(self):
        t0 = now_ms(-30)
        e1, e2, e3 = (agg("ETHUSDT", i, f"2717.{i}", "1", t0 + i * 1000) for i in (1, 2, 3))
        shutdown = json.dumps({"stream": "!serverShutdown", "data": {"e": "serverShutdown", "E": 1}})
        connect = FakeConnect(OSError("network is unreachable"),        # attempt 1 fails
                              FakeSocket([e1, e2]),                     # works, then drops
                              FakeSocket([shutdown]),                   # server announces shutdown
                              FakeSocket([e2, e3]))                     # e2 re-delivered
        code, out, _ = self.run_feed(["--symbols", "ETHUSDT", "--max-events", "4"], connect)
        self.assertEqual(code, live_feed.EXIT_OK, out)
        self.assertEqual(self.sleeps, [1, 1, 2])          # bounded backoff; reset after a good connection
        self.assertEqual(len(connect.urls), 4)
        self.assertIn("Reconnecting in 1 s (attempt 1/5)", out)
        self.assertIn("Binance sent serverShutdown", out)
        self.assertEqual([t[2] for t in self.ticks()], ["aggTrade:1", "aggTrade:2", "aggTrade:3"])
        self.assertIn("Reconnects: 3", out)

    def test_16b_gives_up_after_bounded_attempts(self):
        connect = FakeConnect(*[OSError("no route to host")] * 6)
        code, out, _ = self.run_feed(["--symbols", "ETHUSDT"], connect)
        self.assertEqual(code, live_feed.EXIT_NETWORK)
        self.assertEqual(self.sleeps, [1, 2, 4, 8, 16])
        self.assertIn("gave up after 5 reconnect attempts", out)
        self.assertIn("python -m app.replay", out)

    def test_16c_real_websocket_client_against_local_server(self):
        t0 = now_ms(-10)
        requested = []

        def handler(ws):
            requested.append(ws.request.path)
            for i in range(1, 4):
                ws.send(agg("ETHUSDT", i, f"2717.0{i}", "0.5", t0 + i))
            time.sleep(0.5)

        with serve(handler, "127.0.0.1", 0) as server:
            threading.Thread(target=server.serve_forever, daemon=True).start()
            port = server.socket.getsockname()[1]
            code, out, _ = self.run_feed(["--symbols", "ETHUSDT", "--max-events", "3",
                                          "--base-url", f"ws://127.0.0.1:{port}"],
                                         live_feed.ws_connect)
            server.shutdown()
        self.assertEqual(code, live_feed.EXIT_OK, out)
        self.assertEqual(requested, ["/stream?streams=ethusdt@aggTrade"])
        self.assertEqual(len(self.ticks()), 3)

    def test_17_ctrl_c_stops_cleanly_and_keeps_committed_ticks(self):
        t0 = now_ms(-10)
        code, out, _ = self.run_feed(["--symbols", "ETHUSDT"],
                                     FakeConnect(FakeSocket([agg("ETHUSDT", 1, "2717", "1", t0),
                                                             KeyboardInterrupt()])))
        self.assertEqual(code, live_feed.EXIT_OK)
        self.assertIn("Stopped: Ctrl+C", out)
        self.assertEqual(len(self.ticks()), 1)

    def test_18_database_error_stops_feed_and_rolls_back_that_event(self):
        t0 = now_ms(-10)
        code, out, err = self.run_feed(
            ["--symbols", "ETHUSDT"],
            FakeConnect(FakeSocket([agg("ETHUSDT", 1, "2717", "1", t0),
                                    agg("ETHUSDT", 2, "99999999999", "1", t0 + 1),   # > NUMERIC(18,8)
                                    agg("ETHUSDT", 3, "2718", "1", t0 + 2)])))
        self.assertEqual(code, live_feed.EXIT_DB_ERROR)
        self.assertIn("[22003]", err)
        self.assertEqual([t[2] for t in self.ticks()], ["aggTrade:1"])

    def test_19_malformed_message_skipped_not_stored(self):
        t0 = now_ms(-10)
        code, out, _ = self.run_feed(
            ["--symbols", "ETHUSDT", "--max-events", "1"],
            FakeConnect(FakeSocket(["{broken", agg("ETHUSDT", 1, "abc", "1", t0),
                                    agg("ETHUSDT", 2, "2717", "1", t0)])))
        self.assertEqual(code, live_feed.EXIT_OK)
        self.assertEqual([t[2] for t in self.ticks()], ["aggTrade:2"])
        self.assertIn("Skipped:    2", out)


if __name__ == "__main__":
    unittest.main()
