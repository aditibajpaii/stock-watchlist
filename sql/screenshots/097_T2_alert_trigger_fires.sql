BEGIN;
INSERT INTO alert_rules (user_id, instrument_id, direction, threshold) VALUES (1, 4, 'ABOVE', 1700) RETURNING rule_id;

SELECT * FROM ingest_tick('NSE', 'HDFCBANK', now(), 1690, NULL, 'MANUAL', 't2-1');
SELECT * FROM ingest_tick('NSE', 'HDFCBANK', now() + interval '10 seconds', 1710, NULL, 'MANUAL', 't2-2');
SELECT * FROM ingest_tick('NSE', 'HDFCBANK', now() + interval '20 seconds', 1720, NULL, 'MANUAL', 't2-3');

SELECT e.event_id, e.rule_id, e.tick_id, t.price
FROM alert_events e
JOIN price_ticks t ON t.tick_id = e.tick_id
WHERE t.instrument_id = 4;
ROLLBACK;
