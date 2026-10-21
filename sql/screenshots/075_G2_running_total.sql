\echo '========================================================================'
\echo ' G2 | Window: running total and running average (SUM / AVG OVER ORDER BY)'
\echo '      Q: Cumulative traded volume and moving price average for BTCUSDT'
\echo '========================================================================'
SELECT tick_id,
       observed_at::time(0)  AS time,
       price::numeric(12,2)  AS price,
       volume,
       SUM(volume) OVER (ORDER BY observed_at, tick_id)                   AS running_volume,
       round(AVG(price) OVER (ORDER BY observed_at, tick_id), 2)         AS running_avg_price,
       round(AVG(price) OVER (ORDER BY observed_at, tick_id
                              ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2) AS moving_avg_3
FROM price_ticks
WHERE instrument_id = 6
ORDER BY observed_at, tick_id;
