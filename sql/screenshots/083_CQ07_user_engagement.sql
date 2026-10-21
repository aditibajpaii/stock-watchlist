SELECT u.username,
       count(DISTINCT w.watchlist_id) AS watchlists,
       count(DISTINCT r.rule_id) AS rules,
       count(DISTINCT e.event_id) AS alerts
FROM users u
LEFT JOIN watchlists w ON w.user_id = u.user_id
LEFT JOIN alert_rules r ON r.user_id = u.user_id
LEFT JOIN alert_events e ON e.rule_id = r.rule_id
GROUP BY u.username
ORDER BY alerts DESC;
