SELECT rule_id, user_id, instrument_id, direction, threshold, cooldown_seconds, is_active
FROM alert_rules
WHERE user_id IN (1, 3);
