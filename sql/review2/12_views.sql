-- =====================================================================
-- 12_views.sql  -  Template "Views (2-3 minimum)"
--   V1 review2.v_watchlist_contents   join of 5 tables (>= 3 required)
--   V2 review2.v_instrument_activity  aggregated view
--   V3 review2.v_active_alert_rules   row-restricting view WITH CHECK OPTION;
--                                     the access path for the support role
--                                     in 17_security.sql
-- Shows each view being queried, whether PostgreSQL considers it
-- updatable (catalog), an UPDATE through V3, and the CHECK OPTION
-- rejecting a change that would move a row out of the view.
-- Data changes are made inside a transaction that is ROLLED BACK.
--
-- Note: a view alone does not hide the base table. A user who has
-- SELECT on alert_rules can still read inactive rules directly; the
-- protection comes from privileges (17_security.sql).
-- =====================================================================
\ir _guard.sql

CREATE OR REPLACE VIEW review2.v_watchlist_contents AS
SELECT u.username,
       w.name        AS watchlist,
       i.exchange,
       i.symbol,
       i.name        AS instrument_name,
       wi.added_at,
       lt.price      AS latest_price,
       lt.observed_at AS latest_price_at
FROM users u
JOIN watchlists w       ON w.user_id = u.user_id
JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
JOIN instruments i      ON i.instrument_id = wi.instrument_id
LEFT JOIN LATERAL (SELECT t.price, t.observed_at
                   FROM price_ticks t
                   WHERE t.instrument_id = i.instrument_id
                   ORDER BY t.observed_at DESC, t.tick_id DESC
                   LIMIT 1) AS lt ON true;
COMMENT ON VIEW review2.v_watchlist_contents IS
    'V1: what each watchlist contains, with the latest price (users, watchlists, watchlist_items, instruments, price_ticks).';

CREATE OR REPLACE VIEW review2.v_instrument_activity AS
SELECT i.instrument_id, i.exchange, i.symbol,
       count(t.tick_id)       AS ticks,
       min(t.price)           AS min_price,
       max(t.price)           AS max_price,
       round(avg(t.price), 2) AS avg_price,
       count(t.tick_id) - count(t.volume) AS ticks_volume_unknown,
       (SELECT count(*) FROM alert_events e JOIN price_ticks p ON p.tick_id = e.tick_id
         WHERE p.instrument_id = i.instrument_id)                      AS alerts,
       (SELECT count(*) FROM alert_rules r
         WHERE r.instrument_id = i.instrument_id AND r.is_active)       AS active_rules
FROM instruments i
LEFT JOIN price_ticks t ON t.instrument_id = i.instrument_id
GROUP BY i.instrument_id, i.exchange, i.symbol;
COMMENT ON VIEW review2.v_instrument_activity IS
    'V2: per-instrument market activity (aggregated). Contains no user data.';

CREATE OR REPLACE VIEW review2.v_active_alert_rules AS
SELECT rule_id, user_id, instrument_id, direction, threshold, cooldown_seconds, is_active
FROM alert_rules
WHERE is_active
WITH CASCADED CHECK OPTION;
COMMENT ON VIEW review2.v_active_alert_rules IS
    'V3: only ACTIVE rules (row restriction). Updatable; CHECK OPTION stops an update from moving a row out of the view.';

\echo '=== V1 query: what does kavya "Main" contain, and at what latest price?'
SELECT watchlist, symbol, instrument_name, latest_price
FROM review2.v_watchlist_contents
WHERE username = 'kavya'
ORDER BY symbol;

\echo '=== V2 query: instruments with at least one alert, busiest first'
SELECT exchange, symbol, ticks, min_price, max_price, avg_price, alerts, active_rules
FROM review2.v_instrument_activity
WHERE alerts > 0
ORDER BY alerts DESC, symbol;

\echo '=== V3 query: the active rules (rule 5, which is inactive, is not visible)'
SELECT * FROM review2.v_active_alert_rules ORDER BY rule_id;

\echo '===== Which views are updatable? (information_schema, decided by PostgreSQL) ====='
SELECT table_name AS view_name, is_updatable, is_insertable_into, check_option
FROM information_schema.views
WHERE table_schema = 'review2'
ORDER BY table_name;

\echo '===== Updating THROUGH the view V3 (inside a transaction, rolled back) ====='
BEGIN;
\echo 'before: rule 4 cooldown'
SELECT rule_id, cooldown_seconds FROM alert_rules WHERE rule_id = 4;
UPDATE review2.v_active_alert_rules SET cooldown_seconds = 30 WHERE rule_id = 4
RETURNING rule_id, cooldown_seconds;
\echo 'after: the base table alert_rules changed, because V3 is a simple updatable view'
SELECT rule_id, cooldown_seconds FROM alert_rules WHERE rule_id = 4;

\echo 'rule 5 is invisible through V3, so an UPDATE through V3 cannot reach it:'
UPDATE review2.v_active_alert_rules SET cooldown_seconds = 30 WHERE rule_id = 5;
\echo 'rows updated:' :ROW_COUNT

\set ON_ERROR_STOP off
SAVEPOINT before_check_option;
\echo '>>> EXPECTED ERROR [44000] CHECK OPTION: setting is_active = false would move the row out of the view'
UPDATE review2.v_active_alert_rules SET is_active = false WHERE rule_id = 4;
\echo '<<< actual SQLSTATE:' :SQLSTATE
ROLLBACK TO SAVEPOINT before_check_option;
\echo '>>> EXPECTED ERROR [55000] V2 is aggregated, so it is not updatable'
UPDATE review2.v_instrument_activity SET ticks = 0 WHERE symbol = 'TCS';
\echo '<<< actual SQLSTATE:' :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK;

\echo '===== After ROLLBACK: rule 4 cooldown is back to its seed value 0 ====='
SELECT rule_id, cooldown_seconds, is_active FROM alert_rules WHERE rule_id = 4;
