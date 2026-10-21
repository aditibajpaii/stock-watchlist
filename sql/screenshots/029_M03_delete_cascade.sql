\echo '========================================================================'
\echo ' M03 | DML DELETE: removing the watchlist also removes its items'
\echo '       (ON DELETE CASCADE) but never instruments or price history'
\echo '========================================================================'
SELECT count(*) AS items_in_list FROM watchlist_items wi
JOIN watchlists w USING (watchlist_id) WHERE w.name = 'Review 2 Demo (renamed)';

DELETE FROM watchlists WHERE name = 'Review 2 Demo (renamed)'
RETURNING watchlist_id, name;

SELECT (SELECT count(*) FROM watchlists)      AS watchlists,
       (SELECT count(*) FROM watchlist_items) AS watchlist_items,
       (SELECT count(*) FROM instruments)     AS instruments,
       (SELECT count(*) FROM price_ticks)     AS price_ticks;
