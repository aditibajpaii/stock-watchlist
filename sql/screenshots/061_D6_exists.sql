\echo '========================================================================'
\echo ' D6 | Subquery: EXISTS'
\echo '      Q: Which alert rules have fired at least once?'
\echo '========================================================================'
SELECT r.rule_id, r.user_id, r.direction, r.threshold::numeric(12,2) AS threshold, r.is_active
FROM alert_rules r
WHERE EXISTS (SELECT 1 FROM alert_events e WHERE e.rule_id = r.rule_id)
ORDER BY r.rule_id;
