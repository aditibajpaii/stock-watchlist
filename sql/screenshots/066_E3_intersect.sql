SELECT instrument_id FROM watchlist_items
INTERSECT
SELECT instrument_id FROM alert_rules;
