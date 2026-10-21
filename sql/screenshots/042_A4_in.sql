\echo '========================================================================'
\echo ' A4 | Basic: IN'
\echo '      Q: Show the alert rules of users 1 and 3 (arjun and kavya).'
\echo '========================================================================'
SELECT rule_id, user_id, instrument_id, direction,
       threshold::numeric(12,2) AS threshold, cooldown_seconds, is_active
FROM alert_rules
WHERE user_id IN (1, 3)
ORDER BY user_id, rule_id;
