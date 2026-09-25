"""Phase 6 tests for the performance index ix_price_ticks_instrument_time.

Two groups:
  * LiveIndexDefinitionTests - READ-ONLY checks on the dev database
    stock_watchlist (index present and exactly as designed, schema intact).
  * PlannerTests - a throwaway database (production build 00+01+03+06 plus
    60,000 synthetic ticks) to check planner PROPERTIES: which index a
    query uses, whether a Sort/Seq Scan appears. Never exact plan text:
    PostgreSQL is cost-based and plans may legitimately vary.

Run (project root, venv active):
    python -m unittest tests.test_indexes -v
"""

import os
import subprocess
import unittest
from pathlib import Path

import psycopg

from tests.benchmark_indexes import QUERIES, query_params

ROOT = Path(__file__).resolve().parent.parent
PG_BIN = Path(os.environ.get("PG_BIN", "/opt/homebrew/opt/postgresql@18/bin"))
DEV_DB = os.environ.get("DB_NAME", "stock_watchlist")
TEST_DB = "stock_watchlist_idx_test"
INDEX = "ix_price_ticks_instrument_time"
EXPECTED_DEF = ("CREATE INDEX ix_price_ticks_instrument_time ON public.price_ticks "
                "USING btree (instrument_id, observed_at DESC, tick_id DESC)")
TEST_ROWS = 60_000
TABLES = ("users", "instruments", "watchlists", "watchlist_items",
          "price_ticks", "alert_rules", "alert_events")


def admin(sql):
    with psycopg.connect(dbname="postgres", autocommit=True) as conn:
        conn.execute(sql)


def psql_file(db, *files):
    args = [str(PG_BIN / "psql"), "-X", "-q", "-d", db, "-v", "ON_ERROR_STOP=1"]
    for f in files:
        args += ["-f", str(ROOT / "sql" / f)]
    return subprocess.run(args, capture_output=True, text=True)


def walk(plan):
    yield plan
    for child in plan.get("Plans", []):
        yield from walk(child)


# =====================================================================
# Read-only checks on the real dev database
# =====================================================================
class LiveIndexDefinitionTests(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.conn = psycopg.connect(dbname=DEV_DB, autocommit=True)
        row = cls.conn.execute("""
            SELECT i.indrelid::regclass::text, am.amname, i.indisunique,
                   i.indpred IS NULL, i.indexprs IS NULL, i.indoption::int2[],
                   pg_get_indexdef(i.indexrelid),
                   ARRAY(SELECT a.attname::text
                         FROM unnest(i.indkey::int2[]) WITH ORDINALITY k(attnum, ord)
                         JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
                         ORDER BY k.ord)
            FROM pg_index i
            JOIN pg_class c ON c.oid = i.indexrelid
            JOIN pg_am am ON am.oid = c.relam
            WHERE c.relname = %s""", (INDEX,)).fetchone()
        cls.index = row

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def test_01_index_exists(self):
        self.assertIsNotNone(self.index, f"{INDEX} missing in {DEV_DB}")

    def test_02_on_price_ticks_btree_plain(self):
        table, am, unique, not_partial, no_exprs = self.index[:5]
        self.assertEqual(table, "price_ticks")
        self.assertEqual(am, "btree")
        self.assertFalse(unique)            # performance index, not a constraint
        self.assertTrue(not_partial)        # no WHERE clause
        self.assertTrue(no_exprs)           # plain columns, no expressions

    def test_03_column_order(self):
        self.assertEqual(self.index[7], ["instrument_id", "observed_at", "tick_id"])

    def test_04_desc_where_intended(self):
        # indoption bit 1 = DESC, bit 2 = NULLS FIRST (DESC default => 3)
        self.assertEqual(self.index[5], [0, 3, 3])
        self.assertEqual(self.index[6], EXPECTED_DEF)

    def test_05_only_approved_non_constraint_index(self):
        extra = self.conn.execute("""
            SELECT i.indexrelid::regclass::text FROM pg_index i
            WHERE i.indrelid::regclass::text = ANY(%s)
              AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = i.indexrelid)""",
            (list(TABLES),)).fetchall()
        self.assertEqual(extra, [(INDEX,)])

    def test_06_tables_and_constraints_unchanged(self):
        result = psql_file(DEV_DB, "verify_spec.sql")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("LIVE SCHEMA MATCHES", result.stderr)   # NOTICEs go to stderr


# =====================================================================
# Planner properties on a throwaway database with realistic volume
# =====================================================================
class PlannerTests(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        admin(f"DROP DATABASE IF EXISTS {TEST_DB}")
        admin(f"CREATE DATABASE {TEST_DB}")
        result = psql_file(TEST_DB, "00_schema.sql", "01_seed.sql",
                           "03_functions_triggers.sql", "06_indexes.sql")
        if result.returncode != 0:
            raise RuntimeError(result.stderr)
        with psycopg.connect(dbname=TEST_DB, autocommit=True) as conn:
            conn.execute("""INSERT INTO instruments (exchange, symbol, name, quote_currency)
                            SELECT 'NSE', 'BENCH' || lpad(n::text, 2, '0'), 'Bench ' || n, 'INR'
                            FROM generate_series(1, 13) n""")
            # synthetic test data only: bulk load without the alert trigger
            conn.execute("ALTER TABLE price_ticks DISABLE TRIGGER trg_price_ticks_evaluate_alerts")
            conn.execute("""
                INSERT INTO price_ticks (instrument_id, observed_at, price, volume, source, source_event_id)
                SELECT ((g - 1) %% 20) + 1,
                       timestamptz '2026-01-05 09:15:00+05:30' + g * interval '100 milliseconds',
                       round((1000 + ((g - 1) %% 20) * 150 + 50 * sin(g / 5000.0))::numeric, 2),
                       CASE WHEN g %% 10 = 0 THEN NULL ELSE g %% 500 + 1 END,
                       'REPLAY', 'itest:' || lpad(g::text, 7, '0')
                FROM generate_series(1, %s) g""", (TEST_ROWS,))
            conn.execute("ALTER TABLE price_ticks ENABLE TRIGGER trg_price_ticks_evaluate_alerts")
            conn.execute("VACUUM ANALYZE price_ticks")
            cls.params = query_params(conn)
        cls.conn = psycopg.connect(dbname=TEST_DB, autocommit=True)

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()
        admin(f"DROP DATABASE IF EXISTS {TEST_DB}")

    def plan(self, name, conn=None):
        conn = conn or self.conn
        return conn.execute("EXPLAIN (FORMAT JSON) " + QUERIES[name], self.params).fetchone()[0][0]["Plan"]

    def price_ticks_nodes(self, plan):
        return [n for n in walk(plan) if n.get("Relation Name") == "price_ticks"
                or n.get("Index Name", "").startswith(("ix_price", "uq_price", "pk_price"))]

    def uses_index(self, plan):
        return any(n.get("Index Name") == INDEX for n in walk(plan))

    def has(self, plan, *node_types):
        return any(n["Node Type"] in node_types for n in walk(plan))

    # ---- the application's query shapes --------------------------------
    def test_07_latest_n_uses_index_without_sort(self):
        plan = self.plan("A_latest_50")
        self.assertTrue(self.uses_index(plan))
        self.assertFalse(self.has(plan, "Sort", "Incremental Sort"))
        self.assertFalse(self.has(plan, "Seq Scan", "Parallel Seq Scan"))

    def test_08_previous_tick_row_comparison_is_an_index_condition(self):
        plan = self.plan("C_previous_tick")
        scans = [n for n in walk(plan) if n.get("Index Name") == INDEX]
        self.assertEqual(len(scans), 1)
        self.assertIn("ROW(observed_at, tick_id) <", scans[0].get("Index Cond", ""))
        self.assertFalse(self.has(plan, "Sort", "Incremental Sort"))

    def test_09_late_tick_check_uses_index(self):
        plan = self.plan("E_late_tick_check")
        self.assertTrue(self.uses_index(plan))
        self.assertFalse(self.has(plan, "Seq Scan", "Parallel Seq Scan"))

    def test_10_time_range_uses_index(self):
        # the planner may pick an ordered Index Scan or Bitmap Index Scan + Sort;
        # both are valid - the property checked is that it uses our index
        plan = self.plan("B_range_30min")
        self.assertTrue(self.uses_index(plan))
        self.assertFalse(self.has(plan, "Seq Scan", "Parallel Seq Scan"))

    def test_11_watchlist_latest_prices_uses_index(self):
        self.assertTrue(self.uses_index(self.plan("D_watchlist_latest_prices")))

    # ---- the alert trigger's own queries --------------------------------
    def test_12_alert_trigger_queries_use_index(self):
        notices = []
        with psycopg.connect(dbname=TEST_DB, autocommit=True) as conn:
            conn.add_notice_handler(lambda d: notices.append(d.message_primary))
            last = conn.execute("SELECT max(observed_at) FROM price_ticks "
                                "WHERE instrument_id = %s", (self.params["iid"],)).fetchone()[0]
            with conn.transaction(force_rollback=True):
                for s in ("LOAD 'auto_explain'",
                          "SET LOCAL auto_explain.log_min_duration = 0",
                          "SET LOCAL auto_explain.log_nested_statements = on",
                          "SET LOCAL auto_explain.log_level = notice"):
                    conn.execute(s)
                conn.execute("SELECT * FROM ingest_tick('NSE','RELIANCE', %s + interval '1 s', "
                             "3100, 1, 'MANUAL', 'itest:auto-explain')", (last,))
        late = [n for n in notices if "t.observed_at > NEW.observed_at" in n]
        prev = [n for n in notices if "(t.observed_at, t.tick_id) < (NEW.observed_at, NEW.tick_id)" in n]
        self.assertEqual((len(late), len(prev)), (1, 1), "trigger queries not captured")
        self.assertIn(INDEX, late[0])
        self.assertIn(INDEX, prev[0])
        self.assertNotIn("Seq Scan on price_ticks", late[0] + prev[0])

    # ---- control / correctness -------------------------------------------
    def test_13_without_index_plans_change_but_results_do_not(self):
        with psycopg.connect(dbname=TEST_DB) as conn:          # explicit transaction
            with_rows = {n: conn.execute(QUERIES[n], self.params).fetchall() for n in QUERIES}
            conn.execute(f"DROP INDEX {INDEX}")                 # rolled back below
            plan = self.plan("A_latest_50", conn)
            self.assertFalse(self.uses_index(plan))
            self.assertTrue(self.has(plan, "Sort", "Incremental Sort"))
            for n in QUERIES:
                self.assertEqual(conn.execute(QUERIES[n], self.params).fetchall(), with_rows[n], n)
            conn.rollback()
        self.assertTrue(self.uses_index(self.plan("A_latest_50")))  # index back

    def test_14_alerts_still_correct_with_index(self):
        with psycopg.connect(dbname=TEST_DB, autocommit=True) as conn:
            last = conn.execute("SELECT max(observed_at) FROM price_ticks "
                                "WHERE instrument_id = %s", (self.params["iid"],)).fetchone()[0]
            with conn.transaction(force_rollback=True):
                before = conn.execute("SELECT count(*) FROM alert_events").fetchone()[0]
                for k, price in enumerate((2990, 3010, 3020)):   # cross ABOVE 3000 once
                    conn.execute("SELECT * FROM ingest_tick('NSE','RELIANCE', %s + make_interval(secs => %s), "
                                 "%s, 1, 'MANUAL', %s)", (last, k + 1, price, f"itest:x{k}"))
                after = conn.execute("SELECT count(*) FROM alert_events").fetchone()[0]
        self.assertEqual(after - before, 1)

    # ---- the verifier still catches index drift --------------------------
    def test_15_verifier_detects_extra_and_missing_index(self):
        self.assertEqual(psql_file(TEST_DB, "verify_spec.sql").returncode, 0)
        admin_conn = psycopg.connect(dbname=TEST_DB, autocommit=True)
        try:
            admin_conn.execute("CREATE INDEX ix_unapproved ON price_ticks (price)")
            extra = psql_file(TEST_DB, "verify_spec.sql")
            self.assertNotEqual(extra.returncode, 0)
            self.assertIn("ix_unapproved", extra.stdout)
            self.assertIn("EXTRA in live DB", extra.stdout)
            admin_conn.execute("DROP INDEX ix_unapproved")

            admin_conn.execute(f"DROP INDEX {INDEX}")
            missing = psql_file(TEST_DB, "verify_spec.sql")
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn("MISSING in live DB", missing.stdout)
        finally:
            admin_conn.execute("DROP INDEX IF EXISTS ix_unapproved")
            admin_conn.close()
            psql_file(TEST_DB, "06_indexes.sql")
        self.assertEqual(psql_file(TEST_DB, "verify_spec.sql").returncode, 0)


if __name__ == "__main__":
    unittest.main()
