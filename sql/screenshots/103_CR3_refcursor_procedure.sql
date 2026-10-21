\echo '========================================================================'
\echo ' CR3 | Cursor 2: REFCURSOR in a stored procedure (OPEN ... FOR / FETCH / CLOSE)'
\echo '       prints a watchlist report line by line with RAISE NOTICE'
\echo '========================================================================'
\sf reporting.sp_print_watchlist_report
CALL reporting.sp_print_watchlist_report('arjun');
