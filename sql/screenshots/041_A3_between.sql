\echo '========================================================================'
\echo ' A3 | Basic: BETWEEN'
\echo '      Q: Which ticks were priced between 3,000 and 3,600 (inclusive)?'
\echo '========================================================================'
SELECT tick_id, instrument_id, price::numeric(12,2) AS price, observed_at
FROM price_ticks
WHERE price BETWEEN 3000 AND 3600
ORDER BY instrument_id, observed_at;
