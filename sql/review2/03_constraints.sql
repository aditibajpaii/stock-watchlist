-- =====================================================================
-- 03_constraints.sql  -  Tables & constraints evidence (Review 1 criterion
-- "Table creation with description and screenshot", Review 2 item 1).
--
-- Shows, from the catalog, the four composite alternate keys, then tries
-- to break every kind of constraint. Each failing statement is announced
-- with ">>> EXPECTED ERROR [SQLSTATE]" and confirmed by the SQLSTATE psql
-- actually received. Everything runs in one transaction that is ROLLED
-- BACK, so the sandbox is unchanged afterwards.
--
-- ON_ERROR_ROLLBACK on: psql sets an automatic savepoint before each
-- statement, so one failed statement does not abort the whole
-- transaction (16_transactions.sql shows explicit SAVEPOINTs instead).
-- =====================================================================
\ir _guard.sql

\echo '===== The composite / alternate keys, read from pg_constraint ====='
SELECT conrelid::regclass AS table_name, conname AS constraint_name,
       pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conname IN ('uq_instruments_exchange_symbol', 'uq_watchlists_user_name',
                  'uq_price_ticks_source_event', 'uq_alert_events_rule_tick',
                  'pk_watchlist_items')
ORDER BY conrelid::regclass::text;

BEGIN;
\set ON_ERROR_ROLLBACK on
\set ON_ERROR_STOP off

\echo '===== UNIQUE (exchange, symbol) on instruments ====='
\echo '>>> EXPECTED ERROR [23505] same exchange + same symbol'
INSERT INTO instruments (exchange, symbol, name, quote_currency)
VALUES ('NSE', 'RELIANCE', 'Duplicate listing', 'INR');
\echo '<<< actual SQLSTATE:' :SQLSTATE
\echo 'allowed: the same symbol on a DIFFERENT exchange (the key is the pair, not symbol alone)'
INSERT INTO instruments (exchange, symbol, name, quote_currency)
VALUES ('BSE', 'RELIANCE', 'Reliance Industries Ltd', 'INR')
RETURNING instrument_id, exchange, symbol;

\echo '===== UNIQUE (user_id, name) on watchlists ====='
\echo '>>> EXPECTED ERROR [23505] arjun already has a watchlist called Crypto'
INSERT INTO watchlists (user_id, name)
SELECT user_id, 'Crypto' FROM users WHERE username = 'arjun';
\echo '<<< actual SQLSTATE:' :SQLSTATE
\echo 'allowed: another user may use the same watchlist name'
INSERT INTO watchlists (user_id, name)
SELECT user_id, 'Crypto' FROM users WHERE username = 'priya'
RETURNING watchlist_id, user_id, name;

\echo '===== UNIQUE (source, instrument_id, source_event_id) on price_ticks ====='
\echo '>>> EXPECTED ERROR [23505] replaying the stored event r2demo:000006 for RELIANCE'
INSERT INTO price_ticks (instrument_id, observed_at, price, volume, source, source_event_id)
SELECT instrument_id, observed_at, price, volume, source, source_event_id
FROM price_ticks WHERE source_event_id = 'r2demo:000006';
\echo '<<< actual SQLSTATE:' :SQLSTATE
\echo 'the official path ingest_tick() turns the same duplicate into status DUPLICATE (ON CONFLICT DO NOTHING)'
SELECT * FROM ingest_tick('NSE', 'RELIANCE',
                          (SELECT observed_at FROM price_ticks WHERE source_event_id = 'r2demo:000006'),
                          3002.40, 1500, 'REPLAY', 'r2demo:000006');

\echo '===== UNIQUE (rule_id, tick_id) on alert_events ====='
\echo '>>> EXPECTED ERROR [23505] rule 1 already fired on tick 6 (event 1)'
INSERT INTO alert_events (rule_id, tick_id) VALUES (1, 6);
\echo '<<< actual SQLSTATE:' :SQLSTATE

\echo '===== Composite PRIMARY KEY (watchlist_id, instrument_id) on watchlist_items ====='
\echo '>>> EXPECTED ERROR [23505] RELIANCE is already in arjun "Long Term"'
INSERT INTO watchlist_items (watchlist_id, instrument_id)
SELECT w.watchlist_id, i.instrument_id
FROM watchlists w JOIN users u ON u.user_id = w.user_id
JOIN instruments i ON i.exchange = 'NSE' AND i.symbol = 'RELIANCE'
WHERE u.username = 'arjun' AND w.name = 'Long Term';
\echo '<<< actual SQLSTATE:' :SQLSTATE

\echo '===== FOREIGN KEY ====='
\echo '>>> EXPECTED ERROR [23503] watchlist for a user_id that does not exist'
INSERT INTO watchlists (user_id, name) VALUES (999, 'Ghost list');
\echo '<<< actual SQLSTATE:' :SQLSTATE

\echo '===== CHECK constraints ====='
\echo '>>> EXPECTED ERROR [23514] ck_price_ticks_price_pos (price must be > 0)'
INSERT INTO price_ticks (instrument_id, observed_at, price, source, source_event_id)
VALUES (1, now(), -5, 'MANUAL', 'check-demo-1');
\echo '<<< actual SQLSTATE:' :SQLSTATE
\echo '>>> EXPECTED ERROR [23514] ck_alert_rules_direction (only ABOVE or BELOW)'
INSERT INTO alert_rules (user_id, instrument_id, direction, threshold)
VALUES (1, 1, 'SIDEWAYS', 3000);
\echo '<<< actual SQLSTATE:' :SQLSTATE
\echo '>>> EXPECTED ERROR [23514] ck_users_username_format (lower-case letters, digits, _)'
INSERT INTO users (username, email) VALUES ('Bad Name!', 'bad@example.com');
\echo '<<< actual SQLSTATE:' :SQLSTATE
\echo '>>> EXPECTED ERROR [23514] ck_alert_rules_cooldown_nonneg (cooldown >= 0)'
UPDATE alert_rules SET cooldown_seconds = -1 WHERE rule_id = 4;
\echo '<<< actual SQLSTATE:' :SQLSTATE

\echo '===== NOT NULL ====='
\echo '>>> EXPECTED ERROR [23502] email is NOT NULL'
INSERT INTO users (username, email) VALUES ('no_email', NULL);
\echo '<<< actual SQLSTATE:' :SQLSTATE
\echo 'allowed: volume is the only nullable business column (NULL = unknown, not zero)'
SELECT column_name, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'price_ticks' AND column_name IN ('price', 'volume')
ORDER BY column_name;

\echo '===== GENERATED ALWAYS AS IDENTITY ====='
\echo '>>> EXPECTED ERROR [428C9] user_id is generated; a client may not supply it'
INSERT INTO users (user_id, username, email) VALUES (99, 'manual_id', 'manual@example.com');
\echo '<<< actual SQLSTATE:' :SQLSTATE

\echo '===== ON DELETE RESTRICT ====='
-- PostgreSQL reports a RESTRICT violation as SQLSTATE 23001
-- (restrict_violation); the default NO ACTION would report 23503.
\echo '>>> EXPECTED ERROR [23001] RELIANCE has price ticks, rules and watchlist items (RESTRICT)'
DELETE FROM instruments WHERE exchange = 'NSE' AND symbol = 'RELIANCE';
\echo '<<< actual SQLSTATE:' :SQLSTATE

\set ON_ERROR_STOP on
ROLLBACK;
\set ON_ERROR_ROLLBACK off

\echo '===== After ROLLBACK: nothing above was kept ====='
SELECT (SELECT count(*) FROM instruments) AS instruments,
       (SELECT count(*) FROM watchlists)  AS watchlists,
       (SELECT count(*) FROM price_ticks) AS price_ticks,
       (SELECT count(*) FROM alert_events) AS alert_events,
       (SELECT count(*) FROM users)       AS users;
