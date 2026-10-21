SELECT r.rule_id, u.username, i.symbol, r.direction, r.threshold, t.tick_id, t.price
FROM alert_rules r
JOIN users u ON u.user_id = r.user_id
JOIN instruments i ON i.instrument_id = r.instrument_id
JOIN price_ticks t ON t.instrument_id = r.instrument_id
WHERE r.is_active = false
  AND ((r.direction = 'ABOVE' AND t.price >= r.threshold)
    OR (r.direction = 'BELOW' AND t.price <= r.threshold));
