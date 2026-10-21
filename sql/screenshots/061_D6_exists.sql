SELECT r.rule_id, r.user_id, r.direction, r.threshold
FROM alert_rules r
WHERE EXISTS (SELECT 1 FROM alert_events e WHERE e.rule_id = r.rule_id);
