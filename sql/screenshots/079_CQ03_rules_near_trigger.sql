\echo '========================================================================'
\echo ' CQ03 | Complex: 4 tables + LATERAL + CASE'
\echo '        Q: For every ACTIVE rule, how far (%) is the latest price from the'
\echo '           threshold, and is the rule''s condition currently met?'
\echo '========================================================================'
SELECT r.rule_id, u.username, i.symbol, r.direction,
       r.threshold::numeric(12,2)                                   AS threshold,
       lp.price::numeric(12,2)                                      AS latest_price,
       round((lp.price - r.threshold) / r.threshold * 100, 2)       AS distance_pct,
       CASE WHEN lp.price IS NULL THEN 'no data'
            WHEN (r.direction = 'ABOVE' AND lp.price >= r.threshold)
              OR (r.direction = 'BELOW' AND lp.price <= r.threshold) THEN 'condition met'
            ELSE 'waiting' END                                      AS state
FROM alert_rules r
JOIN users u       ON u.user_id = r.user_id
JOIN instruments i ON i.instrument_id = r.instrument_id
LEFT JOIN LATERAL (
    SELECT t.price FROM price_ticks t WHERE t.instrument_id = r.instrument_id
    ORDER BY t.observed_at DESC, t.tick_id DESC LIMIT 1) lp ON true
WHERE r.is_active
ORDER BY abs(lp.price - r.threshold) / r.threshold NULLS LAST;
