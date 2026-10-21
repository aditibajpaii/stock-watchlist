SELECT tick_id, instrument_id, price, volume
FROM price_ticks
WHERE volume IS NULL;

SELECT count(*) FROM price_ticks WHERE volume IS NOT NULL;
