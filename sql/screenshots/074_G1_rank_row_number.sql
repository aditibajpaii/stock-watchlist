\echo '========================================================================'
\echo ' G1 | Window: ROW_NUMBER, RANK, DENSE_RANK (difference shown by the ties)'
\echo '      Q: Rank instruments by how many ticks they have'
\echo '========================================================================'
SELECT i.symbol,
       count(t.tick_id) AS ticks,
       ROW_NUMBER() OVER (ORDER BY count(t.tick_id) DESC, i.symbol) AS row_number,
       RANK()       OVER (ORDER BY count(t.tick_id) DESC)           AS rank,
       DENSE_RANK() OVER (ORDER BY count(t.tick_id) DESC)           AS dense_rank
FROM instruments i
LEFT JOIN price_ticks t ON t.instrument_id = i.instrument_id
GROUP BY i.symbol
ORDER BY row_number;
