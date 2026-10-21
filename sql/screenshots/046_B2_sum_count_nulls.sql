SELECT instrument_id, count(*), count(volume), sum(volume)
FROM price_ticks
GROUP BY instrument_id
ORDER BY instrument_id;
