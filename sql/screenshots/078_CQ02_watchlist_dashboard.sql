\echo '========================================================================'
\echo ' CQ02 | Complex: 4 tables + LATERAL subquery + UDF'
\echo '        Q: Show every watchlist item with its latest price and % change'
\echo '           since its first tick (what the website dashboard shows)'
\echo '========================================================================'
SELECT u.username, w.name AS watchlist, i.symbol,
       lp.price::numeric(12,2)                       AS latest_price,
       i.quote_currency                              AS ccy,
       reporting.fn_price_change_pct(i.instrument_id) AS change_pct,
       lp.observed_at::time(0)                       AS as_of
FROM users u
JOIN watchlists w       ON w.user_id = u.user_id
JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
JOIN instruments i      ON i.instrument_id = wi.instrument_id
LEFT JOIN LATERAL (
    SELECT t.price, t.observed_at FROM price_ticks t
    WHERE t.instrument_id = i.instrument_id
    ORDER BY t.observed_at DESC, t.tick_id DESC LIMIT 1) lp ON true
ORDER BY u.username, w.name, i.symbol;
