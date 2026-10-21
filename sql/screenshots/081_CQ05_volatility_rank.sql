SELECT i.symbol, count(*) AS ticks, min(t.price) AS low, max(t.price) AS high,
       round((max(t.price) - min(t.price)) / avg(t.price) * 100, 2) AS range_pct
FROM price_ticks t
JOIN instruments i ON i.instrument_id = t.instrument_id
GROUP BY i.symbol
HAVING count(*) >= 2
ORDER BY range_pct DESC;
