#!/usr/bin/env bash
# Test the PROPOSED parent-update integrity fix in a throwaway database.
# The fix is NOT applied to stock_watchlist, stock_watchlist_benchmark or the
# Review 2 sandbox.
#
#   source .venv/bin/activate
#   bash scripts/review2_integrity_fix_test.sh          # build, test, drop
#   bash scripts/review2_integrity_fix_test.sh --keep   # keep the test database
#
# Steps (all on stock_watchlist_review2_fixtest, rebuilt like the sandbox):
#   1. build from sql/00, 01, 03, 06 and replay run r2demo
#   2. tests, phase "before": parent instrument_id UPDATEs are accepted
#   3. apply sql/review2/proposed/integrity_parent_update_fix.sql
#   4. tests, phase "after": what is rejected, what still works
#   5. project SQL suites 02_schema_tests.sql and 04_alert_tests.sql with the fix
#   6. sql/verify_spec.sql with the fix (expected to list the new objects)
#   7. Python suites with the fix in their own template databases
#   8. rollback file, then verify_spec.sql again
# Output: docs/review2/sql_output/95_integrity_fix_test.out (steps 1-4, 8)
#         docs/review2/sql_output/proposed_fix_regression_suites.out (steps 5-7)

set -euo pipefail

FIXDB="stock_watchlist_review2_fixtest"
PG_BIN="${PG_BIN:-/opt/homebrew/opt/postgresql@18/bin}"
export PATH="$PG_BIN:$PATH"
cd "$(dirname "$0")/.."

KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

if ! python -c "import fastapi, psycopg" 2>/dev/null; then
    echo "ERROR: activate the virtual environment first: source .venv/bin/activate" >&2
    exit 2
fi

DIR="sql/review2/proposed"
OUT="docs/review2/sql_output/95_integrity_fix_test.out"
SUITES_OUT="docs/review2/sql_output/proposed_fix_regression_suites.out"
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -P pager=off)
mkdir -p "$(dirname "$OUT")"

echo "== 1. Fresh test database: $FIXDB"
dropdb --if-exists --force "$FIXDB"
createdb "$FIXDB"
PGOPTIONS="-c client_min_messages=warning" "${PSQL[@]}" -d "$FIXDB" \
    -f sql/00_schema.sql -f sql/01_seed.sql -f sql/03_functions_triggers.sql -f sql/06_indexes.sql
DB_NAME="$FIXDB" python -m app.replay data/replay_prices.csv --run-id r2demo > /dev/null
{
    echo "### Proposed integrity fix: regression test on $FIXDB"
    echo "### built from sql/00_schema.sql, 01_seed.sql, 03_functions_triggers.sql, 06_indexes.sql + replay run r2demo"
    echo
    echo "### STEP 2. Phase BEFORE (production design, no fix)"
} > "$OUT"

echo "== 2. Phase before: the gap"
"${PSQL[@]}" -e -d "$FIXDB" -v phase=before -f "$DIR/integrity_parent_update_fix_tests.sql" >> "$OUT" 2>&1

echo "== 3. Apply the proposed fix (test database only)"
{ echo; echo "### STEP 3. Apply $DIR/integrity_parent_update_fix.sql"; } >> "$OUT"
"${PSQL[@]}" -e -d "$FIXDB" -f "$DIR/integrity_parent_update_fix.sql" >> "$OUT" 2>&1

echo "== 4. Phase after: rejected and still-allowed operations"
{ echo; echo "### STEP 4. Phase AFTER (fix applied)"; } >> "$OUT"
"${PSQL[@]}" -e -d "$FIXDB" -v phase=after -f "$DIR/integrity_parent_update_fix_tests.sql" >> "$OUT" 2>&1

echo "== 5. Project SQL suites with the fix"
{
    echo "### Regression suites run with the PROPOSED fix applied ($(date '+%Y-%m-%d %H:%M %Z'))"
    echo
    echo "### STEP 5a. sql/02_schema_tests.sql on $FIXDB"
} > "$SUITES_OUT"
"${PSQL[@]}" -d "$FIXDB" -f sql/02_schema_tests.sql >> "$SUITES_OUT" 2>&1
{ echo; echo "### STEP 5b. sql/04_alert_tests.sql on $FIXDB"; } >> "$SUITES_OUT"
"${PSQL[@]}" -d "$FIXDB" -f sql/04_alert_tests.sql >> "$SUITES_OUT" 2>&1
grep -A2 "passed | failed | total" "$SUITES_OUT" | grep -E "^ *[0-9]" | sed 's/^/   /'

echo "== 6. sql/verify_spec.sql with the fix (expected: reports the 3 new objects)"
{ echo; echo "### STEP 6. sql/verify_spec.sql with the fix applied (expected to fail: it lists the design's objects)"; } >> "$SUITES_OUT"
status=0
"${PSQL[@]}" -d "$FIXDB" -f sql/verify_spec.sql >> "$SUITES_OUT" 2>&1 || status=$?
echo "   verify_spec exit status $status (non-zero expected until verify_spec.sql lists the new objects)"
echo "### verify_spec exit status: $status" >> "$SUITES_OUT"

echo "== 7. Python suites with the fix in their template databases"
{ echo; echo "### STEP 7. python scripts/review2_fixtest_suites.py"; } >> "$SUITES_OUT"
status=0
python scripts/review2_fixtest_suites.py >> "$SUITES_OUT" 2>&1 || status=$?
grep -E "^SUITE |^ALL SUITES|SUITE\(S\) FAILED" "$SUITES_OUT" | sed 's/^/   /'
[ "$status" -eq 0 ] || { echo "Python suites FAILED with the fix (see $SUITES_OUT)"; exit 1; }

echo "== 8. Rollback file, then verify_spec.sql again"
{ echo; echo "### STEP 8. Undo with $DIR/integrity_parent_update_fix_rollback.sql, then sql/verify_spec.sql"; } >> "$OUT"
"${PSQL[@]}" -e -d "$FIXDB" -f "$DIR/integrity_parent_update_fix_rollback.sql" >> "$OUT" 2>&1
"${PSQL[@]}" -d "$FIXDB" -f sql/verify_spec.sql >> "$OUT" 2>&1
grep -h "LIVE SCHEMA MATCHES" "$OUT" | sed 's/^.*NOTICE: */   /'

python scripts/review2_evidence.py check "$OUT"

if [ "$KEEP" -eq 0 ]; then
    dropdb --force "$FIXDB"
    echo "Dropped $FIXDB"
fi
echo "INTEGRITY FIX TEST COMPLETE (logs: $OUT, $SUITES_OUT)"
