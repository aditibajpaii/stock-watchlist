-- =====================================================================
-- 05_demo_queries.sql
-- Screenshot-friendly demonstration of the Phase 4 alert engine on the
-- SEED data (arjun's rules: rule 1 = RELIANCE ABOVE 3000, cooldown 300 s;
-- rule 2 = RELIANCE BELOW 2800).
--
-- Everything runs in ONE transaction that is ROLLED BACK at the end:
-- safe to run any number of times; the database is unchanged afterwards.
--
-- Run:  psql -d stock_watchlist -f sql/05_demo_queries.sql
-- Market time used: 2026-01-05 09:15 IST onwards (fixed, reproducible).
-- =====================================================================

\pset footer off
\set QUIET on
BEGIN;

-- event view used by every step
CREATE TEMP VIEW demo_events AS
SELECT e.event_id, u.username, i.symbol, r.direction, r.threshold::NUMERIC(12,2) AS threshold,
       t.price::NUMERIC(12,2) AS tick_price, t.observed_at, t.source_event_id
FROM alert_events e
JOIN alert_rules  r ON r.rule_id = e.rule_id
JOIN users        u ON u.user_id = r.user_id
JOIN price_ticks  t ON t.tick_id = e.tick_id
JOIN instruments  i ON i.instrument_id = t.instrument_id
ORDER BY t.observed_at, e.event_id;

\echo
\echo '================ DEMO 1: first tick, then an ABOVE crossing ================'
\echo '-- 2990 (first tick: no previous price, no alert)'
SELECT * FROM ingest_tick('NSE','RELIANCE','2026-01-05 09:15:00+05:30', 2990, 100, 'MANUAL', 'demo:1');
\echo '-- 3005 (2990 -> 3005 crosses ABOVE 3000)'
SELECT * FROM ingest_tick('NSE','RELIANCE','2026-01-05 09:15:01+05:30', 3005, 100, 'MANUAL', 'demo:2');
SELECT * FROM demo_events;

\echo
\echo '================ DEMO 2: staying above -> no repeated alert ================'
SELECT * FROM ingest_tick('NSE','RELIANCE','2026-01-05 09:15:02+05:30', 3010, 100, 'MANUAL', 'demo:3');
SELECT * FROM ingest_tick('NSE','RELIANCE','2026-01-05 09:15:03+05:30', 3020, 100, 'MANUAL', 'demo:4');
\echo '-- still exactly one event:'
SELECT * FROM demo_events;

\echo
\echo '================ DEMO 3: cooldown (rule 1 cooldown = 300 s) ================'
\echo '-- drop to 2990 at 09:15:10, re-cross to 3005 at 09:15:20 (19 s after the last alert)'
SELECT * FROM ingest_tick('NSE','RELIANCE','2026-01-05 09:15:10+05:30', 2990, 100, 'MANUAL', 'demo:5');
SELECT * FROM ingest_tick('NSE','RELIANCE','2026-01-05 09:15:20+05:30', 3005, 100, 'MANUAL', 'demo:6');
\echo '-- crossing suppressed by cooldown: still one event'
SELECT * FROM demo_events;
\echo '-- drop again, re-cross at 09:20:30 (329 s after the last alert, > 300 s)'
SELECT * FROM ingest_tick('NSE','RELIANCE','2026-01-05 09:20:00+05:30', 2990, 100, 'MANUAL', 'demo:7');
SELECT * FROM ingest_tick('NSE','RELIANCE','2026-01-05 09:20:30+05:30', 3005, 100, 'MANUAL', 'demo:8');
\echo '-- fires again: two events'
SELECT * FROM demo_events;

\echo
\echo '================ DEMO 4: duplicate input ================'
\echo '-- re-send source event demo:8'
SELECT * FROM ingest_tick('NSE','RELIANCE','2026-01-05 09:20:30+05:30', 3005, 100, 'MANUAL', 'demo:8');
SELECT count(*) AS ticks_with_id_demo_8 FROM price_ticks WHERE source_event_id = 'demo:8';
SELECT count(*) AS total_events FROM alert_events;

\echo
\echo '================ DEMO 5: late tick is stored but ignored ================'
\echo '-- a tick from 09:14:00 (earlier than existing ticks) at 2700 = below 2800'
SELECT * FROM ingest_tick('NSE','RELIANCE','2026-01-05 09:14:00+05:30', 2700, 100, 'MANUAL', 'demo:late');
SELECT tick_id, observed_at, price::NUMERIC(12,2), source_event_id, ingested_at
FROM price_ticks ORDER BY observed_at, tick_id;
\echo '-- no BELOW event was created by the late tick:'
SELECT * FROM demo_events;

\echo
\echo '================ DEMO 6: integrity trigger ================'
\echo '-- try to pair RELIANCE rule 1 with a BTCUSDT tick by hand'
SELECT * FROM ingest_tick('BINANCE','BTCUSDT','2026-01-05 09:15:00+05:30', 99000, 1, 'MANUAL', 'demo:btc');
SAVEPOINT before_bad_insert;
\set ON_ERROR_STOP off
INSERT INTO alert_events (rule_id, tick_id)
SELECT 1, tick_id FROM price_ticks WHERE source_event_id = 'demo:btc';
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT before_bad_insert;

\echo
\echo '================ DEMO 7: rollback ================'
SELECT count(*) AS ticks_inside_transaction  FROM price_ticks;
SELECT count(*) AS events_inside_transaction FROM alert_events;
ROLLBACK;
\echo '-- after ROLLBACK:'
SELECT count(*) AS ticks_after_rollback  FROM price_ticks;
SELECT count(*) AS events_after_rollback FROM alert_events;
