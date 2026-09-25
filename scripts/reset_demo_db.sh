#!/usr/bin/env bash
# Reset the classroom database to its clean seeded state.
#
#   bash scripts/reset_demo_db.sh                 # resets stock_watchlist
#   bash scripts/reset_demo_db.sh some_other_db   # (tests only) resets another database
#
# Runs, stopping at the first error:
#   sql/00_schema.sql            drops and recreates the 7 tables
#   sql/01_seed.sql              3 users, 7 instruments, 5 watchlists, 11 items, 6 rules
#   sql/03_functions_triggers.sql  ingest_tick() and the 2 triggers
#   sql/06_indexes.sql           ix_price_ticks_instrument_time
# Then prints the row counts and exits non-zero unless they match the clean
# state. It only touches the one database named below: it never creates or
# drops databases, and it runs no git commands.
#
# Same as the direct command:
#   psql -q -d stock_watchlist -v ON_ERROR_STOP=1 -f sql/00_schema.sql -f sql/01_seed.sql \
#        -f sql/03_functions_triggers.sql -f sql/06_indexes.sql

set -euo pipefail

DB="${1:-stock_watchlist}"
PG_BIN="${PG_BIN:-/opt/homebrew/opt/postgresql@18/bin}"
PSQL="$PG_BIN/psql"
EXPECTED="3|7|5|11|6|0|0"

cd "$(dirname "$0")/.."

echo "Resetting database: $DB"
echo "  (drops and rebuilds its tables; all replay/manual/live ticks and alerts in it are removed)"

# client_min_messages=warning hides the harmless "does not exist, skipping" notices
PGOPTIONS="-c client_min_messages=warning" "$PSQL" -X -q -d "$DB" -v ON_ERROR_STOP=1 \
    -f sql/00_schema.sql -f sql/01_seed.sql -f sql/03_functions_triggers.sql -f sql/06_indexes.sql

echo
"$PSQL" -X -d "$DB" -v ON_ERROR_STOP=1 -c "
SELECT (SELECT count(*) FROM users)           AS users,
       (SELECT count(*) FROM instruments)     AS instruments,
       (SELECT count(*) FROM watchlists)      AS watchlists,
       (SELECT count(*) FROM watchlist_items) AS watchlist_items,
       (SELECT count(*) FROM alert_rules)     AS alert_rules,
       (SELECT count(*) FROM price_ticks)     AS price_ticks,
       (SELECT count(*) FROM alert_events)    AS alert_events;"

ACTUAL=$("$PSQL" -X -At -d "$DB" -v ON_ERROR_STOP=1 -c "
SELECT (SELECT count(*) FROM users) || '|' || (SELECT count(*) FROM instruments) || '|' ||
       (SELECT count(*) FROM watchlists) || '|' || (SELECT count(*) FROM watchlist_items) || '|' ||
       (SELECT count(*) FROM alert_rules) || '|' || (SELECT count(*) FROM price_ticks) || '|' ||
       (SELECT count(*) FROM alert_events);")

if [ "$ACTUAL" = "$EXPECTED" ]; then
    echo "OK: $DB is clean (users|instruments|watchlists|items|rules|ticks|events = $ACTUAL)"
else
    echo "ERROR: unexpected counts $ACTUAL (expected $EXPECTED)" >&2
    exit 1
fi
