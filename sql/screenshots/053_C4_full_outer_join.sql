SELECT w.user_id, wi.instrument_id, r.rule_id, r.user_id AS rule_user, r.instrument_id AS rule_instrument
FROM watchlists w
JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
FULL OUTER JOIN alert_rules r ON r.user_id = w.user_id AND r.instrument_id = wi.instrument_id
ORDER BY w.user_id, wi.instrument_id;
