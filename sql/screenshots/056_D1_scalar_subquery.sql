SELECT tick_id, instrument_id, price, observed_at
FROM price_ticks
WHERE observed_at = (SELECT max(observed_at) FROM price_ticks);

SELECT tick_id, price
FROM price_ticks
WHERE instrument_id = 2
  AND price > (SELECT avg(price) FROM price_ticks WHERE instrument_id = 2);
