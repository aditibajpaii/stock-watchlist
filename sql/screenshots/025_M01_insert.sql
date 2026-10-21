INSERT INTO watchlists (user_id, name) VALUES (1, 'Favourites') RETURNING *;

INSERT INTO watchlist_items (watchlist_id, instrument_id)
SELECT watchlist_id, 3 FROM watchlists WHERE name = 'Favourites';

INSERT INTO watchlist_items (watchlist_id, instrument_id)
SELECT watchlist_id, 5 FROM watchlists WHERE name = 'Favourites';

SELECT w.name, i.symbol
FROM watchlists w
JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
JOIN instruments i ON i.instrument_id = wi.instrument_id
WHERE w.name = 'Favourites';
