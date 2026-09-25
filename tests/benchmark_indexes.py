"""Phase 6 index benchmark on a THROWAWAY database.

Builds stock_watchlist_benchmark from sql/00, 01, 03, bulk-loads synthetic
price ticks, then measures the project's real query shapes in three stages:

  1. baseline  - only the PK/UNIQUE indexes from 00_schema.sql
  2. btree     - after running sql/06_indexes.sql (the production index)
  3. brin      - B-tree dropped, BRIN (observed_at) instead (comparison only)

and finally restores the production B-tree so the database can be used for
manual screenshots with sql/07_benchmark_queries.sql.

The dev database (stock_watchlist) is never touched.

BENCHMARK-ONLY BULK LOAD: synthetic rows are inserted directly into
price_ticks with trg_price_ticks_evaluate_alerts DISABLED on this throwaway
database. This is not an application ingestion path (ingest_tick is).

Run (project root, venv active):
    python tests/benchmark_indexes.py            # 500,000 rows, 7 timed runs
    python tests/benchmark_indexes.py --rows 100000 --runs 5
Cleanup afterwards:
    dropdb stock_watchlist_benchmark

Raw output: docs/benchmark_results/ (results.json + plan text files).
"""

import argparse
import hashlib
import json
import os
import platform
import statistics
import subprocess
import sys
import time
from datetime import timedelta
from pathlib import Path

import psycopg

ROOT = Path(__file__).resolve().parent.parent
PG_BIN = Path(os.environ.get("PG_BIN", "/opt/homebrew/opt/postgresql@18/bin"))
DB = "stock_watchlist_benchmark"
OUT = ROOT / "docs" / "benchmark_results"
INDEX = "ix_price_ticks_instrument_time"
BRIN = "ix_bench_brin_observed_at"
N_INSTRUMENTS = 20                      # 7 seed + 13 benchmark instruments

# Query shapes used by the project. %(name)s parameters are filled from the
# data by query_params(). Keep in sync with sql/07_benchmark_queries.sql.
QUERIES = {
    "A_latest_50": """
        SELECT tick_id, observed_at, price, volume
        FROM price_ticks
        WHERE instrument_id = %(iid)s
        ORDER BY observed_at DESC, tick_id DESC
        LIMIT 50""",
    "B_range_30min": """
        SELECT tick_id, observed_at, price, volume
        FROM price_ticks
        WHERE instrument_id = %(iid)s
          AND observed_at >= %(range_from)s
          AND observed_at <  %(range_to)s
        ORDER BY observed_at, tick_id""",
    "C_previous_tick": """
        SELECT t.price
        FROM price_ticks t
        WHERE t.instrument_id = %(iid)s
          AND (t.observed_at, t.tick_id) < (%(c_observed_at)s, %(c_tick_id)s)
        ORDER BY t.observed_at DESC, t.tick_id DESC
        LIMIT 1""",
    "D_watchlist_latest_prices": """
        SELECT i.symbol, lt.price, lt.observed_at
        FROM watchlist_items wi
        JOIN instruments i ON i.instrument_id = wi.instrument_id
        CROSS JOIN LATERAL (
            SELECT t.price, t.observed_at
            FROM price_ticks t
            WHERE t.instrument_id = wi.instrument_id
            ORDER BY t.observed_at DESC, t.tick_id DESC
            LIMIT 1) lt
        WHERE wi.watchlist_id = %(watchlist_id)s
        ORDER BY i.symbol""",
    "E_late_tick_check": """
        SELECT EXISTS (SELECT 1 FROM price_ticks t
                       WHERE t.instrument_id = %(iid)s
                         AND t.observed_at > %(e_observed_at)s)""",
}


# ---------------------------------------------------------------------
# setup
# ---------------------------------------------------------------------
def admin(sql):
    with psycopg.connect(dbname="postgres", autocommit=True) as conn:
        conn.execute(sql)


def psql(*files):
    args = [str(PG_BIN / "psql"), "-X", "-q", "-d", DB, "-v", "ON_ERROR_STOP=1"]
    for f in files:
        args += ["-f", str(ROOT / "sql" / f)]
    subprocess.run(args, check=True, capture_output=True, text=True)


def build(rows):
    admin(f"DROP DATABASE IF EXISTS {DB}")
    admin(f"CREATE DATABASE {DB}")
    psql("00_schema.sql", "01_seed.sql", "03_functions_triggers.sql")
    with psycopg.connect(dbname=DB, autocommit=True) as conn:
        conn.execute("""
            INSERT INTO instruments (exchange, symbol, name, quote_currency)
            SELECT 'NSE', 'BENCH' || lpad(n::text, 2, '0'), 'Benchmark instrument ' || n, 'INR'
            FROM generate_series(1, %s) n""", (N_INSTRUMENTS - 7,))
        # benchmark-only: bypass the alert trigger for the synthetic bulk load
        conn.execute("ALTER TABLE price_ticks DISABLE TRIGGER trg_price_ticks_evaluate_alerts")
        start = time.perf_counter()
        conn.execute("""
            INSERT INTO price_ticks (instrument_id, observed_at, price, volume, source, source_event_id)
            SELECT ((g - 1) %% %(n)s) + 1,
                   timestamptz '2026-01-05 09:15:00+05:30' + g * interval '100 milliseconds',
                   round((1000 + ((g - 1) %% %(n)s) * 150 + 50 * sin(g / 5000.0))::numeric, 2),
                   CASE WHEN g %% 10 = 0 THEN NULL ELSE (g %% 500) + 1 END,
                   'REPLAY', 'bench:' || lpad(g::text, 7, '0')
            FROM generate_series(1, %(rows)s) g""", {"n": N_INSTRUMENTS, "rows": rows})
        load_s = time.perf_counter() - start
        conn.execute("ALTER TABLE price_ticks ENABLE TRIGGER trg_price_ticks_evaluate_alerts")
        conn.execute("VACUUM ANALYZE price_ticks")
    return load_s


def query_params(conn):
    iid = conn.execute("SELECT instrument_id FROM instruments "
                       "WHERE exchange = 'NSE' AND symbol = 'RELIANCE'").fetchone()[0]
    lo, hi, n = conn.execute("SELECT min(observed_at), max(observed_at), count(*) "
                             "FROM price_ticks WHERE instrument_id = %s", (iid,)).fetchone()
    mid = lo + (hi - lo) / 2
    c_obs, c_tid = conn.execute(
        "SELECT observed_at, tick_id FROM price_ticks WHERE instrument_id = %s "
        "ORDER BY observed_at, tick_id OFFSET %s LIMIT 1", (iid, n // 2)).fetchone()
    wl = conn.execute("SELECT w.watchlist_id FROM watchlists w JOIN users u USING (user_id) "
                      "WHERE u.username = 'arjun' AND w.name = 'Long Term'").fetchone()[0]
    return {"iid": iid, "range_from": mid, "range_to": mid + timedelta(minutes=30),
            "c_observed_at": c_obs, "c_tick_id": c_tid,
            "e_observed_at": hi, "watchlist_id": wl}


# ---------------------------------------------------------------------
# measurement
# ---------------------------------------------------------------------
def walk(plan):
    yield plan
    for child in plan.get("Plans", []):
        yield from walk(child)


def describe_nodes(plan):
    out = []
    for node in walk(plan):
        label = node["Node Type"]
        if node.get("Scan Direction") == "Backward":
            label += " Backward"
        if "Index Name" in node:
            label += f" using {node['Index Name']}"
        out.append(label)
    return out


def measure(conn, name, params, runs):
    sql = QUERIES[name]
    explain = "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " + sql
    for _ in range(2):                                   # warm-up (not recorded)
        conn.execute(explain, params)
    times, last = [], None
    for _ in range(runs):
        last = conn.execute(explain, params).fetchone()[0][0]
        times.append(last["Execution Time"])
    plan = last["Plan"]
    text = "\n".join(r[0] for r in conn.execute(
        "EXPLAIN (ANALYZE, BUFFERS) " + sql, params).fetchall())
    result = conn.execute(sql, params).fetchall()
    return {
        "execution_ms_runs": [round(t, 3) for t in times],
        "execution_ms_median": round(statistics.median(times), 3),
        "planning_ms_last": round(last["Planning Time"], 3),
        "nodes": describe_nodes(plan),
        "seq_scan": any(n["Node Type"] in ("Seq Scan", "Parallel Seq Scan") for n in walk(plan)),
        "sort": any(n["Node Type"] in ("Sort", "Incremental Sort") for n in walk(plan)),
        "shared_hit": plan.get("Shared Hit Blocks", 0),
        "shared_read": plan.get("Shared Read Blocks", 0),
        "rows_returned": plan.get("Actual Rows"),
        "jit": "JIT" in last,
        "plan_text": text,
        "result_rows": len(result),
        "result_sha256": hashlib.sha256(repr(result).encode()).hexdigest(),
    }


def ingest_timing(conn, iid_symbol, calls):
    """Median wall time of ingest_tick (with the alert trigger) per call.

    Each call runs in its own transaction that is ROLLED BACK, so the data
    stays identical between stages.
    """
    last = conn.execute("SELECT max(observed_at) FROM price_ticks t JOIN instruments i "
                        "USING (instrument_id) WHERE i.symbol = %s", (iid_symbol,)).fetchone()[0]
    times = []
    for k in range(calls):
        price = 3010 if k % 2 else 2990                  # alternate across rule 1's 3000
        with conn.transaction(force_rollback=True):
            start = time.perf_counter()
            conn.execute("SELECT * FROM ingest_tick('NSE', %s, %s + make_interval(secs => %s), "
                         "%s, 1, 'MANUAL', %s)", (iid_symbol, last, k + 1, price, f"bench-ingest:{k}"))
            times.append((time.perf_counter() - start) * 1000)
    return {"calls": calls, "median_ms": round(statistics.median(times), 3),
            "min_ms": round(min(times), 3), "max_ms": round(max(times), 3)}


def trigger_plans(conn):
    """auto_explain output for ONE ingest_tick call (nested trigger queries)."""
    notices = []
    handler = lambda d: notices.append(d.message_primary)
    conn.add_notice_handler(handler)
    last = conn.execute("SELECT max(observed_at) FROM price_ticks t JOIN instruments i "
                        "USING (instrument_id) WHERE i.symbol = 'RELIANCE'").fetchone()[0]
    with conn.transaction(force_rollback=True):
        for setting in ("LOAD 'auto_explain'",
                        "SET LOCAL auto_explain.log_min_duration = 0",
                        "SET LOCAL auto_explain.log_analyze = on",
                        "SET LOCAL auto_explain.log_buffers = on",
                        "SET LOCAL auto_explain.log_nested_statements = on",
                        "SET LOCAL auto_explain.log_level = notice"):
            conn.execute(setting)
        conn.execute("SELECT * FROM ingest_tick('NSE', 'RELIANCE', %s + interval '1 second', "
                     "3010, 1, 'MANUAL', 'bench-auto-explain')", (last,))
    conn.remove_notice_handler(handler)
    return "\n\n".join(notices)


def sizes(conn):
    rows = conn.execute("""
        SELECT c.relname, pg_relation_size(c.oid), pg_size_pretty(pg_relation_size(c.oid))
        FROM pg_class c
        WHERE c.oid = 'price_ticks'::regclass
           OR c.oid IN (SELECT indexrelid FROM pg_index WHERE indrelid = 'price_ticks'::regclass)
        ORDER BY c.relname""").fetchall()
    total = conn.execute("SELECT pg_total_relation_size('price_ticks'), "
                         "pg_size_pretty(pg_total_relation_size('price_ticks'))").fetchone()
    return {"relations": {r[0]: {"bytes": r[1], "pretty": r[2]} for r in rows},
            "price_ticks_total": {"bytes": total[0], "pretty": total[1]}}


def run_stage(stage, runs, ingest_calls):
    with psycopg.connect(dbname=DB, autocommit=True) as conn:
        params = query_params(conn)
        result = {"queries": {name: measure(conn, name, params, runs) for name in QUERIES},
                  "sizes": sizes(conn)}
        if ingest_calls:
            result["ingest_tick"] = ingest_timing(conn, "RELIANCE", ingest_calls)
            result["trigger_auto_explain"] = trigger_plans(conn)
        result["params"] = {k: str(v) for k, v in params.items()}
    print_stage(stage, result)
    return result


def print_stage(stage, result):
    print(f"\n=== {stage} ===")
    for name, q in result["queries"].items():
        print(f"  {name:<26} median {q['execution_ms_median']:>9.3f} ms  "
              f"buffers hit={q['shared_hit']:<6} read={q['shared_read']:<6} "
              f"{' > '.join(q['nodes'])}")
    if "ingest_tick" in result:
        print(f"  ingest_tick (trigger on)   median {result['ingest_tick']['median_ms']:>9.3f} ms/call")


# ---------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--rows", type=int, default=500_000)
    ap.add_argument("--runs", type=int, default=7, help="timed runs per query (median reported)")
    ap.add_argument("--ingest-calls", type=int, default=50)
    ap.add_argument("--drop", action="store_true", help="drop the benchmark DB at the end")
    args = ap.parse_args()

    print(f"Building {DB} with {args.rows:,} ticks ...")
    load_s = build(args.rows)
    print(f"Loaded in {load_s:.1f} s (alert trigger disabled for the bulk load only)")

    results = {"rows": args.rows, "instruments": N_INSTRUMENTS, "runs_per_query": args.runs,
               "load_seconds": round(load_s, 2)}
    with psycopg.connect(dbname=DB) as conn:
        results["environment"] = {
            "postgres": conn.execute("SELECT version()").fetchone()[0],
            "settings": dict(conn.execute(
                "SELECT name, setting || coalesce(unit, '') FROM pg_settings WHERE name IN "
                "('shared_buffers','work_mem','effective_cache_size','random_page_cost',"
                "'jit','max_parallel_workers_per_gather')").fetchall()),
            "machine": f"{platform.platform()} {platform.machine()}",
            "python": platform.python_version(),
            "psycopg": psycopg.__version__,
        }
        results["row_count"] = conn.execute("SELECT count(*) FROM price_ticks").fetchone()[0]

    results["baseline"] = run_stage("BASELINE (PK/UNIQUE indexes only)", args.runs, args.ingest_calls)

    start = time.perf_counter()
    psql("06_indexes.sql")
    results["btree_build_seconds"] = round(time.perf_counter() - start, 2)
    with psycopg.connect(dbname=DB, autocommit=True) as conn:
        conn.execute("ANALYZE price_ticks")
    results["btree"] = run_stage(f"WITH B-TREE {INDEX}", args.runs, args.ingest_calls)

    with psycopg.connect(dbname=DB, autocommit=True) as conn:
        conn.execute(f"DROP INDEX {INDEX}")
        start = time.perf_counter()
        conn.execute(f"CREATE INDEX {BRIN} ON price_ticks USING brin (observed_at)")
        results["brin_build_seconds"] = round(time.perf_counter() - start, 2)
        conn.execute("ANALYZE price_ticks")
    results["brin"] = run_stage(f"BRIN ONLY {BRIN} (comparison)", args.runs, 0)

    with psycopg.connect(dbname=DB, autocommit=True) as conn:
        conn.execute(f"DROP INDEX {BRIN}")
    psql("06_indexes.sql")                               # leave the production state
    with psycopg.connect(dbname=DB, autocommit=True) as conn:
        conn.execute("ANALYZE price_ticks")

    # every stage must return exactly the same rows
    same = {name: len({results[st]["queries"][name]["result_sha256"]
                       for st in ("baseline", "btree", "brin")}) == 1 for name in QUERIES}
    results["identical_results_all_stages"] = same
    print(f"\nIdentical results in all stages: {same}")

    OUT.mkdir(parents=True, exist_ok=True)
    for stage in ("baseline", "btree", "brin"):
        with open(OUT / f"plans_{stage}.txt", "w") as f:
            for name, q in results[stage]["queries"].items():
                f.write(f"===== {name}  (median of {args.runs}: {q['execution_ms_median']} ms; "
                        f"runs: {q['execution_ms_runs']})\n{QUERIES[name].strip()}\n\n{q['plan_text']}\n\n")
        if "trigger_auto_explain" in results[stage]:
            (OUT / f"trigger_auto_explain_{stage}.txt").write_text(results[stage].pop("trigger_auto_explain"))
        for q in results[stage]["queries"].values():
            q.pop("plan_text")
    (OUT / "results.json").write_text(json.dumps(results, indent=2, default=str))
    print(f"Raw results written to {OUT.relative_to(ROOT)}/")

    if args.drop:
        admin(f"DROP DATABASE {DB}")
        print(f"Dropped {DB}")
    else:
        print(f"Kept {DB} (production B-tree installed) for manual EXPLAIN screenshots.\n"
              f"Cleanup: dropdb {DB}")
    return 0 if all(same.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
