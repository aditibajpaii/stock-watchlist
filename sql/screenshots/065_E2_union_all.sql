SELECT instrument_id FROM watchlist_items WHERE watchlist_id = 2
UNION ALL
SELECT instrument_id FROM alert_rules WHERE user_id = 1;
