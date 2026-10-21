BEGIN;
INSERT INTO watchlist_items (watchlist_id, instrument_id)
SELECT watchlist_id, 4 FROM watchlists WHERE name = 'Favourites';
SAVEPOINT sp1;
INSERT INTO watchlist_items (watchlist_id, instrument_id)
SELECT watchlist_id, 3 FROM watchlists WHERE name = 'Favourites';
ROLLBACK TO SAVEPOINT sp1;
INSERT INTO watchlist_items (watchlist_id, instrument_id)
SELECT watchlist_id, 2 FROM watchlists WHERE name = 'Favourites';
COMMIT;

SELECT w.name, i.symbol
FROM watchlists w
JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
JOIN instruments i ON i.instrument_id = wi.instrument_id
WHERE w.name = 'Favourites';
