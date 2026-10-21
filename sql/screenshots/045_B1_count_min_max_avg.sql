\echo '========================================================================'
\echo ' B1 | Aggregate: COUNT, MIN, MAX, AVG with GROUP BY'
\echo '      Q: For each instrument, how many ticks and what price range?'
\echo '========================================================================'
SELECT instrument_id,
       count(*)                       AS ticks,
       min(price)::numeric(12,2)      AS min_price,
       max(price)::numeric(12,2)      AS max_price,
       round(avg(price), 2)           AS avg_price
FROM price_ticks
GROUP BY instrument_id
ORDER BY instrument_id;
