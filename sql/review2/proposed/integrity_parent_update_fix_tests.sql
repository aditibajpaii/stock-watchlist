-- =====================================================================
-- integrity_parent_update_fix_tests.sql  -  regression tests for the
-- PROPOSED fix (integrity_parent_update_fix.sql).
--
-- Runs only on the throwaway database stock_watchlist_review2_fixtest,
-- built by scripts/review2_integrity_fix_test.sh exactly like the Review 2
-- sandbox (00, 01, 03, 06 + replay run r2demo).
--   -v phase=before   the gap, before the fix is applied
--   -v phase=after    the fix applied: what is rejected, what still works
-- Everything runs in one transaction that is ROLLED BACK.
-- =====================================================================
\set ON_ERROR_STOP on
SELECT current_database() = 'stock_watchlist_review2_fixtest' AS in_fixtest \gset
\if :in_fixtest
\else
  \echo 'REFUSING TO RUN: connect to stock_watchlist_review2_fixtest, not' :DBNAME
  DO $$ BEGIN RAISE EXCEPTION 'fix tests run only on stock_watchlist_review2_fixtest'; END $$;
\endif
\if :{?phase}
\else
  \set phase after
\endif
SELECT :'phase' = 'before' AS before_fix \gset
\pset pager off
\pset footer on
\pset null '(null)'
\set ECHO queries

\echo '===== Phase:' :phase '====='
\echo '===== C1. Triggers on the three tables involved (catalog) ====='
SELECT c.relname AS table_name, t.tgname, pg_get_triggerdef(t.oid) AS definition
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
WHERE NOT t.tgisinternal AND c.relname IN ('alert_events', 'alert_rules', 'price_ticks')
ORDER BY c.relname, t.tgname;

\echo '===== C2. ON UPDATE action of every foreign key (a = NO ACTION: no cascading update path) ====='
SELECT conrelid::regclass AS child, conname, confrelid::regclass AS parent, confupdtype
FROM pg_constraint
WHERE contype = 'f' AND connamespace = 'public'::regnamespace
ORDER BY 1, 2;

BEGIN;
CREATE TEMP VIEW mismatched_events AS
SELECT e.event_id, e.rule_id, r.instrument_id AS rule_instrument,
       e.tick_id, t.instrument_id AS tick_instrument
FROM alert_events e
JOIN alert_rules r ON r.rule_id = e.rule_id
JOIN price_ticks t ON t.tick_id = e.tick_id
WHERE r.instrument_id <> t.instrument_id;

\echo 'events whose rule and tick refer to different instruments, at the start (expect 0):'
SELECT count(*) AS mismatched FROM mismatched_events;

-- a rule and a tick that have no alert events (the fix must not depend on events)
SELECT min(r.rule_id) AS idle_rule FROM alert_rules r
WHERE NOT EXISTS (SELECT 1 FROM alert_events e WHERE e.rule_id = r.rule_id) \gset
SELECT min(t.tick_id) AS idle_tick FROM price_ticks t
WHERE NOT EXISTS (SELECT 1 FROM alert_events e WHERE e.tick_id = t.tick_id) \gset
SELECT :idle_rule AS idle_rule, :idle_tick AS idle_tick;
SAVEPOINT start;

\if :before_fix
\echo '===== B1. Before the fix: UPDATE of alert_rules.instrument_id is ACCEPTED ====='
UPDATE alert_rules SET instrument_id = 2 WHERE rule_id = 1
RETURNING rule_id, instrument_id;
SELECT * FROM mismatched_events ORDER BY event_id;
ROLLBACK TO SAVEPOINT start;

\echo '===== B2. Before the fix: UPDATE of price_ticks.instrument_id is ACCEPTED ====='
UPDATE price_ticks SET instrument_id = 2 WHERE tick_id = 6
RETURNING tick_id, instrument_id;
SELECT * FROM mismatched_events ORDER BY event_id;
ROLLBACK TO SAVEPOINT start;

\else
\echo '===== T1. The fix in the catalog: function and its two triggers ====='
SELECT p.proname, pg_get_function_result(p.oid) AS returns
FROM pg_proc p WHERE p.proname = 'forbid_instrument_change';
SELECT c.relname AS table_name, t.tgname, t.tgenabled
FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
WHERE t.tgname LIKE '%instrument_immutable' ORDER BY 1;

\echo '===== PROHIBITED: changing instrument_id on a parent row ====='
\set ON_ERROR_STOP off
\echo '>>> EXPECTED ERROR [23514] T2 rule 1 (has events) moved to instrument 2'
UPDATE alert_rules SET instrument_id = 2 WHERE rule_id = 1;
\echo '<<< actual SQLSTATE:' :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT start;

\set ON_ERROR_STOP off
\echo '>>> EXPECTED ERROR [23514] T3 tick 6 (has an event) moved to instrument 2'
UPDATE price_ticks SET instrument_id = 2 WHERE tick_id = 6;
\echo '<<< actual SQLSTATE:' :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT start;

\set ON_ERROR_STOP off
\echo '>>> EXPECTED ERROR [23514] T4 a rule WITHOUT events is also immutable'
UPDATE alert_rules SET instrument_id = 2 WHERE rule_id = :idle_rule;
\echo '<<< actual SQLSTATE:' :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT start;

\set ON_ERROR_STOP off
\echo '>>> EXPECTED ERROR [23514] T5 a tick WITHOUT events is also immutable'
UPDATE price_ticks SET instrument_id = 2 WHERE tick_id = :idle_tick;
\echo '<<< actual SQLSTATE:' :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT start;

SELECT count(*) AS instrument_1_ticks_before FROM price_ticks WHERE instrument_id = 1;
\set ON_ERROR_STOP off
\echo '>>> EXPECTED ERROR [23514] T6 multi-row UPDATE: the whole statement is rejected'
UPDATE price_ticks SET instrument_id = 2 WHERE instrument_id = 1;
\echo '<<< actual SQLSTATE:' :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT start;
SELECT count(*) AS instrument_1_ticks_after FROM price_ticks WHERE instrument_id = 1;

\echo '===== STILL ALLOWED ====='
\echo 'T7 setting instrument_id to its current value (no change) is allowed:'
WITH u AS (UPDATE price_ticks SET instrument_id = instrument_id WHERE instrument_id = 1 RETURNING 1)
SELECT count(*) AS rows_updated FROM u;
ROLLBACK TO SAVEPOINT start;

\echo 'T8 the API PATCH /alert-rules statement (app/main.py update_alert_rule), unchanged:'
UPDATE alert_rules
   SET is_active        = coalesce(false, is_active),
       cooldown_seconds = coalesce(120, cooldown_seconds)
 WHERE rule_id = 1 RETURNING rule_id, is_active, cooldown_seconds;
ROLLBACK TO SAVEPOINT start;

\echo 'T9 other columns of a tick can still be corrected (trigger fires only on UPDATE OF instrument_id):'
UPDATE price_ticks SET volume = 10 WHERE tick_id = 6 RETURNING tick_id, instrument_id, volume;
ROLLBACK TO SAVEPOINT start;

\echo 'T10 ingest_tick still stores ticks and the alert engine still fires (rule 1: RELIANCE ABOVE 3000):'
SELECT max(observed_at) AS last_obs FROM price_ticks WHERE instrument_id = 1 \gset
SELECT count(*) AS rule1_events_before FROM alert_events WHERE rule_id = 1;
SELECT * FROM ingest_tick('NSE', 'RELIANCE', :'last_obs'::timestamptz + interval '1 day',
                          2999.00, NULL, 'MANUAL', 'fixtest-below');
SELECT * FROM ingest_tick('NSE', 'RELIANCE', :'last_obs'::timestamptz + interval '2 days',
                          3001.00, NULL, 'MANUAL', 'fixtest-above');
SELECT count(*) AS rule1_events_after FROM alert_events WHERE rule_id = 1;
ROLLBACK TO SAVEPOINT start;

\set ON_ERROR_STOP off
\echo '>>> EXPECTED ERROR [23514] T11 the existing check on alert_events still rejects a mismatched event'
UPDATE alert_events SET tick_id = 2 WHERE event_id = 1;
\echo '<<< actual SQLSTATE:' :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT start;

\echo 'T12 deletes are unchanged: deleting rule 1 cascades to its events'
SELECT count(*) AS rule1_events FROM alert_events WHERE rule_id = 1;
DELETE FROM alert_rules WHERE rule_id = 1 RETURNING rule_id;
SELECT count(*) AS rule1_events_after_delete FROM alert_events WHERE rule_id = 1;
ROLLBACK TO SAVEPOINT start;

\set ON_ERROR_STOP off
\echo '>>> EXPECTED ERROR [428C9] T13 the instrument key itself cannot be changed either (identity column)'
UPDATE instruments SET instrument_id = 99 WHERE instrument_id = 1;
\echo '<<< actual SQLSTATE:' :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT start;
\endif

ROLLBACK;
\echo '===== After ROLLBACK (expect 0) ====='
SELECT count(*) AS mismatched
FROM alert_events e
JOIN alert_rules r ON r.rule_id = e.rule_id
JOIN price_ticks t ON t.tick_id = e.tick_id
WHERE r.instrument_id <> t.instrument_id;
