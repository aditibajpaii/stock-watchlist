#!/usr/bin/env bash
# Run every existing test suite, in phase order, and stop at the first failure.
#
#   source .venv/bin/activate      # first
#   bash scripts/run_all_tests.sh
#
# Suites (nothing new is tested here; these are the project's real suites):
#   Phase 2  sql/02_schema_tests.sql     51 tests  (dev DB, one transaction, rolled back)
#   Phase 3  sql/verify_spec.sql         schema matches docs/PHASE1_SPEC.md (read-only)
#   Phase 4  sql/04_alert_tests.sql      50 tests  (dev DB, rolled back)
#   Phase 4  tests/concurrency_test.sh   17 checks (throwaway DB stock_watchlist_ctest)
#   Phase 5  tests.test_replay           18 tests  (throwaway DBs)
#   Phase 6  tests.test_indexes          15 tests  (reads dev DB; throwaway DB for plans)
#   Phase 7  tests.test_api              32 tests  (throwaway DBs)
#   Phase 8  tests.test_frontend         14 tests  (throwaway DB)
#   Phase 9  tests.test_live_feed        24 tests  (throwaway DB; no internet needed)
# The dev database stock_watchlist is left unchanged. The 500,000-row
# benchmark (tests/benchmark_indexes.py) is NOT run; its results are kept
# in docs/benchmark_results/.
#
# Requirements: PostgreSQL running, the dev DB built (scripts/reset_demo_db.sh),
# and the project virtual environment active. No git commands.

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
        echo "schema matches spec"
    elif grep -q "ALL CONCURRENCY CHECKS PASSED" "$log"; then
        echo "$(grep -c '  PASS ' "$log") checks passed"
    elif grep -q "^Ran " "$log"; then
        grep "^Ran " "$log" | tail -1 | awk '{print $2 " tests OK"}'
    fi
}

echo "Running all test suites (logs in $LOG_DIR)"
echo
run "Phase 2 schema tests"        psql -X -q -d "$DB" -v ON_ERROR_STOP=1 -f sql/02_schema_tests.sql
run "Phase 3 schema verifier"     psql -X -q -d "$DB" -v ON_ERROR_STOP=1 -f sql/verify_spec.sql
run "Phase 4 alert tests"         psql -X -q -d "$DB" -v ON_ERROR_STOP=1 -f sql/04_alert_tests.sql
run "Phase 4 concurrency checks"  bash tests/concurrency_test.sh
run "Phase 5 replay tests"        python -m unittest tests.test_replay
run "Phase 6 index tests"         python -m unittest tests.test_indexes
run "Phase 7 API tests"           python -m unittest tests.test_api
run "Phase 8 frontend tests"      python -m unittest tests.test_frontend
run "Phase 9 live-feed tests"     python -m unittest tests.test_live_feed

echo
echo "ALL SUITES PASSED"
