SELECT w.name, count(*) AS items
FROM watchlists w
JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
GROUP BY w.name
HAVING count(*) >= 3;
