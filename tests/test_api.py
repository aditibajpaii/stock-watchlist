"""Phase 7 API tests - FastAPI TestClient against REAL PostgreSQL.

Every test gets a fresh throwaway database cloned from a template built
with the production scripts sql/00, 01, 03, 06. Nothing is mocked; the
dev database stock_watchlist is never touched.

Seed ids used below (deterministic, see sql/01_seed.sql):
  users 1 arjun, 2 priya, 3 kavya
  instruments 1 NSE RELIANCE, 2 TCS, 3 INFY, 4 HDFCBANK, 5 M&M,
              6 BINANCE BTCUSDT, 7 ETHUSDT
  watchlists 1 arjun/Crypto, 2 arjun/Long Term, 3 priya/Auto, 4 priya/Tech, 5 kavya/Main
  rules 1 arjun RELIANCE ABOVE 3000 (cd 300), 2 arjun RELIANCE BELOW 2800,
        3 arjun BTCUSDT ABOVE 100000, 4 priya TCS BELOW 3500 (cd 0),
        5 priya INFY ABOVE 1600 (inactive), 6 kavya ETHUSDT BELOW 3000

Run (project root, venv active):
    python -m unittest tests.test_api -v
"""

import os
import subprocess
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg
from fastapi.testclient import TestClient

from app.main import app

ROOT = Path(__file__).resolve().parent.parent
PG_BIN = Path(os.environ.get("PG_BIN", "/opt/homebrew/opt/postgresql@18/bin"))
TEMPLATE_DB = "stock_watchlist_api_template"
TEST_DB = "stock_watchlist_api_test"
BASE = datetime(2026, 1, 5, 3, 45, tzinfo=timezone.utc)     # 09:15 IST


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


class ApiTestCase(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.old_db = os.environ.get("DB_NAME")
        os.environ["DB_NAME"] = TEST_DB
        cls.client = TestClient(app)

    @classmethod
    def tearDownClass(cls):
        if cls.old_db is None:
            os.environ.pop("DB_NAME", None)
        else:
            os.environ["DB_NAME"] = cls.old_db

    def setUp(self):
        admin(f"DROP DATABASE IF EXISTS {TEST_DB}")
        admin(f"CREATE DATABASE {TEST_DB} TEMPLATE {TEMPLATE_DB}")

    # ---- helpers -----------------------------------------------------
    def ingest(self, symbol, seconds, price, eid, exchange="NSE", volume=None):
        body = {"exchange": exchange, "symbol": symbol,
                "observed_at": (BASE + timedelta(seconds=seconds)).isoformat(),
                "price": str(price), "source_event_id": eid}
        if volume is not None:
            body["volume"] = str(volume)
        return self.client.post("/ticks/ingest", json=body)

    def db(self, sql, params=()):
        with psycopg.connect(dbname=TEST_DB, autocommit=True) as conn:
            cur = conn.execute(sql, params)
            return cur.fetchall() if cur.description else None

    def assert_clean_error(self, response, status):
        self.assertEqual(response.status_code, status, response.text)
        text = response.text.lower()
        for leak in ("traceback", "psycopg", "password", "host=", "dbname", "select ", "insert "):
            self.assertNotIn(leak, text)
        self.assertIn("detail", response.json())


# =====================================================================
class HealthAndReadTests(ApiTestCase):

    def test_01_health(self):
        r = self.client.get("/health")
        self.assertEqual((r.status_code, r.json()), (200, {"status": "ok", "database": "connected"}))

    def test_01b_health_and_endpoints_report_unreachable_database(self):
        os.environ["DB_NAME"] = "database_that_does_not_exist"
        try:
            r = self.client.get("/health")
            self.assertEqual((r.status_code, r.json()), (503, {"status": "error", "database": "unavailable"}))
            self.assert_clean_error(self.client.get("/users"), 503)
        finally:
            os.environ["DB_NAME"] = TEST_DB

    def test_02_list_users(self):
        r = self.client.get("/users")
        self.assertEqual(r.status_code, 200)
        self.assertEqual([u["username"] for u in r.json()], ["arjun", "priya", "kavya"])
        self.assertEqual(set(r.json()[0]), {"user_id", "username", "email", "created_at"})

    def test_03_missing_user_404(self):
        self.assertEqual(self.client.get("/users/1").json()["username"], "arjun")
        self.assert_clean_error(self.client.get("/users/999"), 404)
        self.assertEqual(self.client.get("/users/0").status_code, 422)      # ids are positive

    def test_04_instruments(self):
        r = self.client.get("/instruments")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(len(r.json()), 7)
        self.assertEqual(set(r.json()[0]), {"instrument_id", "exchange", "symbol", "name",
                                            "quote_currency", "is_active"})
        self.assertEqual(self.client.get("/instruments/6").json()["symbol"], "BTCUSDT")
        self.assert_clean_error(self.client.get("/instruments/999"), 404)

    def test_05_instrument_filters(self):
        self.assertEqual([i["symbol"] for i in self.client.get("/instruments?exchange=BINANCE").json()],
                         ["BTCUSDT", "ETHUSDT"])
        self.db("UPDATE instruments SET is_active = false WHERE symbol = 'HDFCBANK'")
        active = self.client.get("/instruments?active_only=true").json()
        self.assertEqual(len(active), 6)
        self.assertNotIn("HDFCBANK", [i["symbol"] for i in active])
        both = self.client.get("/instruments?exchange=NSE&active_only=true").json()
        self.assertEqual(len(both), 4)

    def test_06_latest_price(self):
        self.assertEqual(self.client.get("/instruments/999/latest").json()["detail"],
                         "Instrument not found.")
        r = self.client.get("/instruments/1/latest")                        # no ticks yet
        self.assertEqual((r.status_code, r.json()["detail"]), (404, "Instrument has no price ticks yet."))
        self.ingest("RELIANCE", 0, "2990", "a")
        self.ingest("RELIANCE", 10, "2995", "b")
        self.ingest("RELIANCE", 10, "2999.5", "c")        # same observed_at, later tick_id
        self.ingest("RELIANCE", 5, "2700", "late")        # older market time
        r = self.client.get("/instruments/1/latest")
        self.assertEqual(r.status_code, 200)
        self.assertEqual((r.json()["price"], r.json()["source_event_id"]), ("2999.50000000", "c"))
        self.assertEqual(r.json()["source"], "MANUAL")

    def test_07_history_is_chronological(self):
        for k, price in enumerate(["2990", "2991", "2992", "2993", "2994"]):
            self.ingest("RELIANCE", k * 10, price, f"h{k}")
        self.ingest("RELIANCE", 15, "2500", "hlate")      # late tick, lands in the middle by time
        ticks = self.client.get("/instruments/1/history").json()
        times = [t["observed_at"] for t in ticks]
        self.assertEqual(times, sorted(times))
        self.assertEqual([t["source_event_id"] for t in ticks], ["h0", "h1", "hlate", "h2", "h3", "h4"])

    def test_08_history_limit_and_window(self):
        for k in range(8):
            self.ingest("TCS", k, 3600 + k, f"t{k}")
        three = self.client.get("/instruments/2/history?limit=3").json()
        self.assertEqual([t["source_event_id"] for t in three], ["t5", "t6", "t7"])   # most recent 3
        for bad in ("0", "1001", "abc"):
            self.assertEqual(self.client.get(f"/instruments/2/history?limit={bad}").status_code, 422)
        window = self.client.get("/instruments/2/history", params={
            "from_time": (BASE + timedelta(seconds=2)).isoformat(),
            "to_time": (BASE + timedelta(seconds=5)).isoformat()}).json()
        self.assertEqual([t["source_event_id"] for t in window], ["t2", "t3", "t4"])
        naive = self.client.get("/instruments/2/history?from_time=2026-01-05T09:15:00")
        self.assertEqual(naive.status_code, 422)                              # timezone required
        reversed_window = self.client.get("/instruments/2/history", params={
            "from_time": (BASE + timedelta(seconds=5)).isoformat(),
            "to_time": (BASE + timedelta(seconds=2)).isoformat()})
        self.assertEqual(reversed_window.status_code, 422)


# =====================================================================
class WatchlistTests(ApiTestCase):

    def test_09_create_watchlist(self):
        r = self.client.post("/users/2/watchlists", json={"name": "  My Stocks  "})
        self.assertEqual(r.status_code, 201, r.text)
        self.assertEqual((r.json()["name"], r.json()["user_id"], r.json()["items"]), ("My Stocks", 2, []))
        names = [w["name"] for w in self.client.get("/users/2/watchlists").json()]
        self.assertEqual(names, ["Auto", "My Stocks", "Tech"])

    def test_10_duplicate_watchlist_conflict(self):
        r = self.client.post("/users/1/watchlists", json={"name": "Crypto"})
        self.assert_clean_error(r, 409)
        self.assertEqual(r.json()["constraint"], "uq_watchlists_user_name")
        self.assertEqual(self.client.post("/users/3/watchlists", json={"name": "Crypto"}).status_code, 201)
        self.assert_clean_error(self.client.post("/users/999/watchlists", json={"name": "X"}), 404)

    def test_11_add_item_and_list_with_latest_price(self):
        self.ingest("INFY", 0, "1500.25", "i0")
        r = self.client.post("/watchlists/2/items", json={"instrument_id": 3})
        self.assertEqual(r.status_code, 201, r.text)
        self.assertEqual((r.json()["symbol"], r.json()["latest_price"]), ("INFY", "1500.25000000"))
        long_term = next(w for w in self.client.get("/users/1/watchlists").json() if w["name"] == "Long Term")
        items = {i["symbol"]: i for i in long_term["items"]}
        self.assertEqual(set(items), {"RELIANCE", "TCS", "HDFCBANK", "INFY"})
        self.assertIsNone(items["TCS"]["latest_price"])                      # no ticks yet
        self.assertEqual(items["INFY"]["latest_price"], "1500.25000000")

    def test_12_duplicate_item_and_missing_references(self):
        dup = self.client.post("/watchlists/2/items", json={"instrument_id": 1})
        self.assert_clean_error(dup, 409)
        self.assertEqual(dup.json()["constraint"], "pk_watchlist_items")
        no_instr = self.client.post("/watchlists/2/items", json={"instrument_id": 999})
        self.assertEqual((no_instr.status_code, no_instr.json()["detail"]), (404, "Instrument not found."))
        no_list = self.client.post("/watchlists/999/items", json={"instrument_id": 1})
        self.assertEqual((no_list.status_code, no_list.json()["detail"]), (404, "Watchlist not found."))

    def test_13_remove_item(self):
        self.assertEqual(self.client.delete("/watchlists/2/items/1").status_code, 204)
        self.assert_clean_error(self.client.delete("/watchlists/2/items/1"), 404)
        self.assertEqual(self.client.get("/instruments/1").status_code, 200)   # instrument kept

    def test_14_delete_watchlist_cascades_items_only(self):
        self.ingest("RELIANCE", 0, "2990", "w0")
        self.assertEqual(self.client.delete("/watchlists/2").status_code, 204)
        self.assertEqual(self.db("SELECT count(*) FROM watchlist_items WHERE watchlist_id = 2")[0][0], 0)
        self.assertEqual(self.db("SELECT count(*) FROM instruments")[0][0], 7)
        self.assertEqual(self.db("SELECT count(*) FROM price_ticks")[0][0], 1)
        self.assert_clean_error(self.client.delete("/watchlists/2"), 404)


# =====================================================================
class AlertRuleTests(ApiTestCase):

    def test_15_create_rule(self):
        r = self.client.post("/users/3/alert-rules", json={
            "instrument_id": 1, "direction": "ABOVE", "threshold": "3100.5", "cooldown_seconds": 60})
        self.assertEqual(r.status_code, 201, r.text)
        rule = r.json()
        self.assertEqual((rule["symbol"], rule["direction"], rule["threshold"], rule["cooldown_seconds"],
                          rule["is_active"]), ("RELIANCE", "ABOVE", "3100.50000000", 60, True))
        ids = [x["rule_id"] for x in self.client.get("/users/3/alert-rules").json()]
        self.assertEqual(ids, [6, rule["rule_id"]])

    def test_16_duplicate_rule_conflict(self):
        r = self.client.post("/users/1/alert-rules", json={
            "instrument_id": 1, "direction": "ABOVE", "threshold": "3000.00"})     # = rule 1
        self.assert_clean_error(r, 409)
        self.assertEqual(r.json()["constraint"], "uq_alert_rules_definition")

    def test_17_disable_rule(self):
        r = self.client.patch("/alert-rules/1", json={"is_active": False})
        self.assertEqual((r.status_code, r.json()["is_active"], r.json()["cooldown_seconds"]), (200, False, 300))
        self.ingest("RELIANCE", 0, "2990", "d0")
        self.ingest("RELIANCE", 1, "3010", "d1")                       # crossing, rule disabled
        self.assertEqual(self.db("SELECT count(*) FROM alert_events WHERE rule_id = 1")[0][0], 0)

    def test_18_change_cooldown(self):
        r = self.client.patch("/alert-rules/1", json={"cooldown_seconds": 120})
        self.assertEqual((r.json()["cooldown_seconds"], r.json()["is_active"]), (120, True))
        r = self.client.patch("/alert-rules/1", json={"cooldown_seconds": 0, "is_active": False})
        self.assertEqual((r.json()["cooldown_seconds"], r.json()["is_active"]), (0, False))
        self.assert_clean_error(self.client.patch("/alert-rules/999", json={"is_active": True}), 404)

    def test_19_rule_definition_cannot_be_changed(self):
        before = self.db("SELECT user_id, instrument_id, direction, threshold FROM alert_rules WHERE rule_id = 1")
        for field, value in (("threshold", "3500"), ("direction", "BELOW"),
                             ("instrument_id", 2), ("user_id", 2)):
            with self.subTest(field):
                r = self.client.patch("/alert-rules/1", json={field: value})
                self.assertEqual(r.status_code, 422)
                r = self.client.patch("/alert-rules/1", json={field: value, "is_active": False})
                self.assertEqual(r.status_code, 422)                 # even mixed with a legal field
        self.assertEqual(self.client.patch("/alert-rules/1", json={}).status_code, 422)
        after = self.db("SELECT user_id, instrument_id, direction, threshold FROM alert_rules WHERE rule_id = 1")
        self.assertEqual(before, after)
        self.assertTrue(self.db("SELECT is_active FROM alert_rules WHERE rule_id = 1")[0][0])
        self.assertNotIn("put", {m.lower() for r in app.routes if r.path == "/alert-rules/{rule_id}"
                                 for m in getattr(r, "methods", ())})

    def test_28_delete_rule_cascades_its_alert_history(self):
        self.ingest("RELIANCE", 0, "2990", "x0")
        self.ingest("RELIANCE", 1, "3010", "x1")                       # rule 1 fires
        self.assertEqual(len(self.client.get("/users/1/alerts").json()), 1)
        self.assertEqual(self.client.delete("/alert-rules/1").status_code, 204)
        self.assertEqual(self.db("SELECT count(*) FROM alert_events WHERE rule_id = 1")[0][0], 0)
        self.assertEqual(self.client.get("/users/1/alerts").json(), [])
        self.assertEqual(self.db("SELECT count(*) FROM price_ticks")[0][0], 2)   # ticks kept
        self.assert_clean_error(self.client.delete("/alert-rules/1"), 404)


# =====================================================================
class IngestAndAlertTests(ApiTestCase):

    def test_20_alert_history_is_joined(self):
        self.ingest("TCS", 0, "3550", "t0")
        self.ingest("TCS", 5, "3490.75", "t1")                        # priya rule 4 BELOW 3500
        alerts = self.client.get("/users/2/alerts").json()
        self.assertEqual(len(alerts), 1)
        a = alerts[0]
        self.assertEqual((a["rule_id"], a["instrument_id"], a["exchange"], a["symbol"], a["direction"],
                          a["threshold"], a["price"]),
                         (4, 2, "NSE", "TCS", "BELOW", "3500.00000000", "3490.75000000"))
        self.assertEqual(datetime.fromisoformat(a["observed_at"]), BASE + timedelta(seconds=5))
        self.assertIn("fired_at", a)
        stored = self.db("SELECT * FROM alert_events")[0]
        self.assertEqual(len(stored), 4)          # event_id, rule_id, tick_id, fired_at - nothing copied

    def test_21_manual_ingest_inserts_via_ingest_tick(self):
        r = self.ingest("RELIANCE", 0, "2990", "m1", volume="100")
        self.assertEqual((r.status_code, r.json()["status"]), (201, "INSERTED"))
        row = self.db("SELECT tick_id, source, source_event_id, price, volume FROM price_ticks")
        self.assertEqual(len(row), 1)
        self.assertEqual(row[0][0], r.json()["tick_id"])
        self.assertEqual(row[0][1:3], ("MANUAL", "m1"))

    def test_22_manual_ingest_duplicate(self):
        first = self.ingest("RELIANCE", 0, "2990", "same")
        second = self.ingest("RELIANCE", 30, "3100", "same")
        self.assertEqual((second.status_code, second.json()), (200, {"status": "DUPLICATE", "tick_id": None}))
        self.assertEqual(first.json()["status"], "INSERTED")
        self.assertEqual(self.db("SELECT count(*) FROM price_ticks")[0][0], 1)

    def test_23_crossing_via_api_creates_visible_alert(self):
        self.ingest("RELIANCE", 0, "2990", "c0")
        self.ingest("RELIANCE", 1, "3010", "c1")                       # rule 1 ABOVE 3000
        self.ingest("RELIANCE", 2, "3020", "c2")                       # stays above: no new alert
        self.ingest("BTCUSDT", 0, "99000", "b0", exchange="BINANCE")
        self.ingest("BTCUSDT", 1, "100500", "b1", exchange="BINANCE")  # rule 3 ABOVE 100000
        alerts = self.client.get("/users/1/alerts").json()
        self.assertEqual([(a["symbol"], a["price"]) for a in alerts],
                         [("BTCUSDT", "100500.00000000"), ("RELIANCE", "3010.00000000")])  # newest first
        only_reliance = self.client.get("/users/1/alerts?instrument_id=1").json()
        self.assertEqual([a["rule_id"] for a in only_reliance], [1])
        self.assertEqual(self.client.get("/users/1/alerts?limit=1").json()[0]["symbol"], "BTCUSDT")
        self.assertEqual(self.client.get("/users/2/alerts").json(), [])  # other users see nothing
        self.assertEqual(self.client.get("/users/1/alerts?limit=501").status_code, 422)
        self.assert_clean_error(self.client.get("/users/999/alerts"), 404)

    def test_24_unknown_instrument(self):
        r = self.ingest("NOSUCH", 0, "100", "u0")
        self.assert_clean_error(r, 404)
        self.assertEqual(r.json()["sqlstate"], "SW001")

    def test_25_inactive_instrument(self):
        self.db("UPDATE instruments SET is_active = false WHERE symbol = 'HDFCBANK'")
        r = self.ingest("HDFCBANK", 0, "1650", "in0")
        self.assert_clean_error(r, 409)
        self.assertEqual(r.json()["sqlstate"], "SW002")
        self.assertEqual(self.db("SELECT count(*) FROM price_ticks")[0][0], 0)

    def test_26_invalid_request_values_rejected(self):
        ok = {"exchange": "NSE", "symbol": "TCS", "observed_at": BASE.isoformat(),
              "price": "3600", "source_event_id": "v"}
        bad_ticks = {"negative price": {"price": "-5"}, "zero price": {"price": "0"},
                     "NaN price": {"price": "NaN"}, "negative volume": {"volume": "-1"},
                     "naive timestamp": {"observed_at": "2026-01-05T09:15:00"},
                     "blank event id": {"source_event_id": "   "}, "unknown field": {"source": "BINANCE"}}
        for name, change in bad_ticks.items():
            with self.subTest(name):
                self.assertEqual(self.client.post("/ticks/ingest", json={**ok, **change}).status_code, 422)
        missing = dict(ok); del missing["price"]
        self.assertEqual(self.client.post("/ticks/ingest", json=missing).status_code, 422)
        rule = {"instrument_id": 1, "direction": "ABOVE", "threshold": "3100"}
        for name, change in {"direction": {"direction": "SIDEWAYS"}, "threshold": {"threshold": "0"},
                             "cooldown": {"cooldown_seconds": -1}, "instrument": {"instrument_id": 0}}.items():
            with self.subTest(name):
                self.assertEqual(self.client.post("/users/1/alert-rules", json={**rule, **change}).status_code, 422)
        self.assertEqual(self.client.post("/users/1/watchlists", json={"name": "   "}).status_code, 422)
        self.assertEqual(self.client.post("/users/1/watchlists", json={"name": "x" * 51}).status_code, 422)
        self.assertEqual(self.db("SELECT count(*) FROM price_ticks")[0][0], 0)

    def test_27_database_errors_are_readable_not_tracebacks(self):
        # values that pass API validation but break database limits
        huge = self.client.post("/users/1/alert-rules", json={
            "instrument_id": 1, "direction": "ABOVE", "threshold": "999999999999"})   # > NUMERIC(18,8)
        self.assert_clean_error(huge, 422)
        self.assertEqual(huge.json()["sqlstate"], "22003")
        big_cooldown = self.client.patch("/alert-rules/1", json={"cooldown_seconds": 3_000_000_000})
        self.assert_clean_error(big_cooldown, 422)                             # > INTEGER
        self.assertEqual(self.db("SELECT cooldown_seconds FROM alert_rules WHERE rule_id = 1")[0][0], 300)

    def test_29_sql_injection_strings_are_data(self):
        r = self.client.get("/instruments", params={"exchange": "NSE' OR '1'='1"})
        self.assertEqual((r.status_code, r.json()), (200, []))
        evil = "x'); DROP TABLE users; --"
        r = self.client.post("/users/1/watchlists", json={"name": evil})
        self.assertEqual(r.status_code, 201)
        self.assertEqual(self.db("SELECT name FROM watchlists WHERE name = %s", (evil,))[0][0], evil)
        self.assertEqual(self.db("SELECT count(*) FROM users")[0][0], 3)          # table intact

    def test_30_decimals_and_timestamps_round_trip_exactly(self):
        self.ingest("BTCUSDT", 0, "100123.12345678", "p", exchange="BINANCE", volume="0.00000001")
        t = self.client.get("/instruments/6/latest").json()
        self.assertEqual((t["price"], t["volume"]), ("100123.12345678", "0.00000001"))
        self.assertEqual(datetime.fromisoformat(t["observed_at"]), BASE)
        self.assertIsNotNone(datetime.fromisoformat(t["observed_at"]).tzinfo)

    def test_31_openapi_docs_available(self):
        self.assertEqual(self.client.get("/docs").status_code, 200)
        spec = self.client.get("/openapi.json").json()
        self.assertIn("/ticks/ingest", spec["paths"])
        self.assertEqual(len(spec["paths"]), 15)            # 18 endpoints on 15 paths


if __name__ == "__main__":
    unittest.main()
