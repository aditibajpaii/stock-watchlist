SELECT i.symbol, r.rule_id, r.direction, r.threshold
FROM alert_rules r
RIGHT JOIN instruments i ON i.instrument_id = r.instrument_id
ORDER BY i.symbol;
