\echo '========================================================================'
\echo ' C1 | Join: INNER JOIN across 4 tables (M:N through watchlist_items)'
\echo '      Q: Which instruments are in each user''s watchlists?'
\echo '========================================================================'
SELECT u.username, w.name AS watchlist, i.exchange, i.symbol
FROM watchlist_items wi
INNER JOIN watchlists w  ON w.watchlist_id = wi.watchlist_id
INNER JOIN users u       ON u.user_id = w.user_id
INNER JOIN instruments i ON i.instrument_id = wi.instrument_id
ORDER BY u.username, w.name, i.symbol;
