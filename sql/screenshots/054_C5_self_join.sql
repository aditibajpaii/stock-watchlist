SELECT a.instrument_id, a.watchlist_id AS list_1, b.watchlist_id AS list_2
FROM watchlist_items a
JOIN watchlist_items b ON a.instrument_id = b.instrument_id AND a.watchlist_id < b.watchlist_id
ORDER BY a.instrument_id;
