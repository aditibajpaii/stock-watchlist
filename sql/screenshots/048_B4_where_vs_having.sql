\echo '========================================================================'
\echo ' B4 | Aggregate: WHERE vs HAVING in ONE query'
\echo '      WHERE filters ROWS before grouping; HAVING filters GROUPS after.'
\echo '      Q: Among ticks with a known volume, which instruments have >= 3 of them?'
\echo '========================================================================'
SELECT i.symbol,
       count(*)               AS ticks_with_volume,
       round(avg(t.price), 2) AS avg_price
FROM price_ticks t
JOIN instruments i ON i.instrument_id = t.instrument_id
WHERE t.volume IS NOT NULL          -- row filter (before GROUP BY)
GROUP BY i.symbol
HAVING count(*) >= 3                -- group filter (after GROUP BY)
ORDER BY ticks_with_volume DESC;
