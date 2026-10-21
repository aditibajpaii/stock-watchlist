\echo '========================================================================'
\echo ' B2 | Aggregate: SUM and COUNT(*) vs COUNT(column)'
\echo '      Q: Total traded volume per instrument? (SUM and COUNT(col) skip NULLs)'
\echo '========================================================================'
SELECT i.symbol,
       count(*)           AS all_ticks,
       count(t.volume)    AS ticks_with_volume,
       sum(t.volume)      AS total_volume
FROM price_ticks t
JOIN instruments i ON i.instrument_id = t.instrument_id
GROUP BY i.symbol
ORDER BY i.symbol;
