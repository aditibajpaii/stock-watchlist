\echo '========================================================================'
\echo ' P2 | Stored procedure reporting.sp_create_watchlist (atomic: all or nothing)'
\echo '      1) an unknown symbol -> exception -> nothing is created'
\echo '      2) a valid call inside a transaction (rolled back afterwards)'
\echo '========================================================================'
CALL reporting.sp_create_watchlist('priya', 'Banking', 'NSE', ARRAY['HDFCBANK', 'NOSUCH']);
SELECT count(*) AS banking_lists FROM watchlists WHERE name = 'Banking';

BEGIN;
CALL reporting.sp_create_watchlist('priya', 'Banking', 'NSE', ARRAY['HDFCBANK', 'RELIANCE']);
SELECT username, watchlist_name, symbol FROM reporting.v_watchlist_contents
WHERE watchlist_name = 'Banking' ORDER BY symbol;
ROLLBACK;
