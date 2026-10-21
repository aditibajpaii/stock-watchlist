\echo '========================================================================'
\echo ' V1 | View joining 4 tables: reporting.v_watchlist_contents'
\echo '      Purpose: one simple name for ''who watches what'' (hides the joins)'
\echo '========================================================================'
\sv reporting.v_watchlist_contents
SELECT username, watchlist_name, exchange, symbol
FROM reporting.v_watchlist_contents
WHERE username = 'priya'
ORDER BY watchlist_name, symbol;
