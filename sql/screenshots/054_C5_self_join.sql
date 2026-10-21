\echo '========================================================================'
\echo ' C5 | Join: SELF JOIN (watchlist_items joined to itself)'
\echo '      Q: Which pairs of different users watch the same instrument?'
\echo '========================================================================'
SELECT i.symbol, ua.username AS user_a, ub.username AS user_b
FROM watchlist_items a
JOIN watchlist_items b ON b.instrument_id = a.instrument_id
JOIN watchlists wa     ON wa.watchlist_id = a.watchlist_id
JOIN watchlists wb     ON wb.watchlist_id = b.watchlist_id
JOIN users ua          ON ua.user_id = wa.user_id
JOIN users ub          ON ub.user_id = wb.user_id
JOIN instruments i     ON i.instrument_id = a.instrument_id
WHERE wa.user_id < wb.user_id
ORDER BY i.symbol, user_a, user_b;
