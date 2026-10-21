#!/usr/bin/env bash
# Review 2 academic sandbox: build it, run every sql/review2 script, verify
# the real output, and (separately) clean it up.
#
#   source .venv/bin/activate                     # first (replay needs psycopg)
#   bash scripts/review2_sandbox.sh               # rebuild + run all + verify
#   bash scripts/review2_sandbox.sh --index-explain
#                                                 # also re-run the EXPLAIN ANALYZE
#                                                 # comparison on stock_watchlist_benchmark
#   bash scripts/review2_sandbox.sh --auth-demo   # also prove a password (SCRAM) login of the
#                                                 # restricted role on a throwaway server
#   bash scripts/review2_sandbox.sh --cleanup     # drop the sandbox and the r2_* roles
#
# What it touches, and nothing else:
#   database  stock_watchlist_review2_sandbox  (dropped and rebuilt each run)
#   roles     r2_owner, r2_analyst, r2_support, r2_feed  (PostgreSQL roles are
#             cluster-wide; they get privileges only inside the sandbox and
#             are NOLOGIN except during the login probe)
#   files     docs/review2/sql_output/*.out, QUERY_EVIDENCE.md, SCREENSHOT_MATRIX.md,
#             TABLE_CONSTRAINT_INVENTORY.md (all regenerated from real output)
# With --index-explain it also reads stock_watchlist_benchmark through
# sql/07_benchmark_queries.sql (its DROP INDEX runs inside a transaction
# that is rolled back).
#
# The classroom database stock_watchlist is never connected to.

set -euo pipefail

SANDBOX="stock_watchlist_review2_sandbox"
ROLES=(r2_analyst r2_support r2_feed r2_owner)
LOGIN_PROBE_ROLE="r2_analyst"
RUN_ID="r2demo"
PG_BIN="${PG_BIN:-/opt/homebrew/opt/postgresql@18/bin}"
export PATH="$PG_BIN:$PATH"
cd "$(dirname "$0")/.."

case "$SANDBOX" in
    stock_watchlist|stock_watchlist_benchmark|postgres|template0|template1)
        echo "REFUSING: $SANDBOX is not a sandbox name" >&2; exit 2 ;;
esac

OUT_DIR="docs/review2/sql_output"
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -P pager=off)

drop_roles() {
    for r in "${ROLES[@]}"; do
        "${PSQL[@]}" -d postgres -c "DROP ROLE IF EXISTS $r" >/dev/null
    done
}

drop_sandbox() {
    dropdb --if-exists --force "$SANDBOX"
    drop_roles
}

if [ "${1:-}" = "--cleanup" ]; then
    drop_sandbox
    echo "Removed database $SANDBOX and roles: ${ROLES[*]}"
    exit 0
fi

INDEX_EXPLAIN=0
AUTH_DEMO=0
for arg in "$@"; do
    case "$arg" in
        --index-explain) INDEX_EXPLAIN=1 ;;
        --auth-demo)     AUTH_DEMO=1 ;;
        *) echo "unknown option: $arg (use --index-explain, --auth-demo or --cleanup)" >&2; exit 2 ;;
    esac
done

if ! python -c "import psycopg" 2>/dev/null; then
    echo "ERROR: activate the virtual environment first: source .venv/bin/activate" >&2
    exit 2
fi

restore_nologin() {
    "${PSQL[@]}" -d postgres -c "DO \$\$ BEGIN IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$LOGIN_PROBE_ROLE') THEN ALTER ROLE $LOGIN_PROBE_ROLE NOLOGIN; END IF; END \$\$" >/dev/null 2>&1 || true
}
trap restore_nologin EXIT

echo "== 1. Fresh sandbox: $SANDBOX"
drop_sandbox
createdb "$SANDBOX"
PGOPTIONS="-c client_min_messages=warning" "${PSQL[@]}" -d "$SANDBOX" \
    -f sql/00_schema.sql -f sql/01_seed.sql -f sql/03_functions_triggers.sql -f sql/06_indexes.sql
echo "   built from sql/00_schema.sql, 01_seed.sql, 03_functions_triggers.sql, 06_indexes.sql"

echo "== 2. Replay data/replay_prices.csv (run id $RUN_ID) through ingest_tick()"
mkdir -p "$OUT_DIR"
DB_NAME="$SANDBOX" python -m app.replay data/replay_prices.csv --run-id "$RUN_ID" \
    > "$OUT_DIR/00_replay_load.out" 2>&1
tail -3 "$OUT_DIR/00_replay_load.out" | sed 's/^/   /'

echo "== 3. Run sql/review2 scripts (output: $OUT_DIR)"
for f in sql/review2/[0-9]*.sql; do
    name="$(basename "$f" .sql)"
    out="$OUT_DIR/$name.out"
    if [[ "$name" == *login_probe* ]]; then
        # A real, separate login as the restricted role. Local connections
        # on this cluster use pg_hba "trust", so no password is involved;
        # LOGIN is switched on only for this step and off again afterwards.
        "${PSQL[@]}" -d postgres -c "ALTER ROLE $LOGIN_PROBE_ROLE LOGIN" >/dev/null
        status=0
        "${PSQL[@]}" -e -U "$LOGIN_PROBE_ROLE" -d "$SANDBOX" -f "$f" > "$out" 2>&1 || status=$?
        restore_nologin
    else
        status=0
        "${PSQL[@]}" -e -d "$SANDBOX" -f "$f" > "$out" 2>&1 || status=$?
    fi
    if [ "$status" -ne 0 ]; then
        echo "   FAIL  $f (psql exit $status)"; echo; tail -25 "$out"; exit 1
    fi
    echo "   ran   $f"
done

echo "== 4. Core schema in the sandbox still matches the design (sql/verify_spec.sql)"
"${PSQL[@]}" -d "$SANDBOX" -f sql/verify_spec.sql > "$OUT_DIR/90_verify_spec_sandbox.out" 2>&1
grep -h "LIVE SCHEMA MATCHES" "$OUT_DIR/90_verify_spec_sandbox.out" | sed 's/^.*NOTICE: */   /'
echo "   conceptual ER diagram vs catalog (scripts/review2_diagrams.py --verify-db):"
python scripts/review2_diagrams.py --verify-db "$SANDBOX" > "$OUT_DIR/92_er_vs_catalog.out"
tail -1 "$OUT_DIR/92_er_vs_catalog.out" | sed 's/^/   /'
if [ -f docs/review2/ER_CHEN_PRESENTATION.svg ]; then
    echo "   team presentation diagram vs the verified model (--audit-svg):"
    python scripts/review2_diagrams.py --audit-svg docs/review2/ER_CHEN_PRESENTATION.svg \
        > "$OUT_DIR/94_team_er_audit.out"
    tail -1 "$OUT_DIR/94_team_er_audit.out" | sed 's/^/   /'
fi

if [ "$INDEX_EXPLAIN" -eq 1 ]; then
    echo "== 5. EXPLAIN ANALYZE before/after index on stock_watchlist_benchmark"
    "${PSQL[@]}" -d stock_watchlist_benchmark -f sql/07_benchmark_queries.sql \
        > "$OUT_DIR/91_index_explain_benchmark.out" 2>&1
    echo "   written $OUT_DIR/91_index_explain_benchmark.out"
fi

if [ "$AUTH_DEMO" -eq 1 ]; then
    echo "== 5b. Password (SCRAM) login proof on a throwaway server (scripts/review2_auth_demo.sh)"
    bash scripts/review2_auth_demo.sh | sed 's/^/   /'
fi

echo "== 6. Verify every output (expected errors only, every query returns rows)"
python scripts/review2_evidence.py check "$OUT_DIR"/[0-9]*.out
python scripts/review2_evidence.py queries --db "$SANDBOX" --out docs/review2/QUERY_EVIDENCE.md
python scripts/review2_evidence.py matrix  --db "$SANDBOX" --out docs/review2/SCREENSHOT_MATRIX.md
python scripts/review2_inventory.py --db "$SANDBOX"

echo
echo "REVIEW 2 SANDBOX READY: $SANDBOX (kept for screenshots; remove with --cleanup)"
