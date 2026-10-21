SELECT instrument_id, count(volume) AS known, count(*) - count(volume) AS unknown,
       round(count(volume)::numeric / NULLIF(count(*) - count(volume), 0), 2) AS ratio
FROM price_ticks
GROUP BY instrument_id;

SELECT count(volume) / (count(*) - count(volume)) AS ratio
FROM price_ticks
WHERE instrument_id = 3;
