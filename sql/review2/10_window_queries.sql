-- =====================================================================
-- 10_window_queries.sql  -  Template category G (Window/analytic),
-- minimum 2, marked "recommended for higher band" in the template.
-- Coverage: LAG, ROW_NUMBER / RANK / DENSE_RANK, running total, LEAD,
-- moving average. A window function keeps every row (unlike GROUP BY).
-- Read-only.
-- =====================================================================
\ir _guard.sql

\echo '=== W01 | LAG | How did the RELIANCE price change from each tick to the next?'
-- Same ordering (observed_at, tick_id) that the alert trigger uses to
-- find the "previous tick".
SELECT t.tick_id, t.price,
       lag(t.price) OVER w                                AS previous_price,
       t.price - lag(t.price) OVER w                      AS change,
       round(100 * (t.price - lag(t.price) OVER w)
                 / lag(t.price) OVER w, 3)                AS change_pct
FROM price_ticks t
WHERE t.instrument_id = 1              -- NSE RELIANCE
WINDOW w AS (ORDER BY t.observed_at, t.tick_id)
ORDER BY t.observed_at, t.tick_id;

\echo '=== W02 | ROW_NUMBER, RANK, DENSE_RANK | Rank users by number of watchlists (how each function treats the tie)'
SELECT u.username,
       count(w.watchlist_id) AS watchlists,
       row_number() OVER (ORDER BY count(w.watchlist_id) DESC, u.username) AS row_number,
       rank()       OVER (ORDER BY count(w.watchlist_id) DESC)             AS rank,
       dense_rank() OVER (ORDER BY count(w.watchlist_id) DESC)             AS dense_rank
FROM users u
LEFT JOIN watchlists w ON w.user_id = u.user_id
GROUP BY u.username
ORDER BY watchlists DESC, u.username;

\echo '=== W03 | running total | What is the cumulative known traded volume of RELIANCE over market time?'
SELECT t.tick_id, t.volume,
       sum(t.volume) OVER (ORDER BY t.observed_at, t.tick_id
                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_volume,
       count(t.volume) OVER (ORDER BY t.observed_at, t.tick_id
                             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS ticks_with_known_volume
FROM price_ticks t
WHERE t.instrument_id = 1              -- NSE RELIANCE
ORDER BY t.observed_at, t.tick_id;

\echo '=== W04 | LEAD | How many seconds of market time pass before the next BTCUSDT tick?'
SELECT t.tick_id, t.price,
       lead(t.price) OVER w                                             AS next_price,
       extract(epoch FROM lead(t.observed_at) OVER w - t.observed_at)::int AS seconds_to_next_tick
FROM price_ticks t
WHERE t.instrument_id = 6              -- BINANCE BTCUSDT
WINDOW w AS (ORDER BY t.observed_at, t.tick_id)
ORDER BY t.observed_at, t.tick_id;

\echo '=== W05 | moving average | What is the 3-tick moving average of the TCS price?'
SELECT t.tick_id, t.price,
       round(avg(t.price) OVER (ORDER BY t.observed_at, t.tick_id
                                ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2) AS moving_avg_3
FROM price_ticks t
WHERE t.instrument_id = 2              -- NSE TCS
ORDER BY t.observed_at, t.tick_id;
