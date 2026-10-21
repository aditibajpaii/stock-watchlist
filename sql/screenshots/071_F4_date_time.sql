SELECT tick_id, observed_at, observed_at::date AS day, to_char(observed_at, 'HH24:MI:SS') AS time,
       extract(hour FROM observed_at) AS hour, date_trunc('minute', observed_at) AS minute
FROM price_ticks
WHERE instrument_id = 1;

SELECT now(), current_date, current_date + 7 AS next_week, age(now(), '2026-01-01');
