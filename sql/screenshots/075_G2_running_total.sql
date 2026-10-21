SELECT tick_id, price, volume,
       SUM(volume) OVER (ORDER BY observed_at) AS running_volume,
       round(AVG(price) OVER (ORDER BY observed_at), 2) AS running_avg
FROM price_ticks
WHERE instrument_id = 6;
