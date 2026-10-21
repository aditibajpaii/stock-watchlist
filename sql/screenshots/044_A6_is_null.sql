\echo '========================================================================'
\echo ' A6 | Basic: IS NULL / IS NOT NULL'
\echo '      Q: Which ticks arrived with an UNKNOWN volume (NULL, not zero)?'
\echo '========================================================================'
SELECT tick_id, instrument_id, price::numeric(12,2) AS price, volume, source_event_id
FROM price_ticks
WHERE volume IS NULL
ORDER BY tick_id;

SELECT count(*) FILTER (WHERE volume IS NULL)     AS unknown_volume,
       count(*) FILTER (WHERE volume IS NOT NULL) AS known_volume
FROM price_ticks;
