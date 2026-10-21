SELECT u.username, i.symbol, count(*) AS alerts, max(t.observed_at) AS last_alert
FROM alert_events e
JOIN alert_rules r ON r.rule_id = e.rule_id
JOIN users u ON u.user_id = r.user_id
JOIN instruments i ON i.instrument_id = r.instrument_id
JOIN price_ticks t ON t.tick_id = e.tick_id
GROUP BY u.username, i.symbol
ORDER BY u.username, alerts DESC;
