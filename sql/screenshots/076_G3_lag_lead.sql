\echo '========================================================================'
\echo ' G3 | Window: LAG and LEAD'
\echo '      Q: Previous / next RELIANCE price, the change, and where it crossed 3000'
\echo '         (the same previous-vs-new comparison the alert trigger makes)'
\echo '========================================================================'
SELECT tick_id,
       observed_at::time(0)                                   AS time,
       LAG(price)  OVER w ::numeric(12,2)                     AS prev_price,
       price::numeric(12,2)                                   AS price,
       LEAD(price) OVER w ::numeric(12,2)                     AS next_price,
       (price - LAG(price) OVER w)::numeric(12,2)             AS change,
       CASE WHEN LAG(price) OVER w < 3000 AND price >= 3000 THEN 'crossed ABOVE 3000'
            WHEN LAG(price) OVER w > 2800 AND price <= 2800 THEN 'crossed BELOW 2800'
       END                                                    AS crossing
FROM price_ticks
WHERE instrument_id = 1
WINDOW w AS (ORDER BY observed_at, tick_id)
ORDER BY observed_at, tick_id;
