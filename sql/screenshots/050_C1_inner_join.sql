SELECT u.username, w.name, i.symbol
FROM watchlist_items wi
INNER JOIN watchlists w ON w.watchlist_id = wi.watchlist_id
INNER JOIN users u ON u.user_id = w.user_id
INNER JOIN instruments i ON i.instrument_id = wi.instrument_id
ORDER BY u.username, w.name;
