\echo '========================================================================'
\echo ' CQ06 | Complex: 4 tables + window (LAG) in a subquery'
\echo '        Q: Which DISABLED rules would have fired? (crossings they missed)'
\echo '========================================================================'
SELECT r.rule_id, u.username, i.symbol, r.direction,
       r.threshold::numeric(12,2) AS threshold,
       x.prev_price::numeric(12,2) AS prev_price,
       x.price::numeric(12,2)      AS price,
       x.observed_at::time(0)      AS at
FROM alert_rules r
JOIN users u       ON u.user_id = r.user_id
JOIN instruments i ON i.instrument_id = r.instrument_id
JOIN (SELECT t.instrument_id, t.price, t.observed_at,
             LAG(t.price) OVER (PARTITION BY t.instrument_id
                                ORDER BY t.observed_at, t.tick_id) AS prev_price
      FROM price_ticks t) x ON x.instrument_id = r.instrument_id
WHERE NOT r.is_active
  AND (   (r.direction = 'ABOVE' AND x.prev_price < r.threshold AND x.price >= r.threshold)
       OR (r.direction = 'BELOW' AND x.prev_price > r.threshold AND x.price <= r.threshold))
ORDER BY r.rule_id, x.observed_at;
