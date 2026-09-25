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
-- Market time: T0 = 10 minutes after the later of now() and the latest
-- stored RELIANCE/BTCUSDT tick, so the demo also works after a replay
-- (no demo tick is "late", and rule 1's 300 s cooldown has expired).
-- The event view shows only events created by this demo.
-- =====================================================================

\pset footer off
\set QUIET on
BEGIN;

SELECT date_trunc('minute', greatest(now(), max(t.observed_at))) + interval '10 minutes' AS t0
FROM price_ticks t JOIN instruments i USING (instrument_id)
WHERE i.symbol IN ('RELIANCE', 'BTCUSDT') \gset
SELECT count(*) AS ticks_before FROM price_ticks \gset
SELECT count(*) AS events_before FROM alert_events \gset
\echo 'Demo market time T0 =' :t0

-- event view used by every step
CREATE TEMP VIEW demo_events AS
SELECT e.event_id, u.username, i.symbol, r.direction, r.threshold::NUMERIC(12,2) AS threshold,
       t.price::NUMERIC(12,2) AS tick_price, t.observed_at, t.source_event_id
FROM alert_events e
JOIN alert_rules  r ON r.rule_id = e.rule_id
JOIN users        u ON u.user_id = r.user_id
JOIN price_ticks  t ON t.tick_id = e.tick_id
JOIN instruments  i ON i.instrument_id = t.instrument_id
WHERE t.observed_at >= :'t0'::timestamptz - interval '2 minutes'
ORDER BY t.observed_at, e.event_id;

\echo
\echo '================ DEMO 1: first tick, then an ABOVE crossing ================'
\echo '-- 2990 (below 3000: no ABOVE alert)'
SELECT * FROM ingest_tick('NSE','RELIANCE',(:'t0'::timestamptz + interval '0 s'), 2990, 100, 'MANUAL', 'demo:1');
\echo '-- 3005 (2990 -> 3005 crosses ABOVE 3000)'
SELECT * FROM ingest_tick('NSE','RELIANCE',(:'t0'::timestamptz + interval '1 s'), 3005, 100, 'MANUAL', 'demo:2');
SELECT * FROM demo_events;

\echo
\echo '================ DEMO 2: staying above -> no repeated alert ================'
SELECT * FROM ingest_tick('NSE','RELIANCE',(:'t0'::timestamptz + interval '2 s'), 3010, 100, 'MANUAL', 'demo:3');
SELECT * FROM ingest_tick('NSE','RELIANCE',(:'t0'::timestamptz + interval '3 s'), 3020, 100, 'MANUAL', 'demo:4');
\echo '-- still exactly one event:'
SELECT * FROM demo_events;

\echo
\echo '================ DEMO 3: cooldown (rule 1 cooldown = 300 s) ================'
\echo '-- drop to 2990 at T0+10 s, re-cross to 3005 at T0+20 s (19 s after the last alert)'
SELECT * FROM ingest_tick('NSE','RELIANCE',(:'t0'::timestamptz + interval '10 s'), 2990, 100, 'MANUAL', 'demo:5');
SELECT * FROM ingest_tick('NSE','RELIANCE',(:'t0'::timestamptz + interval '20 s'), 3005, 100, 'MANUAL', 'demo:6');
\echo '-- crossing suppressed by cooldown: still one event'
SELECT * FROM demo_events;
\echo '-- drop again, re-cross at T0+330 s (329 s after the last alert, > 300 s)'
SELECT * FROM ingest_tick('NSE','RELIANCE',(:'t0'::timestamptz + interval '300 s'), 2990, 100, 'MANUAL', 'demo:7');
SELECT * FROM ingest_tick('NSE','RELIANCE',(:'t0'::timestamptz + interval '330 s'), 3005, 100, 'MANUAL', 'demo:8');
\echo '-- fires again: two events'
SELECT * FROM demo_events;

\echo
\echo '================ DEMO 4: duplicate input ================'
\echo '-- re-send source event demo:8'
SELECT * FROM ingest_tick('NSE','RELIANCE',(:'t0'::timestamptz + interval '330 s'), 3005, 100, 'MANUAL', 'demo:8');
SELECT count(*) AS ticks_with_id_demo_8 FROM price_ticks WHERE source_event_id = 'demo:8';
SELECT count(*) AS demo_events FROM demo_events;

\echo
\echo '================ DEMO 5: late tick is stored but ignored ================'
\echo '-- a tick from T0-60 s (earlier than the demo ticks) at 2700 = below 2800'
SELECT * FROM ingest_tick('NSE','RELIANCE',(:'t0'::timestamptz + interval '-60 s'), 2700, 100, 'MANUAL', 'demo:late');
SELECT tick_id, observed_at, price::NUMERIC(12,2), source_event_id, ingested_at
FROM price_ticks
WHERE source = 'MANUAL' AND observed_at >= :'t0'::timestamptz - interval '2 minutes'
ORDER BY observed_at, tick_id;
\echo '-- no BELOW event was created by the late tick:'
SELECT * FROM demo_events;

\echo
\echo '================ DEMO 6: integrity trigger ================'
\echo '-- try to pair RELIANCE rule 1 with a BTCUSDT tick by hand'
SELECT * FROM ingest_tick('BINANCE','BTCUSDT',(:'t0'::timestamptz + interval '0 s'), 99000, 1, 'MANUAL', 'demo:btc');
SAVEPOINT before_bad_insert;
\set ON_ERROR_STOP off
INSERT INTO alert_events (rule_id, tick_id)
SELECT 1, tick_id FROM price_ticks WHERE source_event_id = 'demo:btc';
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT before_bad_insert;

\echo
\echo '================ DEMO 7: rollback ================'
SELECT count(*) - :ticks_before  AS ticks_added_inside_transaction  FROM price_ticks;
SELECT count(*) - :events_before AS events_added_inside_transaction FROM alert_events;
ROLLBACK;
\echo '-- after ROLLBACK (compared with before the demo):'
SELECT count(*) - :ticks_before  AS ticks_added_after_rollback  FROM price_ticks;
SELECT count(*) - :events_before AS events_added_after_rollback FROM alert_events;
