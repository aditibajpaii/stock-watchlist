SELECT 'users' AS table_name, count(*) FROM users
UNION ALL
SELECT 'instruments', count(*) FROM instruments
UNION ALL
SELECT 'watchlists', count(*) FROM watchlists
UNION ALL
SELECT 'watchlist_items', count(*) FROM watchlist_items
UNION ALL
SELECT 'alert_rules', count(*) FROM alert_rules
UNION ALL
SELECT 'price_ticks', count(*) FROM price_ticks
UNION ALL
SELECT 'alert_events', count(*) FROM alert_events;
