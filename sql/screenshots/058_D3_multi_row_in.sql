\echo '========================================================================'
\echo ' D3 | Subquery: multi-row with IN'
\echo '      Q: Which instruments have produced at least one alert?'
\echo '========================================================================'
SELECT exchange, symbol
FROM instruments
WHERE instrument_id IN (SELECT r.instrument_id
                        FROM alert_rules r
                        JOIN alert_events e ON e.rule_id = r.rule_id)
ORDER BY symbol;
