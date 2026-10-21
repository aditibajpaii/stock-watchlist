\echo '========================================================================'
\echo ' CQ05 | Complex: aggregate + window (RANK)'
\echo '        Q: Rank instruments by volatility: price range as % of average price'
\echo '           (only instruments with at least 2 ticks)'
\echo '========================================================================'
SELECT i.symbol,
       count(*)                                                 AS ticks,
       min(t.price)::numeric(12,2)                              AS low,
       max(t.price)::numeric(12,2)                              AS high,
       round((max(t.price) - min(t.price)) / avg(t.price) * 100, 3) AS range_pct,
       round(stddev_samp(t.price), 2)                           AS std_dev,
       RANK() OVER (ORDER BY (max(t.price) - min(t.price)) / avg(t.price) DESC) AS volatility_rank
FROM price_ticks t
JOIN instruments i ON i.instrument_id = t.instrument_id
GROUP BY i.symbol
HAVING count(*) >= 2
ORDER BY volatility_rank;
