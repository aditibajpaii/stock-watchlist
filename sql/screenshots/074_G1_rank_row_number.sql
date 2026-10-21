SELECT i.symbol, count(t.tick_id) AS ticks,
       ROW_NUMBER() OVER (ORDER BY count(t.tick_id) DESC, i.symbol),
       RANK() OVER (ORDER BY count(t.tick_id) DESC),
       DENSE_RANK() OVER (ORDER BY count(t.tick_id) DESC)
FROM instruments i
LEFT JOIN price_ticks t ON t.instrument_id = i.instrument_id
GROUP BY i.symbol
ORDER BY ticks DESC, i.symbol;
