SELECT tick_id, instrument_id, price, observed_at
FROM price_ticks
WHERE price BETWEEN 3000 AND 3600
ORDER BY instrument_id, observed_at;
