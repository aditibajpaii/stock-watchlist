\echo '========================================================================'
\echo ' D7 | Subquery: NOT EXISTS'
\echo '      Q: Which instruments have no price data yet? Which rules never fired?'
\echo '========================================================================'
SELECT i.exchange, i.symbol
FROM instruments i
WHERE NOT EXISTS (SELECT 1 FROM price_ticks t WHERE t.instrument_id = i.instrument_id);

SELECT r.rule_id, r.user_id, r.direction, r.threshold::numeric(12,2) AS threshold, r.is_active
FROM alert_rules r
WHERE NOT EXISTS (SELECT 1 FROM alert_events e WHERE e.rule_id = r.rule_id);
