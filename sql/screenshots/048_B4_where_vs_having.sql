SELECT instrument_id, count(*) AS ticks
FROM price_ticks
WHERE volume IS NOT NULL
GROUP BY instrument_id
HAVING count(*) >= 3;
