\echo '========================================================================'
\echo ' C2 | Join: LEFT OUTER JOIN'
\echo '      Q: Tick count for EVERY instrument, including those with no data yet'
\echo '========================================================================'
SELECT i.exchange, i.symbol, count(t.tick_id) AS ticks
FROM instruments i
LEFT JOIN price_ticks t ON t.instrument_id = i.instrument_id
GROUP BY i.exchange, i.symbol
ORDER BY ticks DESC, i.symbol;
