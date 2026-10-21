\echo '========================================================================'
\echo ' D5 | Subquery: correlated (inner query uses the outer row t.instrument_id)'
\echo '      Q: Which ticks were priced above their OWN instrument''s average?'
\echo '========================================================================'
SELECT i.symbol, t.tick_id, t.price::numeric(12,2) AS price
FROM price_ticks t
JOIN instruments i ON i.instrument_id = t.instrument_id
WHERE t.price > (SELECT avg(t2.price)
                 FROM price_ticks t2
                 WHERE t2.instrument_id = t.instrument_id)
ORDER BY i.symbol, t.observed_at;
