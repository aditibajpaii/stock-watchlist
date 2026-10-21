CALL reporting.sp_create_watchlist('priya', 'Banking', 'NSE', ARRAY['HDFCBANK', 'NOSUCH']);
SELECT count(*) FROM watchlists WHERE name = 'Banking';

BEGIN;
CALL reporting.sp_create_watchlist('priya', 'Banking', 'NSE', ARRAY['HDFCBANK', 'RELIANCE']);
SELECT username, watchlist_name, symbol FROM reporting.v_watchlist_contents WHERE watchlist_name = 'Banking';
ROLLBACK;
