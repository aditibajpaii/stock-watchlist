\echo '========================================================================'
\echo ' B5 | Aggregate: GROUP BY + HAVING'
\echo '      Q: Which watchlists contain at least 3 instruments?'
\echo '========================================================================'
SELECT u.username, w.name AS watchlist, count(wi.instrument_id) AS instruments
FROM watchlists w
JOIN users u            ON u.user_id = w.user_id
JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
GROUP BY u.username, w.name
HAVING count(wi.instrument_id) >= 3
ORDER BY instruments DESC, u.username;
