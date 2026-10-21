BEGIN;
INSERT INTO alert_rules (user_id, instrument_id, direction, threshold, cooldown_seconds) VALUES (1, 4, 'ABOVE', 1700, 300);

SELECT * FROM ingest_tick('NSE', 'HDFCBANK', now(), 1690, NULL, 'MANUAL', 't3-1');
SELECT * FROM ingest_tick('NSE', 'HDFCBANK', now() + interval '10 seconds', 1710, NULL, 'MANUAL', 't3-2');
SELECT * FROM ingest_tick('NSE', 'HDFCBANK', now() + interval '20 seconds', 1690, NULL, 'MANUAL', 't3-3');
SELECT * FROM ingest_tick('NSE', 'HDFCBANK', now() + interval '30 seconds', 1710, NULL, 'MANUAL', 't3-4');
SELECT * FROM ingest_tick('NSE', 'HDFCBANK', now() + interval '400 seconds', 1690, NULL, 'MANUAL', 't3-5');
SELECT * FROM ingest_tick('NSE', 'HDFCBANK', now() + interval '410 seconds', 1710, NULL, 'MANUAL', 't3-6');

SELECT e.event_id, t.source_event_id, t.price
FROM alert_events e
JOIN price_ticks t ON t.tick_id = e.tick_id
WHERE t.instrument_id = 4;
ROLLBACK;
