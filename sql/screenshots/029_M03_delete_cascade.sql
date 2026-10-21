SELECT count(*) FROM watchlist_items;

DELETE FROM watchlists WHERE name = 'My Favourites' RETURNING *;

SELECT count(*) FROM watchlist_items;
SELECT count(*) FROM instruments;
SELECT count(*) FROM price_ticks;
