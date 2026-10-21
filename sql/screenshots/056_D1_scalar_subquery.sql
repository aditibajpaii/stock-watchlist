\echo '========================================================================'
\echo ' D1 | Subquery: scalar (returns exactly one value)'
\echo '      Q: What is the most recent tick, and how far is each TCS tick from the TCS average?'
\echo '========================================================================'
SELECT tick_id, instrument_id, price::numeric(12,2) AS price, observed_at
FROM price_ticks
WHERE observed_at = (SELECT max(observed_at) FROM price_ticks);

SELECT tick_id, price::numeric(12,2) AS price,
       round(price - (SELECT avg(price) FROM price_ticks WHERE instrument_id = 2), 2) AS diff_from_avg
FROM price_ticks
WHERE instrument_id = 2
ORDER BY observed_at;
