-- =====================================================================
-- 05_aggregate_queries.sql  -  Template category B (Aggregate), minimum 5
-- Coverage: COUNT, SUM, AVG, MIN, MAX, GROUP BY, HAVING, and one query
-- that contrasts WHERE (row filter) with HAVING (group filter).
-- Read-only.
-- =====================================================================
\ir _guard.sql

\echo '=== AG01 | COUNT, GROUP BY, ORDER BY | How many price ticks does each instrument have?'
SELECT i.symbol, count(*) AS ticks
FROM price_ticks t
JOIN instruments i ON i.instrument_id = t.instrument_id
GROUP BY i.symbol
ORDER BY ticks DESC, i.symbol;

\echo '=== AG02 | MIN, MAX, AVG, GROUP BY | What was the lowest, highest and average price of each instrument?'
SELECT i.symbol,
       min(t.price)           AS min_price,
       max(t.price)           AS max_price,
       round(avg(t.price), 2) AS avg_price
FROM price_ticks t
JOIN instruments i ON i.instrument_id = t.instrument_id
GROUP BY i.symbol
ORDER BY i.symbol;

\echo '=== AG03 | SUM, COUNT, GROUP BY | How much volume is known per instrument, and how many ticks had unknown volume?'
SELECT i.symbol,
       sum(t.volume)               AS known_volume,      -- SUM ignores NULLs
       count(t.volume)             AS ticks_with_volume, -- COUNT(column) skips NULLs
       count(*) - count(t.volume)  AS ticks_volume_unknown
FROM price_ticks t
JOIN instruments i ON i.instrument_id = t.instrument_id
GROUP BY i.symbol
ORDER BY i.symbol;

\echo '=== AG04 | COUNT, GROUP BY, HAVING, WHERE vs HAVING | Which users have more than one ACTIVE alert rule?'
-- WHERE removes inactive rule rows BEFORE grouping;
-- HAVING removes whole user groups AFTER counting.
SELECT u.username, count(*) AS active_rules
FROM alert_rules r
JOIN users u ON u.user_id = r.user_id
WHERE r.is_active
GROUP BY u.username
HAVING count(*) > 1
ORDER BY u.username;

\echo '=== AG05 | COUNT, GROUP BY, HAVING | Same question without the WHERE filter: which users have more than one rule of any status?'
SELECT u.username, count(*) AS rules_any_status
FROM alert_rules r
JOIN users u ON u.user_id = r.user_id
GROUP BY u.username
HAVING count(*) > 1
ORDER BY u.username;

\echo '=== AG06 | COUNT, GROUP BY | How many distinct instruments does each user watch across all of their watchlists?'
SELECT u.username,
       count(DISTINCT w.watchlist_id)   AS watchlists,
       count(DISTINCT wi.instrument_id) AS distinct_instruments
FROM users u
JOIN watchlists w       ON w.user_id = u.user_id
JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
GROUP BY u.username
ORDER BY u.username;
