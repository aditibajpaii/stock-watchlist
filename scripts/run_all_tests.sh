#!/usr/bin/env bash
# Run every test suite in order and stop at the first failure.
#
#   source .venv/bin/activate      # first
#   bash scripts/run_all_tests.sh
#
# Suites:
#   sql/02_schema_tests.sql     51 tests  (dev DB, one transaction, rolled back)
#   sql/verify_spec.sql         schema matches docs/SCHEMA_DESIGN.md (read-only)
#   sql/04_alert_tests.sql      50 tests  (dev DB, rolled back)
#   tests/concurrency_test.sh   17 checks (throwaway DB stock_watchlist_ctest)
#   tests.test_replay           18 tests  (throwaway DBs)
#   tests.test_indexes          15 tests  (reads dev DB; throwaway DB for plans)
#   tests.test_api              32 tests  (throwaway DBs)
#   tests.test_frontend         14 tests  (throwaway DB)
#   tests.test_live_feed        24 tests  (throwaway DB; no internet needed)
# The dev database stock_watchlist is left unchanged. The 500,000-row
# benchmark (tests/benchmark_indexes.py) is NOT run; its results are kept
# in docs/benchmark_results/.
#
# Requirements: PostgreSQL running, the dev DB built (scripts/reset_demo_db.sh),
# and the project virtual environment active.

set -uo pipefail

PG_BIN="${PG_BIN:-/opt/homebrew/opt/postgresql@18/bin}"
export PATH="$PG_BIN:$PATH"
DB=stock_watchlist
cd "$(dirname "$0")/.."

if ! python -c "import fastapi, psycopg, websockets" 2>/dev/null; then
    echo "ERROR: activate the virtual environment first: source .venv/bin/activate" >&2
    exit 2
fi

LOG_DIR=$(mktemp -d)

run() {                      # run <label> <command...>
    local label="$1"; shift
    local log="$LOG_DIR/$(echo "$label" | tr ' /' '__').log"
    printf '%-44s ' "$label"
    if "$@" >"$log" 2>&1; then
        local detail
        detail=$(summarize "$log")
        echo "PASS  $detail"
    else
        echo "FAIL"
        echo
        echo "----- last 40 lines of $log -----"
        tail -40 "$log"
        echo
        echo "STOPPED at the first failing suite: $label"
        exit 1
    fi
}

summarize() {                # a short result line from a suite's output
    local log="$1"
    if grep -q "passed | failed | total" "$log"; then          # 02 / 04 summary table
        grep -A2 "passed | failed | total" "$log" | tail -1 |
            awk -F'|' '{gsub(/ /,""); print $1 "/" $3 " passed"}'
    elif grep -q "LIVE SCHEMA MATCHES" "$log"; then
        echo "schema matches design"
    elif grep -q "ALL CONCURRENCY CHECKS PASSED" "$log"; then
        echo "$(grep -c '  PASS ' "$log") checks passed"
    elif grep -q "^Ran " "$log"; then
        grep "^Ran " "$log" | tail -1 | awk '{print $2 " tests OK"}'
    fi
}

echo "Running all test suites (logs in $LOG_DIR)"
echo
run "Schema tests"                psql -X -q -d "$DB" -v ON_ERROR_STOP=1 -f sql/02_schema_tests.sql
run "Schema verifier"             psql -X -q -d "$DB" -v ON_ERROR_STOP=1 -f sql/verify_spec.sql
run "Alert tests"                 psql -X -q -d "$DB" -v ON_ERROR_STOP=1 -f sql/04_alert_tests.sql
run "Concurrency checks"          bash tests/concurrency_test.sh
run "Replay tests"                python -m unittest tests.test_replay
run "Index tests"                 python -m unittest tests.test_indexes
run "API tests"                   python -m unittest tests.test_api
run "Frontend tests"              python -m unittest tests.test_frontend
run "Live-feed tests"             python -m unittest tests.test_live_feed

echo
echo "ALL SUITES PASSED"
