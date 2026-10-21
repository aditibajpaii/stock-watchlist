\echo '========================================================================'
\echo ' B3 | Aggregate: GROUP BY on two columns'
\echo '      Q: How many alerts fired per user and direction (ABOVE / BELOW)?'
\echo '========================================================================'
SELECT u.username, r.direction, count(*) AS alerts_fired
FROM alert_events e
JOIN alert_rules r ON r.rule_id = e.rule_id
JOIN users u       ON u.user_id = r.user_id
GROUP BY u.username, r.direction
ORDER BY u.username, r.direction;
