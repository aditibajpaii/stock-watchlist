-- =====================================================================
-- 21_fired_at_analysis.sql  -  Is tick_id -> fired_at guaranteed?
-- Evidence for docs/review2/NORMALIZATION_PROOF.md section 9.
--
--   A  catalog facts: defaults, the only INSERT into alert_events in the
--      trigger code, triggers on alert_events, who may write directly
--   B  the application path (ingest_tick -> trigger): two rules firing on
--      one tick, and two ticks ingested in one transaction
--   C  writes the SCHEMA accepts that break tick_id -> fired_at
-- Everything in B and C runs in one transaction that is ROLLED BACK.
-- =====================================================================
\ir _guard.sql

\echo '===== A1. Defaults: both timestamps come from now() = start time of the current transaction ====='
SELECT table_name, column_name, column_default, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND column_name IN ('fired_at', 'ingested_at')
ORDER BY table_name;

\echo '===== A2. Every line of the alert trigger function that mentions alert_events or fired_at ====='
SELECT n AS line, btrim(l) AS text
FROM regexp_split_to_table(pg_get_functiondef('public.evaluate_price_alerts()'::regprocedure), E'\n')
     WITH ORDINALITY AS f(l, n)
WHERE l ~* 'alert_events|fired_at'
ORDER BY n;

\echo '===== A3. Triggers on alert_events: none fires on a change of fired_at ====='
SELECT t.tgname, pg_get_triggerdef(t.oid) AS definition
FROM pg_trigger t
WHERE t.tgrelid = 'public.alert_events'::regclass AND NOT t.tgisinternal;

\echo '===== A4. Roles that may write alert_events directly in this database ====='
SELECT r.rolname, r.rolsuper, r.rolcanlogin,
       has_table_privilege(r.rolname, 'public.alert_events', 'INSERT') AS can_insert,
       has_table_privilege(r.rolname, 'public.alert_events', 'UPDATE') AS can_update
FROM pg_roles r
WHERE r.rolname = current_user OR r.rolname LIKE 'r2\_%'
ORDER BY r.rolsuper DESC, r.rolname;

BEGIN;
SELECT max(observed_at) + interval '5 minutes' AS t_rel FROM price_ticks WHERE instrument_id = 1 \gset
SELECT max(observed_at) + interval '5 minutes' AS t_tcs FROM price_ticks WHERE instrument_id = 2 \gset

\echo '===== B1. Application path: ONE tick that fires TWO rules ====='
\echo 'temporary second rule: priya, RELIANCE ABOVE 3005 (rolled back at the end)'
INSERT INTO alert_rules (user_id, instrument_id, direction, threshold, cooldown_seconds)
SELECT user_id, 1, 'ABOVE', 3005, 0 FROM users WHERE username = 'priya'
RETURNING rule_id, direction, threshold;
\echo 'RELIANCE 2788 -> 3010 crosses ABOVE 3000 (arjun) and ABOVE 3005 (priya):'
SELECT * FROM ingest_tick('NSE', 'RELIANCE', :'t_rel'::timestamptz, 3010.00, 100, 'MANUAL', 'r2-fired-1');
SELECT e.event_id, e.rule_id, e.tick_id, e.fired_at, t.ingested_at,
       e.fired_at = t.ingested_at AS fired_at_equals_ingested_at
FROM alert_events e JOIN price_ticks t ON t.tick_id = e.tick_id
WHERE t.source_event_id = 'r2-fired-1'
ORDER BY e.event_id;

\echo '===== B2. Application path: a second tick (TCS) ingested in the SAME transaction ====='
SELECT * FROM ingest_tick('NSE', 'TCS', :'t_tcs'::timestamptz, 3510.00, 100, 'MANUAL', 'r2-fired-2');
SELECT * FROM ingest_tick('NSE', 'TCS', :'t_tcs'::timestamptz + interval '1 second', 3480.00, 100, 'MANUAL', 'r2-fired-3');
\echo 'events created in this transaction: different ticks, yet one shared fired_at (transaction start time)'
SELECT e.event_id, e.rule_id, e.tick_id, t.source_event_id, e.fired_at
FROM alert_events e JOIN price_ticks t ON t.tick_id = e.tick_id
WHERE t.source_event_id LIKE 'r2-fired-%'
ORDER BY e.event_id;
SELECT count(DISTINCT e.tick_id) AS ticks, count(DISTINCT e.fired_at) AS distinct_fired_at
FROM alert_events e JOIN price_ticks t ON t.tick_id = e.tick_id
WHERE t.source_event_id LIKE 'r2-fired-%';

\echo '===== B3. On everything the application path produced so far: ticks with more than one fired_at (expect 0) ====='
SELECT count(*) AS ticks_with_several_fired_at
FROM (SELECT tick_id FROM alert_events GROUP BY tick_id HAVING count(DISTINCT fired_at) > 1) AS x;

\echo '===== C1. Accepted by the schema: a hand-written event for tick 6 with an explicit fired_at ====='
INSERT INTO alert_events (rule_id, tick_id, fired_at)
VALUES (2, 6, '2026-01-01 09:15:00+05:30')
RETURNING event_id, rule_id, tick_id, fired_at;
SELECT e.event_id, e.rule_id, e.tick_id, e.fired_at
FROM alert_events e WHERE e.tick_id = 6 ORDER BY e.event_id;

\echo '===== C2. Accepted by the schema: UPDATE of fired_at (no trigger or CHECK watches it) ====='
UPDATE alert_events SET fired_at = fired_at + interval '1 hour' WHERE event_id = 1
RETURNING event_id, tick_id, fired_at;

\echo '===== C3. Now the dependency tick_id -> fired_at is broken in a state the schema accepted ====='
SELECT tick_id, count(*) AS events, count(DISTINCT fired_at) AS distinct_fired_at
FROM alert_events
GROUP BY tick_id
HAVING count(DISTINCT fired_at) > 1
ORDER BY tick_id;

ROLLBACK;

\echo '===== After ROLLBACK: the committed replay data again satisfy fired_at = ingested_at ====='
SELECT count(*) AS alert_events,
       count(*) FILTER (WHERE e.fired_at = t.ingested_at) AS fired_at_equals_ingested_at
FROM alert_events e JOIN price_ticks t ON t.tick_id = e.tick_id;
