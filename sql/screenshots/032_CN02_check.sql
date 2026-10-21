\echo '========================================================================'
\echo ' CN02 | CHECK constraints reject invalid values'
\echo '========================================================================'
SELECT * FROM ingest_tick('NSE', 'TCS', now(), -5, NULL, 'MANUAL', 'manual:negative-price');
SELECT * FROM ingest_tick('NSE', 'TCS', now(), 3500, -1, 'MANUAL', 'manual:negative-volume');
INSERT INTO alert_rules (user_id, instrument_id, direction, threshold)
VALUES (1, 2, 'SIDEWAYS', 3500);
INSERT INTO alert_rules (user_id, instrument_id, direction, threshold, cooldown_seconds)
VALUES (1, 2, 'ABOVE', 3600, -10);
INSERT INTO users (username, email) VALUES ('Bad Name!', 'bad@example.com');
INSERT INTO users (username, email) VALUES ('meera', 'MEERA@EXAMPLE.COM');
