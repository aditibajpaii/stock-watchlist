SELECT tick_id, price,
       CASE
           WHEN price >= 3000 THEN 'HIGH'
           WHEN price <= 2800 THEN 'LOW'
           ELSE 'NORMAL'
       END AS price_level
FROM price_ticks
WHERE instrument_id = 1;
