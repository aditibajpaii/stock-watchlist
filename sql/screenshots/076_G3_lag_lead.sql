SELECT tick_id, price,
       LAG(price) OVER (ORDER BY observed_at) AS prev_price,
       LEAD(price) OVER (ORDER BY observed_at) AS next_price
FROM price_ticks
WHERE instrument_id = 1;
