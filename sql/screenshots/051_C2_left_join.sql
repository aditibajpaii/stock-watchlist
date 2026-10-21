SELECT i.symbol, count(t.tick_id) AS ticks
FROM instruments i
LEFT JOIN price_ticks t ON t.instrument_id = i.instrument_id
GROUP BY i.symbol
ORDER BY ticks DESC;
