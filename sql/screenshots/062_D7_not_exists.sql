SELECT i.symbol
FROM instruments i
WHERE NOT EXISTS (SELECT 1 FROM price_ticks t WHERE t.instrument_id = i.instrument_id);

SELECT r.rule_id, r.direction, r.threshold
FROM alert_rules r
WHERE NOT EXISTS (SELECT 1 FROM alert_events e WHERE e.rule_id = r.rule_id);
