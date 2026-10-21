\echo '========================================================================'
\echo ' F4 | Function: date / time'
\echo '      Q: Show RELIANCE ticks in IST and UTC, the minute bucket, and seconds since the first tick'
\echo '========================================================================'
SELECT tick_id,
       to_char(observed_at, 'DD-Mon-YYYY HH24:MI:SS')          AS ist_time,
       to_char(observed_at AT TIME ZONE 'UTC', 'HH24:MI:SS')   AS utc_time,
       date_trunc('minute', observed_at)::time                 AS minute_bucket,
       extract(epoch FROM observed_at - min(observed_at) OVER ())::int AS secs_since_first,
       to_char(observed_at, 'Dy')                               AS weekday
FROM price_ticks
WHERE instrument_id = 1
ORDER BY observed_at;

SELECT now()::timestamp(0) AS now_ist, current_date, age(now(), min(created_at)) AS oldest_user_age
FROM users;
