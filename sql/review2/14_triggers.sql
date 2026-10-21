-- =====================================================================
-- 14_triggers.sql  -  Template: triggers (>= 2); Review 2 checklist: >= 1
--
-- Re-uses the two production triggers (sql/03_functions_triggers.sql);
-- no trigger is added just to raise the count.
--   T1 trg_price_ticks_evaluate_alerts   AFTER INSERT ON price_ticks
--      edge-triggered alert engine (cooldown in market time)
--   T2 trg_alert_events_check_instrument BEFORE INSERT OR UPDATE OF
--      rule_id, tick_id ON alert_events: rule and tick must be for the
--      SAME instrument
-- Every change runs inside a transaction that is ROLLED BACK.
-- =====================================================================
\ir _guard.sql

\echo '===== Triggers on the 7 tables (catalog) ====='
SELECT c.relname AS table_name, t.tgname AS trigger_name,
       pg_get_triggerdef(t.oid) AS definition
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
WHERE NOT t.tgisinternal
  AND c.relnamespace = 'public'::regnamespace
ORDER BY c.relname, t.tgname;

BEGIN;
-- (created inside the transaction, so the ROLLBACK removes it too)
CREATE TEMP VIEW reliance_rule_events AS
SELECT e.event_id, e.rule_id, r.direction, r.threshold, t.price AS tick_price, t.source_event_id
FROM alert_events e
JOIN alert_rules r ON r.rule_id = e.rule_id
JOIN price_ticks t ON t.tick_id = e.tick_id
WHERE r.instrument_id = 1
ORDER BY e.event_id;

\echo '===== T1: alert trigger ====='
\echo 'RELIANCE now: latest price 2788.00 (below arjun ABOVE 3000), last rule-1 alert at replay +400 s, cooldown 300 s'
SELECT * FROM reliance_rule_events;

-- new market time: 5 minutes after the latest RELIANCE tick (+460 s -> +760 s >= 400 + 300)
SELECT max(observed_at) + interval '5 minutes' AS t_new
FROM price_ticks WHERE instrument_id = 1 \gset

\echo 'insert 3010.00 through the official path ingest_tick(): 2788 -> 3010 crosses ABOVE 3000'
SELECT * FROM ingest_tick('NSE', 'RELIANCE', :'t_new'::timestamptz, 3010.00, 500, 'MANUAL', 'r2-trigger-1');
\echo 'the AFTER INSERT trigger recorded exactly one new event (rule 1), inside the same transaction:'
SELECT * FROM reliance_rule_events;

\echo 'insert 3025.00 one second later: the price STAYS above 3000, so no new event (edge-triggered)'
SELECT * FROM ingest_tick('NSE', 'RELIANCE', :'t_new'::timestamptz + interval '1 second', 3025.00, 500, 'MANUAL', 'r2-trigger-2');
SELECT count(*) AS reliance_events_now FROM reliance_rule_events;

\echo '===== T2: integrity trigger (rule and tick must be the same instrument) ====='
\set ON_ERROR_STOP off
SAVEPOINT before_t2;
\echo '>>> EXPECTED ERROR [23514] rule 1 is for RELIANCE, tick 2 is a TCS tick'
INSERT INTO alert_events (rule_id, tick_id) VALUES (1, 2);
\echo '<<< actual SQLSTATE:' :SQLSTATE
ROLLBACK TO SAVEPOINT before_t2;
\set ON_ERROR_STOP on
\echo 'a matching pair is accepted by the same trigger (rule 1 + RELIANCE tick 8):'
INSERT INTO alert_events (rule_id, tick_id) VALUES (1, 8)
RETURNING event_id, rule_id, tick_id;

ROLLBACK;

\echo '===== After ROLLBACK: the trigger effects disappeared together with the ticks ====='
SELECT (SELECT count(*) FROM price_ticks)  AS price_ticks,
       (SELECT count(*) FROM alert_events) AS alert_events;
