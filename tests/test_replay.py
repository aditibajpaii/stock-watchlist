"""Phase 5 tests for app/replay.py, against a REAL PostgreSQL server.

Each test gets a fresh throwaway database cloned from a template that is
built once from sql/00_schema.sql, 01_seed.sql and 03_functions_triggers.sql.
The dev database (stock_watchlist) is never touched.

Run from the project root with the virtual environment active:

    python -m unittest tests.test_replay -v
"""

import contextlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import timedelta
from decimal import Decimal
from pathlib import Path

import psycopg

from app import replay

ROOT = Path(__file__).resolve().parent.parent
DEMO_CSV = ROOT / "data" / "replay_prices.csv"
PG_BIN = Path(os.environ.get("PG_BIN", "/opt/homebrew/opt/postgresql@18/bin"))
TEMPLATE_DB = "stock_watchlist_p5_template"
TEST_DB = "stock_watchlist_p5_test"
HEADER = "offset_seconds,exchange,symbol,price,volume\n"

# (rule_id, row number) pairs the demo CSV must produce on a fresh seed DB
EXPECTED_DEMO_EVENTS = {(1, 6), (4, 9), (3, 10), (6, 18), (4, 20), (3, 22), (1, 27), (2, 29)}


def admin(sql: str) -> None:
    """Run CREATE/DROP DATABASE on the maintenance database."""
    with psycopg.connect(dbname="postgres", autocommit=True) as conn:
        conn.execute(sql)


def psql_file(db: str, *files: str) -> subprocess.CompletedProcess:
    args = [str(PG_BIN / "psql"), "-X", "-q", "-d", db, "-v", "ON_ERROR_STOP=1"]
    for f in files:
        args += ["-f", str(ROOT / "sql" / f)]
    return subprocess.run(args, capture_output=True, text=True)


def setUpModule():
    admin(f"DROP DATABASE IF EXISTS {TEST_DB}")
    admin(f"DROP DATABASE IF EXISTS {TEMPLATE_DB}")
    admin(f"CREATE DATABASE {TEMPLATE_DB}")
    result = psql_file(TEMPLATE_DB, "00_schema.sql", "01_seed.sql", "03_functions_triggers.sql")
    if result.returncode != 0:
        raise RuntimeError("building template DB failed:\n" + result.stderr)


def tearDownModule():
    admin(f"DROP DATABASE IF EXISTS {TEST_DB}")
    admin(f"DROP DATABASE IF EXISTS {TEMPLATE_DB}")


class ReplayTestCase(unittest.TestCase):
    """Fresh database per test; helpers to run the replay and query results."""

    def setUp(self):
        admin(f"DROP DATABASE IF EXISTS {TEST_DB}")
        admin(f"CREATE DATABASE {TEST_DB} TEMPLATE {TEMPLATE_DB}")
        self._env = mock_env(DB_NAME=TEST_DB)
        self._env.__enter__()
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        self._env.__exit__(None, None, None)
        shutil.rmtree(self.tmp)

    # ---- helpers -----------------------------------------------------
    def write_csv(self, body: str) -> str:
        path = self.tmp / f"replay_{len(list(self.tmp.iterdir()))}.csv"
        path.write_text(HEADER + body)
        return str(path)

    def run_replay(self, *args):
        """Run replay.main in-process; return (exit_code, stdout, stderr)."""
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = replay.main([str(a) for a in args])
        return code, out.getvalue(), err.getvalue()

    def query(self, sql: str, params=()):
        with psycopg.connect(dbname=TEST_DB) as conn:
            return conn.execute(sql, params).fetchall()

    def scalar(self, sql: str, params=()):
        return self.query(sql, params)[0][0]

    def replay_ticks(self, run_id: str):
        """(row_no, symbol, observed_at, price, volume) for one run, by row."""
        rows = self.query(
            """SELECT t.source_event_id, i.symbol, t.observed_at, t.price, t.volume
               FROM price_ticks t JOIN instruments i USING (instrument_id)
               WHERE t.source = 'REPLAY' AND t.source_event_id = ANY(%s)""",
            ([replay.source_event_id(run_id, n) for n in range(1, 1000)],))
        return sorted((int(r[0].split(":")[1]), *r[1:]) for r in rows)

    def events_by_row(self, run_id: str):
        """{(rule_id, row_no)} of alert events on this run's ticks."""
        ids = {replay.source_event_id(run_id, n): n for n in range(1, 1000)}
        rows = self.query(
            """SELECT e.rule_id, t.source_event_id
               FROM alert_events e JOIN price_ticks t USING (tick_id)
               WHERE t.source_event_id = ANY(%s)""", (list(ids),))
        return {(rule_id, ids[sid]) for rule_id, sid in rows}


@contextlib.contextmanager
def mock_env(**values):
    old = {k: os.environ.get(k) for k in values}
    os.environ.update(values)
    try:
        yield
    finally:
        for k, v in old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


# =====================================================================
# 1-4: CSV parsing and validation (no ingestion happens on bad input)
# =====================================================================
class CsvValidationTests(ReplayTestCase):

    def test_01_demo_csv_parses(self):
        rows = replay.load_csv(str(DEMO_CSV))
        self.assertEqual(len(rows), 30)
        first = rows[0]
        self.assertEqual((first.row_no, first.offset_seconds, first.exchange, first.symbol),
                         (1, 0, "NSE", "RELIANCE"))
        self.assertEqual(first.price, Decimal("2985.50"))
        self.assertIsInstance(first.price, Decimal)          # never float
        self.assertEqual(first.volume, Decimal("1200"))
        self.assertEqual([r.row_no for r in rows], list(range(1, 31)))

    def test_02_blank_volume_becomes_sql_null(self):
        rows = replay.load_csv(str(DEMO_CSV))
        self.assertIsNone(rows[2].volume)                    # row 3 has blank volume
        code, _, _ = self.run_replay(DEMO_CSV, "--run-id", "vol")
        self.assertEqual(code, 0)
        by_row = {r[0]: r for r in self.replay_ticks("vol")}
        self.assertIsNone(by_row[3][4])                      # stored as NULL
        self.assertEqual(by_row[1][4], Decimal("1200"))
        self.assertEqual(sum(1 for r in by_row.values() if r[4] is None), 8)

    def test_03_invalid_price_rejected_before_ingestion(self):
        for bad in ("abc", "-5", "0", "NaN", ""):
            with self.subTest(price=bad):
                path = self.write_csv(f"0,NSE,RELIANCE,2990,1\n5,NSE,RELIANCE,{bad},1\n")
                code, _, err = self.run_replay(path)
                self.assertEqual(code, replay.EXIT_BAD_INPUT)
                self.assertIn("row 2", err)
                self.assertEqual(self.scalar("SELECT count(*) FROM price_ticks"), 0)

    def test_04_missing_required_field_rejected(self):
        cases = {
            "missing symbol": "0,NSE,,2990,1\n",
            "missing exchange": "0,,RELIANCE,2990,1\n",
            "missing offset": ",NSE,RELIANCE,2990,1\n",
            "bad offset": "x,NSE,RELIANCE,2990,1\n",
            "negative volume": "0,NSE,RELIANCE,2990,-1\n",
            "offset goes backwards": "10,NSE,RELIANCE,2990,1\n5,NSE,RELIANCE,2991,1\n",
            "too many values": "0,NSE,RELIANCE,2990,1,extra\n",
        }
        for name, body in cases.items():
            with self.subTest(name):
                code, _, err = self.run_replay(self.write_csv(body))
                self.assertEqual(code, replay.EXIT_BAD_INPUT, err)
                self.assertEqual(self.scalar("SELECT count(*) FROM price_ticks"), 0)
        wrong_header = self.tmp / "wrong_header.csv"
        wrong_header.write_text("offset,exchange,symbol,price,volume\n0,NSE,TCS,1,1\n")
        code, _, err = self.run_replay(wrong_header)
        self.assertEqual(code, replay.EXIT_BAD_INPUT)
        self.assertIn("header must be exactly", err)


# =====================================================================
# 5-7: run identity (new run / retry / new run again)
# =====================================================================
class RunIdentityTests(ReplayTestCase):

    def test_05_new_run_inserts_all_rows(self):
        code, out, _ = self.run_replay(DEMO_CSV)
        self.assertEqual(code, 0)
        self.assertIn("Inserted:   30", out)
        run_id = next(l.split()[-1] for l in out.splitlines() if l.startswith("Run ID:"))
        ticks = self.replay_ticks(run_id)
        self.assertEqual([t[0] for t in ticks], list(range(1, 31)))
        # source_event_id format <run_id>:<6-digit row>
        self.assertEqual(self.scalar(
            "SELECT count(*) FROM price_ticks WHERE source_event_id = %s",
            (f"{run_id}:000030",)), 1)

    def test_05b_observed_at_is_run_start_plus_offset(self):
        code, _, _ = self.run_replay(DEMO_CSV, "--run-id", "ts")
        self.assertEqual(code, 0)
        rows = replay.load_csv(str(DEMO_CSV))
        ticks = self.replay_ticks("ts")
        run_start = ticks[0][2] - timedelta(seconds=rows[0].offset_seconds)
        for row, tick in zip(rows, ticks):
            self.assertEqual(tick[2], run_start + timedelta(seconds=row.offset_seconds))
        self.assertEqual(run_start.microsecond, 0)

    def test_06_same_run_id_again_is_all_duplicate(self):
        self.assertEqual(self.run_replay(DEMO_CSV, "--run-id", "X")[0], 0)
        before = self.replay_ticks("X")
        code, out, _ = self.run_replay(DEMO_CSV, "--run-id", "X")
        self.assertEqual(code, 0)
        self.assertIn("Retrying run X", out)
        self.assertEqual(out.count("-> DUPLICATE"), 30)
        self.assertIn("Inserted:   0", out)
        self.assertIn("Duplicates: 30", out)
        self.assertEqual(self.replay_ticks("X"), before)     # nothing changed
        self.assertEqual(self.scalar("SELECT count(*) FROM price_ticks"), 30)
        self.assertEqual(self.scalar("SELECT count(*) FROM alert_events"), 8)

    def test_06b_interrupted_run_resumes_on_its_original_timeline(self):
        first_ten = self.write_csv("".join(DEMO_CSV.read_text().splitlines(True)[1:11]))
        self.assertEqual(self.run_replay(first_ten, "--run-id", "R")[0], 0)
        code, out, _ = self.run_replay(DEMO_CSV, "--run-id", "R")
        self.assertEqual(code, 0)
        self.assertIn("Duplicates: 10", out)
        self.assertIn("Inserted:   20", out)
        rows = replay.load_csv(str(DEMO_CSV))
        ticks = self.replay_ticks("R")
        run_start = ticks[0][2]
        for row, tick in zip(rows, ticks):                  # one continuous timeline
            self.assertEqual(tick[2], run_start + timedelta(seconds=row.offset_seconds))
        self.assertEqual(self.events_by_row("R"), EXPECTED_DEMO_EVENTS)

    def test_07_new_run_id_again_is_a_new_run(self):
        self.assertEqual(self.run_replay(DEMO_CSV, "--run-id", "X")[0], 0)
        # immediately afterwards the X ticks extend ~8 min into the future:
        code, _, err = self.run_replay(DEMO_CSV, "--run-id", "Y")
        self.assertEqual(code, replay.EXIT_DB_ERROR)
        self.assertIn("would be classified as LATE", err)
        self.assertEqual(self.scalar("SELECT count(*) FROM price_ticks"), 30)
        # opt-in: start just after the latest stored tick
        code, out, _ = self.run_replay(DEMO_CSV, "--run-id", "Y", "--start-after-latest")
        self.assertEqual(code, 0)
        self.assertIn("Inserted:   30", out)
        x_last = self.replay_ticks("X")[-1][2]
        y_first = self.replay_ticks("Y")[0][2]
        self.assertEqual(y_first, x_last + timedelta(seconds=1))
        self.assertEqual(self.scalar("SELECT count(*) FROM price_ticks"), 60)
        # continuous history: RELIANCE row 6 of run Y is inside rule 1's
        # cooldown from run X's row 27, so run Y yields 7 events, not 8
        self.assertEqual(self.events_by_row("Y"), EXPECTED_DEMO_EVENTS - {(1, 6)})


# =====================================================================
# 8-10, 15: alert behaviour through replay
# =====================================================================
class ReplayAlertTests(ReplayTestCase):

    def test_08_expected_alert_events_for_known_crossings(self):
        code, out, _ = self.run_replay(DEMO_CSV, "--run-id", "A")
        self.assertEqual(code, 0)
        self.assertIn("Alerts:     8", out)
        self.assertEqual(self.events_by_row("A"), EXPECTED_DEMO_EVENTS)
        self.assertEqual(self.scalar("SELECT count(*) FROM alert_events"), 8)
        self.assertIn("ALERT event=1: arjun RELIANCE ABOVE 3000", out)

    def test_09_staying_beyond_threshold_does_not_repeat(self):
        self.run_replay(DEMO_CSV, "--run-id", "S")
        fired_rows = {row for _, row in self.events_by_row("S")}
        # rows where the price stays above/below, or a crossing is in cooldown
        for row in (8, 11, 12, 14, 16, 23, 28, 30):
            self.assertNotIn(row, fired_rows)
        self.assertEqual(self.scalar(
            "SELECT count(*) FROM alert_events WHERE rule_id = 1"), 2)
        self.assertEqual(self.scalar(
            "SELECT count(*) FROM alert_events WHERE rule_id = 5"), 0)   # inactive rule

    def test_10_multiple_instruments_interleaved(self):
        self.run_replay(DEMO_CSV, "--run-id", "M")
        counts = dict(self.query(
            """SELECT i.symbol, count(*) FROM price_ticks t JOIN instruments i USING (instrument_id)
               GROUP BY i.symbol"""))
        self.assertEqual(counts, {"RELIANCE": 12, "TCS": 6, "BTCUSDT": 8, "ETHUSDT": 2, "INFY": 2})
        # every event pairs a rule and tick of the same instrument
        self.assertEqual(self.scalar(
            """SELECT count(*) FROM alert_events e JOIN alert_rules r USING (rule_id)
               JOIN price_ticks t USING (tick_id) WHERE r.instrument_id <> t.instrument_id"""), 0)
        # tick order per instrument follows the CSV order
        for symbol in counts:
            prices = [r[0] for r in self.query(
                """SELECT t.price FROM price_ticks t JOIN instruments i USING (instrument_id)
                   WHERE i.symbol = %s ORDER BY t.observed_at, t.tick_id""", (symbol,))]
            csv_prices = [r.price for r in replay.load_csv(str(DEMO_CSV)) if r.symbol == symbol]
            self.assertEqual(prices, csv_prices, symbol)

    def test_15_phase2_and_phase4_sql_suites_pass_after_replay(self):
        self.assertEqual(self.run_replay(DEMO_CSV, "--run-id", "P")[0], 0)
        for suite, summary in (("04_alert_tests.sql", "50 |      0 |    50"),
                               ("02_schema_tests.sql", "51 |      0 |    51")):
            with self.subTest(suite):
                result = psql_file(TEST_DB, suite)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(summary, result.stdout)
        # the rolled-back SQL suites left the replay data untouched
        self.assertEqual(self.scalar("SELECT count(*) FROM price_ticks"), 30)
        self.assertEqual(self.scalar("SELECT count(*) FROM alert_events"), 8)


# =====================================================================
# 11-14: dry run and failure handling
# =====================================================================
class DryRunAndErrorTests(ReplayTestCase):

    def test_11_dry_run_changes_nothing_and_needs_no_database(self):
        code, out, _ = self.run_replay(DEMO_CSV, "--dry-run", "--run-id", "D")
        self.assertEqual(code, 0)
        self.assertEqual(out.count("-> would send"), 30)
        self.assertIn("source_event_id=D:000001", out)
        self.assertEqual(self.scalar("SELECT count(*) FROM price_ticks"), 0)
        with mock_env(DB_NAME="database_that_does_not_exist"):
            code, _, _ = self.run_replay(DEMO_CSV, "--dry-run")
        self.assertEqual(code, 0)

    def test_12_unknown_instrument_fails_non_zero(self):
        path = self.write_csv("0,NSE,RELIANCE,2990,1\n5,NSE,NOSUCH,100,1\n10,NSE,RELIANCE,2995,1\n")
        code, out, err = self.run_replay(path, "--run-id", "U")
        self.assertEqual(code, replay.EXIT_DB_ERROR)
        self.assertIn("[SW001]", err)
        self.assertIn("unknown instrument NSE:NOSUCH", err)
        self.assertIn("Replay FAILED", out)
        self.assertEqual([t[0] for t in self.replay_ticks("U")], [1])  # row 1 kept, stop at 2

    def test_12b_cli_exit_code_via_subprocess(self):
        path = self.write_csv("0,NSE,NOSUCH,100,1\n")
        env = dict(os.environ, DB_NAME=TEST_DB)
        result = subprocess.run([sys.executable, "-m", "app.replay", path],
                                cwd=ROOT, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("SW001", result.stderr)

    def test_13_inactive_instrument_fails_non_zero(self):
        self.query_exec("UPDATE instruments SET is_active = false WHERE symbol = 'HDFCBANK'")
        path = self.write_csv("0,NSE,HDFCBANK,1650,1\n")
        code, _, err = self.run_replay(path, "--run-id", "I")
        self.assertEqual(code, replay.EXIT_DB_ERROR)
        self.assertIn("[SW002]", err)
        self.assertEqual(self.scalar("SELECT count(*) FROM price_ticks"), 0)

    def test_14_database_error_rolls_back_only_that_event(self):
        # 12 integer digits pass Python validation but overflow NUMERIC(18,8)
        body = ("0,NSE,RELIANCE,2990,1\n"
                "5,NSE,RELIANCE,999999999999,1\n"
                "10,NSE,RELIANCE,3005,1\n")
        path = self.write_csv(body)
        code, _, err = self.run_replay(path, "--run-id", "E")
        self.assertEqual(code, replay.EXIT_DB_ERROR)
        self.assertIn("[22003]", err)                      # numeric_value_out_of_range
        self.assertEqual([t[0] for t in self.replay_ticks("E")], [1])
        # --continue-on-error: the same connection keeps working after the
        # rolled-back event; row 3 is ingested and still fires the alert
        code, out, _ = self.run_replay(path, "--run-id", "E", "--continue-on-error")
        self.assertEqual(code, replay.EXIT_DB_ERROR)       # still reports failure
        self.assertIn("Errors:     1", out)
        self.assertEqual([t[0] for t in self.replay_ticks("E")], [1, 3])
        self.assertEqual(self.events_by_row("E"), {(1, 3)})

    def query_exec(self, sql: str):
        with psycopg.connect(dbname=TEST_DB) as conn:
            conn.execute(sql)


if __name__ == "__main__":
    unittest.main()
