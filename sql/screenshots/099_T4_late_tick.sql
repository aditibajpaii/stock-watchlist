BEGIN;
INSERT INTO alert_rules (user_id, instrument_id, direction, threshold, cooldown_seconds) VALUES (2, 4, 'BELOW', 1600, 0);

SELECT * FROM ingest_tick('NSE', 'HDFCBANK', now() + interval '60 seconds', 1650, NULL, 'MANUAL', 't4-1');
SELECT * FROM ingest_tick('NSE', 'HDFCBANK', now() + interval '30 seconds', 1590, NULL, 'MANUAL', 't4-2');

SELECT tick_id, price, source_event_id, observed_at FROM price_ticks WHERE instrument_id = 4;
SELECT count(*) FROM alert_events e JOIN price_ticks t ON t.tick_id = e.tick_id WHERE t.instrument_id = 4;
ROLLBACK;
