\echo '========================================================================'
\echo ' CQ04 | Complex: 5 tables + NOT EXISTS (nested)'
\echo '        Q: Which alerts fired on an instrument that the rule''s owner does NOT'
\echo '           have in any of their watchlists?'
\echo '========================================================================'
SELECT e.event_id, u.username, i.symbol, r.direction,
       r.threshold::numeric(12,2) AS threshold, t.price::numeric(12,2) AS price
FROM alert_events e
JOIN alert_rules r ON r.rule_id = e.rule_id
JOIN users u       ON u.user_id = r.user_id
JOIN instruments i ON i.instrument_id = r.instrument_id
JOIN price_ticks t ON t.tick_id = e.tick_id
WHERE NOT EXISTS (
    SELECT 1 FROM watchlists w
    JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
    WHERE w.user_id = r.user_id AND wi.instrument_id = r.instrument_id)
ORDER BY e.event_id;
