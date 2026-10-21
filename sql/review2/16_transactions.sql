-- =====================================================================
-- 16_transactions.sql  -  Review 2 checklist item 5:
--   BEGIN, COMMIT, ROLLBACK, SAVEPOINT, ROLLBACK TO SAVEPOINT
--
-- Only a disposable user "txn_demo" and its watchlists are changed; seed
-- users, watchlists and ticks are never modified. The last step deletes
-- txn_demo, so the sandbox ends with the row counts it started with.
-- Isolation between two concurrent sessions (the instrument row lock in
-- ingest_tick) is demonstrated separately by tests/concurrency_test.sh.
-- =====================================================================
\ir _guard.sql

CREATE TEMP VIEW txn_state AS
SELECT u.username, w.name AS watchlist
FROM users u
LEFT JOIN watchlists w ON w.user_id = u.user_id
WHERE u.username = 'txn_demo'
ORDER BY w.name;

\echo '===== Start: no txn_demo user yet ====='
SELECT count(*) AS txn_demo_users FROM users WHERE username = 'txn_demo';

\echo '===== T1. BEGIN ... COMMIT: the change becomes permanent ====='
BEGIN;
INSERT INTO users (username, email)
VALUES ('txn_demo', 'txn_demo@example.com')
RETURNING user_id, username;
\echo 'inside the transaction this session already sees its own uncommitted row:'
SELECT * FROM txn_state;
COMMIT;
\echo 'after COMMIT:'
SELECT * FROM txn_state;

\echo '===== T2. BEGIN ... ROLLBACK: the change is undone ====='
BEGIN;
INSERT INTO watchlists (user_id, name)
SELECT user_id, 'Scratch' FROM users WHERE username = 'txn_demo'
RETURNING watchlist_id, name;
SELECT * FROM txn_state;
ROLLBACK;
\echo 'after ROLLBACK the Scratch watchlist never existed:'
SELECT * FROM txn_state;

\echo '===== T3. SAVEPOINT and ROLLBACK TO SAVEPOINT: undo only part of a transaction ====='
BEGIN;
INSERT INTO watchlists (user_id, name)
SELECT user_id, 'Txn Main' FROM users WHERE username = 'txn_demo';
SAVEPOINT after_main;
\set ON_ERROR_STOP off
\echo '>>> EXPECTED ERROR [23505] a second "Txn Main" for the same user breaks UNIQUE(user_id, name)'
INSERT INTO watchlists (user_id, name)
SELECT user_id, 'Txn Main' FROM users WHERE username = 'txn_demo';
\echo '<<< actual SQLSTATE:' :SQLSTATE
\echo '>>> EXPECTED ERROR [25P02] after an error the transaction is aborted: every statement fails until a rollback'
SELECT * FROM txn_state;
\echo '<<< actual SQLSTATE:' :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT after_main;
\echo 'after ROLLBACK TO SAVEPOINT the work done before the savepoint is kept and the transaction continues:'
INSERT INTO watchlists (user_id, name)
SELECT user_id, 'Txn Second' FROM users WHERE username = 'txn_demo';
SELECT * FROM txn_state;
COMMIT;
\echo 'after COMMIT: Txn Main and Txn Second are stored; the failed duplicate is not'
SELECT * FROM txn_state;

\echo '===== T4. Atomicity with the alert engine: a tick and the alert its trigger creates are one unit ====='
SELECT count(*) AS ticks_before FROM price_ticks \gset
SELECT count(*) AS events_before FROM alert_events \gset
SELECT max(observed_at) + interval '5 minutes' AS t_new
FROM price_ticks WHERE instrument_id = 1 \gset
BEGIN;
\echo 'RELIANCE 2788 -> 3010 crosses arjun ABOVE 3000 (cooldown already over):'
SELECT * FROM ingest_tick('NSE', 'RELIANCE', :'t_new'::timestamptz, 3010.00, 500, 'MANUAL', 'r2-txn-1');
SELECT (SELECT count(*) FROM price_ticks)  - :ticks_before  AS new_ticks,
       (SELECT count(*) FROM alert_events) - :events_before AS new_alert_events;
ROLLBACK;
\echo 'after ROLLBACK the tick AND the alert created by its trigger are both gone:'
SELECT (SELECT count(*) FROM price_ticks)  - :ticks_before  AS new_ticks,
       (SELECT count(*) FROM alert_events) - :events_before AS new_alert_events;

\echo '===== T5. A NEW connection sees exactly the committed data ====='
\connect
SELECT u.username, w.name AS watchlist
FROM users u
JOIN watchlists w ON w.user_id = u.user_id
WHERE u.username = 'txn_demo'
ORDER BY w.name;

\echo '===== Clean-up: delete txn_demo (ON DELETE CASCADE removes its watchlists) ====='
DELETE FROM users WHERE username = 'txn_demo' RETURNING user_id, username;
SELECT (SELECT count(*) FROM users)        AS users,
       (SELECT count(*) FROM watchlists)   AS watchlists,
       (SELECT count(*) FROM price_ticks)  AS price_ticks,
       (SELECT count(*) FROM alert_events) AS alert_events;
