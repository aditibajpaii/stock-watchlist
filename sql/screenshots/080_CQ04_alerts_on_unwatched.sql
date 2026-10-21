SELECT e.event_id, u.username, i.symbol, r.direction, r.threshold
FROM alert_events e
JOIN alert_rules r ON r.rule_id = e.rule_id
JOIN users u ON u.user_id = r.user_id
JOIN instruments i ON i.instrument_id = r.instrument_id
WHERE NOT EXISTS (
    SELECT 1
    FROM watchlists w
    JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
    WHERE w.user_id = r.user_id AND wi.instrument_id = r.instrument_id
);
