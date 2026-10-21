SELECT tick_id, volume
FROM price_ticks
WHERE instrument_id = 2
  AND volume NOT IN (SELECT volume FROM price_ticks WHERE instrument_id = 1);

SELECT tick_id, volume
FROM price_ticks
WHERE instrument_id = 2
  AND volume NOT IN (SELECT volume FROM price_ticks WHERE instrument_id = 1 AND volume IS NOT NULL);
