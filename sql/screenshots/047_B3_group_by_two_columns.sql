SELECT r.user_id, r.direction, count(*) AS alerts
FROM alert_events e
JOIN alert_rules r ON r.rule_id = e.rule_id
GROUP BY r.user_id, r.direction
ORDER BY r.user_id, r.direction;
