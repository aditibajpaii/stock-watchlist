-- =====================================================================
-- 09_advanced_functions.sql  -  Template category F (Advanced functions), minimum 6
-- Coverage: CASE, COALESCE, NULLIF, date/time, string, numeric functions
-- Read-only.
-- =====================================================================
\ir _guard.sql

\echo '=== F01 | CASE | Describe how each alert rule behaves, in words'
SELECT r.rule_id, u.username, i.symbol, r.direction, r.threshold,
       CASE
           WHEN NOT r.is_active        THEN 'disabled - never fires'
           WHEN r.cooldown_seconds = 0 THEN 'active - fires on every crossing'
           ELSE 'active - at most one alert per ' || r.cooldown_seconds || ' s of market time'
       END AS behaviour
FROM alert_rules r
JOIN users u       ON u.user_id = r.user_id
JOIN instruments i ON i.instrument_id = r.instrument_id
ORDER BY r.rule_id;

\echo '=== F02 | COALESCE | Show the latest price and volume of every instrument, with readable text where there is none'
-- COALESCE is used for DISPLAY only: an unknown volume is not zero,
-- so it is shown as "unknown", never replaced by 0 in calculations.
SELECT i.exchange, i.symbol,
       coalesce(to_char(lt.price,  'FM999999990.00'), 'no ticks yet') AS latest_price,
       coalesce(to_char(lt.volume, 'FM999999990.00'), 'unknown')      AS latest_volume
FROM instruments i
LEFT JOIN LATERAL (SELECT t.price, t.volume
                   FROM price_ticks t
                   WHERE t.instrument_id = i.instrument_id
                   ORDER BY t.observed_at DESC, t.tick_id DESC
                   LIMIT 1) lt ON true
ORDER BY i.exchange, i.symbol;

\echo '=== F03 | NULLIF | How many alerts per 100 ticks did each instrument produce (no division-by-zero error)?'
-- NULLIF(x, 0) turns a zero divisor into NULL, so instruments with no
-- ticks give NULL instead of "ERROR: division by zero".
SELECT i.symbol,
       count(DISTINCT t.tick_id)  AS ticks,
       count(DISTINCT e.event_id) AS alerts,
       round(100.0 * count(DISTINCT e.event_id)
                   / nullif(count(DISTINCT t.tick_id), 0), 1) AS alerts_per_100_ticks
FROM instruments i
LEFT JOIN price_ticks t  ON t.instrument_id = i.instrument_id
LEFT JOIN alert_events e ON e.tick_id = t.tick_id
GROUP BY i.symbol
ORDER BY i.symbol;

\echo '=== F04 | date/time | Over what span of market time did each instrument trade?'
SELECT i.symbol,
       to_char(min(t.observed_at) AT TIME ZONE 'Asia/Kolkata', 'HH24:MI:SS') AS first_tick_ist,
       to_char(max(t.observed_at) AT TIME ZONE 'Asia/Kolkata', 'HH24:MI:SS') AS last_tick_ist,
       max(t.observed_at) - min(t.observed_at)                          AS span,
       extract(epoch FROM max(t.observed_at) - min(t.observed_at))::int AS span_seconds
FROM price_ticks t
JOIN instruments i ON i.instrument_id = t.instrument_id
GROUP BY i.symbol
ORDER BY span_seconds DESC;

\echo '=== F05 | date/time | When (in market time) does each rule leave its cooldown after its last alert?'
-- Offsets are seconds after the first tick of the replay, so they do not
-- depend on the day the sandbox was built.
SELECT r.rule_id, i.symbol, r.direction,
       make_interval(secs => r.cooldown_seconds) AS cooldown,
       extract(epoch FROM la.observed_at - rs.run_start)::int AS last_alert_at_s,
       extract(epoch FROM la.observed_at + make_interval(secs => r.cooldown_seconds)
                          - rs.run_start)::int                AS can_fire_again_at_s,
       to_char((la.observed_at + make_interval(secs => r.cooldown_seconds))
               AT TIME ZONE 'Asia/Kolkata', 'HH24:MI:SS')     AS can_fire_again_ist
FROM alert_rules r
JOIN instruments i ON i.instrument_id = r.instrument_id
CROSS JOIN (SELECT min(observed_at) AS run_start FROM price_ticks) AS rs
JOIN LATERAL (SELECT t.observed_at
              FROM alert_events e
              JOIN price_ticks t ON t.tick_id = e.tick_id
              WHERE e.rule_id = r.rule_id
              ORDER BY t.observed_at DESC, t.tick_id DESC
              LIMIT 1) AS la ON true
ORDER BY r.rule_id;

\echo '=== F06 | string | Build display labels for every instrument'
SELECT format('%s:%s', exchange, symbol) AS ticker,
       upper(name)                       AS name_upper,
       length(name)                      AS name_length,
       replace(name, ' Ltd', '')         AS short_name,
       lower(quote_currency)             AS currency_lower
FROM instruments
ORDER BY ticker;

\echo '=== F07 | string | Show each user with a display name and a masked email (privacy)'
SELECT username,
       initcap(username) AS display_name,
       left(email, 1) || repeat('*', position('@' IN email) - 2)
                      || substring(email FROM position('@' IN email)) AS masked_email,
       split_part(email, '@', 2) AS email_domain
FROM users
ORDER BY username;

\echo '=== F08 | numeric | How much did each instrument move from its first to its last tick?'
WITH first_last AS (
    SELECT t.instrument_id,
           (array_agg(t.price ORDER BY t.observed_at, t.tick_id))[1]           AS first_price,
           (array_agg(t.price ORDER BY t.observed_at DESC, t.tick_id DESC))[1] AS last_price
    FROM price_ticks t
    GROUP BY t.instrument_id
)
SELECT i.symbol,
       round(fl.first_price, 2)                                          AS first_price,
       round(fl.last_price, 2)                                           AS last_price,
       round(fl.last_price - fl.first_price, 2)                          AS change,
       round(100 * (fl.last_price - fl.first_price) / fl.first_price, 2) AS change_pct,
       abs(round(100 * (fl.last_price - fl.first_price) / fl.first_price, 2)) AS abs_change_pct,
       sign(fl.last_price - fl.first_price)                              AS direction_sign,
       floor(fl.last_price)                                              AS last_floor,
       ceil(fl.last_price)                                               AS last_ceil
FROM first_last fl
JOIN instruments i ON i.instrument_id = fl.instrument_id
ORDER BY abs_change_pct DESC;
