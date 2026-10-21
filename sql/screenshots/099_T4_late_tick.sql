\echo '========================================================================'
\echo ' T4 | Trigger logic: a LATE (out-of-order) tick is stored but not evaluated'
\echo '      rule HDFCBANK BELOW 1600. Tick at +60s = 1650, then a tick stamped +30s'
\echo '      (earlier!) at 1590 arrives late -> stored, but no BELOW alert. Rolled back.'
\echo '========================================================================'
BEGIN;
INSERT INTO alert_rules (user_id, instrument_id, direction, threshold, cooldown_seconds)
VALUES (2, 4, 'BELOW', 1600, 0);

SELECT * FROM ingest_tick('NSE', 'HDFCBANK', now() + interval '60 seconds', 1650, NULL, 'MANUAL', 'ss-t4:a');
SELECT * FROM ingest_tick('NSE', 'HDFCBANK', now() + interval '30 seconds', 1590, NULL, 'MANUAL', 'ss-t4:late');

SELECT tick_id, price::numeric(12,2), source_event_id, observed_at::time(0)
FROM price_ticks WHERE instrument_id = 4 ORDER BY observed_at;
SELECT count(*) AS hdfcbank_alerts
FROM alert_events e JOIN price_ticks t ON t.tick_id = e.tick_id WHERE t.instrument_id = 4;
ROLLBACK;
