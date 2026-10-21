-- =====================================================================
-- 01_setup.sql  -  Review 2 academic sandbox: setup and build facts
--
-- Prerequisite (done by scripts/review2_sandbox.sh):
--   createdb stock_watchlist_review2_sandbox
--   psql ... -f sql/00_schema.sql -f sql/01_seed.sql
--            -f sql/03_functions_triggers.sql -f sql/06_indexes.sql
--   DB_NAME=stock_watchlist_review2_sandbox \
--       python -m app.replay data/replay_prices.csv --run-id r2demo
--
-- All Review 2 academic objects (views, procedures, extra functions,
-- cursor demo) are created in their own schema "review2", so the 7
-- production tables, functions, triggers and index in schema "public"
-- stay exactly as sql/00, 03 and 06 built them.
-- =====================================================================
\ir _guard.sql

\echo '===== Connection ====='
SELECT current_database() AS database, current_user AS connected_as,
       split_part(version(), ' on ', 1) AS server;

DROP SCHEMA IF EXISTS review2 CASCADE;
CREATE SCHEMA review2;
COMMENT ON SCHEMA review2 IS
    'Review 2 academic demonstrations (views, procedures, functions, cursors). Not used by the application.';

\echo '===== Row counts: seed + one replay run (expected 3|7|5|11|30|6|8) ====='
SELECT (SELECT count(*) FROM users)           AS users,
       (SELECT count(*) FROM instruments)     AS instruments,
       (SELECT count(*) FROM watchlists)      AS watchlists,
       (SELECT count(*) FROM watchlist_items) AS watchlist_items,
       (SELECT count(*) FROM price_ticks)     AS price_ticks,
       (SELECT count(*) FROM alert_rules)     AS alert_rules,
       (SELECT count(*) FROM alert_events)    AS alert_events;

\echo '===== Ticks per source and instrument (replay run r2demo) ====='
SELECT t.source, i.exchange, i.symbol, count(*) AS ticks,
       min(t.source_event_id) AS first_event_id, max(t.source_event_id) AS last_event_id
FROM price_ticks t
JOIN instruments i ON i.instrument_id = t.instrument_id
GROUP BY t.source, i.exchange, i.symbol
ORDER BY i.exchange, i.symbol;

\echo '===== Alert events produced by the replay (expected 8: rules 1x2, 2x1, 3x2, 4x2, 6x1) ====='
SELECT e.rule_id, count(*) AS events
FROM alert_events e
GROUP BY e.rule_id
ORDER BY e.rule_id;
