SELECT r.rule_id, u.username, i.symbol, r.direction, r.threshold,
       reporting.fn_latest_price(r.instrument_id) AS latest_price,
       reporting.fn_latest_price(r.instrument_id) - r.threshold AS difference
FROM alert_rules r
JOIN users u ON u.user_id = r.user_id
JOIN instruments i ON i.instrument_id = r.instrument_id
WHERE r.is_active = true
ORDER BY r.rule_id;
