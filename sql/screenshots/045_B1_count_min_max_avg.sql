SELECT instrument_id, count(*), min(price), max(price), round(avg(price), 2) AS avg
FROM price_ticks
GROUP BY instrument_id
ORDER BY instrument_id;
