-- =====================================================================
-- 22_integrity_scope.sql  -  How far does the database enforce the rule
-- "an alert event's rule and tick refer to the SAME instrument"?
-- (Question raised by the team's reading guide: are later instrument_id
--  edits on the PARENT rows blocked?)
-- Everything runs in one transaction that is ROLLED BACK.
-- =====================================================================
\ir _guard.sql

\echo '===== Triggers on the three tables involved (catalog) ====='
SELECT c.relname AS table_name, t.tgname, pg_get_triggerdef(t.oid) AS definition
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
WHERE NOT t.tgisinternal AND c.relname IN ('alert_events', 'alert_rules', 'price_ticks')
ORDER BY c.relname;

BEGIN;
CREATE TEMP VIEW mismatched_events AS
SELECT e.event_id, e.rule_id, r.instrument_id AS rule_instrument,
       e.tick_id, t.instrument_id AS tick_instrument
FROM alert_events e
JOIN alert_rules r ON r.rule_id = e.rule_id
JOIN price_ticks t ON t.tick_id = e.tick_id
WHERE r.instrument_id <> t.instrument_id;

\echo 'events whose rule and tick refer to different instruments, before (expect 0):'
SELECT count(*) AS mismatched FROM mismatched_events;
SAVEPOINT start;

\echo '===== 1. Through alert_events: the trigger rejects the breach ====='
\set ON_ERROR_STOP off
\echo '>>> EXPECTED ERROR [23514] move event 1 (rule 1 = RELIANCE) onto tick 2 (TCS)'
UPDATE alert_events SET tick_id = 2 WHERE event_id = 1;
\echo '<<< actual SQLSTATE:' :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT start;

\echo '===== 2. Through the PARENT alert_rules: UPDATE of instrument_id is accepted ====='
UPDATE alert_rules SET instrument_id = 2 WHERE rule_id = 1
RETURNING rule_id, instrument_id;
SELECT * FROM mismatched_events ORDER BY event_id;
ROLLBACK TO SAVEPOINT start;

\echo '===== 3. Through the PARENT price_ticks: UPDATE of instrument_id is accepted ====='
UPDATE price_ticks SET instrument_id = 2 WHERE tick_id = 6
RETURNING tick_id, instrument_id;
SELECT * FROM mismatched_events ORDER BY event_id;

ROLLBACK;
\echo '===== After ROLLBACK (expect 0) ====='
SELECT count(*) AS mismatched
FROM alert_events e
JOIN alert_rules r ON r.rule_id = e.rule_id
JOIN price_ticks t ON t.tick_id = e.tick_id
WHERE r.instrument_id <> t.instrument_id;
