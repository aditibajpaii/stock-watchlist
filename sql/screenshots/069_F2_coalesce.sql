SELECT tick_id, price, volume, COALESCE(volume, 0) AS volume_or_zero
FROM price_ticks
WHERE instrument_id = 6;
