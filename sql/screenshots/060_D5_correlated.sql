SELECT t.tick_id, t.instrument_id, t.price
FROM price_ticks t
WHERE t.price > (SELECT avg(price) FROM price_ticks WHERE instrument_id = t.instrument_id)
ORDER BY t.instrument_id;
