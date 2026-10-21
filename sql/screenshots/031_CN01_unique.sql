\echo '========================================================================'
\echo ' CN01 | UNIQUE constraints reject duplicates'
\echo '========================================================================'
INSERT INTO users (username, email) VALUES ('arjun', 'arjun2@example.com');
INSERT INTO watchlists (user_id, name) VALUES (1, 'Crypto');
INSERT INTO alert_rules (user_id, instrument_id, direction, threshold)
VALUES (1, 1, 'ABOVE', 3000);
