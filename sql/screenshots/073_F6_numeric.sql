SELECT tick_id, price, round(price, 1), ceil(price), floor(price),
       abs(price - 100000) AS diff, round(price * volume, 2) AS value
FROM price_ticks
WHERE instrument_id = 6;
