SELECT u.username, w.name, i.symbol,
       reporting.fn_latest_price(i.instrument_id) AS latest_price,
       reporting.fn_price_change_pct(i.instrument_id) AS change_pct
FROM users u
JOIN watchlists w ON w.user_id = u.user_id
JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
JOIN instruments i ON i.instrument_id = wi.instrument_id
ORDER BY u.username, w.name;
