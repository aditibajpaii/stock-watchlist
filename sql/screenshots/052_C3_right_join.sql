\echo '========================================================================'
\echo ' C3 | Join: RIGHT OUTER JOIN'
\echo '      Q: Every instrument with its alert rules (NULL = nobody has a rule on it)'
\echo '========================================================================'
SELECT i.symbol, r.rule_id, r.direction, r.threshold::numeric(12,2) AS threshold
FROM alert_rules r
RIGHT JOIN instruments i ON i.instrument_id = r.instrument_id
ORDER BY i.symbol, r.rule_id;
