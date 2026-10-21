SELECT u.username, i.symbol, count(r.rule_id) AS rules
FROM watchlists w
JOIN users u ON u.user_id = w.user_id
JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
JOIN instruments i ON i.instrument_id = wi.instrument_id
LEFT JOIN alert_rules r ON r.user_id = w.user_id AND r.instrument_id = wi.instrument_id
GROUP BY u.username, i.symbol
ORDER BY u.username, i.symbol;
