-- =====================================================================
-- 07_subqueries.sql  -  Template category D (Subqueries), minimum 6
-- Coverage: scalar, single-row, multi-row (IN / ANY / ALL), correlated,
-- EXISTS, NOT EXISTS, NOT IN and its NULL pitfall (S10 + fix S11).
-- Read-only.
-- =====================================================================
\ir _guard.sql

\echo '=== S01 | scalar | What share of all ticks does each instrument have?'
-- The subquery returns exactly one value (the total) and is used like a constant.
SELECT i.symbol, count(*) AS ticks,
       round(100.0 * count(*) / (SELECT count(*) FROM price_ticks), 1) AS share_pct
FROM price_ticks t
JOIN instruments i ON i.instrument_id = t.instrument_id
GROUP BY i.symbol
ORDER BY ticks DESC, i.symbol;

\echo '=== S02 | single-row | Which tick is the latest one for NSE TCS?'
-- The outer subquery returns ONE row of two columns, compared with "=".
-- (If it returned two rows, PostgreSQL would raise an error.)
SELECT t.tick_id, t.price, t.observed_at
FROM price_ticks t
WHERE (t.instrument_id, t.observed_at) =
      (SELECT p.instrument_id, max(p.observed_at)
       FROM price_ticks p
       WHERE p.instrument_id = (SELECT instrument_id FROM instruments
                                WHERE exchange = 'NSE' AND symbol = 'TCS')
       GROUP BY p.instrument_id);

\echo '=== S03 | multi-row IN | Which users own a watchlist containing a Binance instrument?'
SELECT u.username, u.email
FROM users u
WHERE u.user_id IN (SELECT w.user_id
                    FROM watchlists w
                    JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
                    JOIN instruments i      ON i.instrument_id = wi.instrument_id
                    WHERE i.exchange = 'BINANCE')
ORDER BY u.username;

\echo '=== S04 | ALL, correlated | Which RELIANCE ticks were inside the alert band (above every BELOW threshold, below every ABOVE threshold)?'
SELECT t.tick_id, t.price
FROM price_ticks t
WHERE t.instrument_id = 1              -- NSE RELIANCE
  AND t.price > ALL (SELECT r.threshold FROM alert_rules r
                     WHERE r.instrument_id = t.instrument_id
                       AND r.direction = 'BELOW' AND r.is_active)
  AND t.price < ALL (SELECT r.threshold FROM alert_rules r
                     WHERE r.instrument_id = t.instrument_id
                       AND r.direction = 'ABOVE' AND r.is_active)
ORDER BY t.observed_at, t.tick_id;

\echo '=== S05 | ANY, correlated | Which instruments traded at or above ANY of their active ABOVE thresholds?'
SELECT DISTINCT i.symbol
FROM price_ticks t
JOIN instruments i ON i.instrument_id = t.instrument_id
WHERE t.price >= ANY (SELECT r.threshold FROM alert_rules r
                      WHERE r.instrument_id = t.instrument_id
                        AND r.direction = 'ABOVE' AND r.is_active)
ORDER BY i.symbol;

\echo '=== S06 | correlated | What is the latest price of each instrument?'
-- The subquery refers to the outer row (t.instrument_id), so it is
-- re-evaluated for every outer row.
SELECT i.symbol, t.price AS latest_price, t.tick_id
FROM price_ticks t
JOIN instruments i ON i.instrument_id = t.instrument_id
WHERE (t.observed_at, t.tick_id) = (SELECT p.observed_at, p.tick_id
                                    FROM price_ticks p
                                    WHERE p.instrument_id = t.instrument_id
                                    ORDER BY p.observed_at DESC, p.tick_id DESC
                                    LIMIT 1)
ORDER BY i.symbol;

\echo '=== S07 | EXISTS, correlated | Which instruments have produced at least one alert?'
SELECT i.symbol, i.name
FROM instruments i
WHERE EXISTS (SELECT 1
              FROM alert_events e
              JOIN price_ticks t ON t.tick_id = e.tick_id
              WHERE t.instrument_id = i.instrument_id)
ORDER BY i.symbol;

\echo '=== S08 | EXISTS, NOT EXISTS, correlated | Which watched instruments have never received a price tick?'
SELECT i.symbol, i.name
FROM instruments i
WHERE EXISTS     (SELECT 1 FROM watchlist_items wi WHERE wi.instrument_id = i.instrument_id)
  AND NOT EXISTS (SELECT 1 FROM price_ticks t      WHERE t.instrument_id  = i.instrument_id)
ORDER BY i.symbol;

\echo '=== S09 | NOT IN, multi-row IN | Which instruments have no alert rule at all?'
-- Safe: alert_rules.instrument_id is NOT NULL, so the list never contains NULL.
SELECT symbol, name
FROM instruments
WHERE instrument_id NOT IN (SELECT instrument_id FROM alert_rules)
ORDER BY symbol;

\echo '=== S10 | NOT IN, NULL pitfall | PITFALL: count ticks that never fired an alert, using NOT IN over an outer join'
-- The subquery starts from alert_rules and LEFT JOINs alert_events, so
-- rule 5 (never fired) contributes a NULL tick_id to the list.
-- x NOT IN (..., NULL) is never TRUE (it is FALSE or UNKNOWN), so the
-- answer is 0 - silently wrong. S11 gives the correct answer.
SELECT count(*) AS ticks_that_never_fired
FROM price_ticks
WHERE tick_id NOT IN (SELECT e.tick_id
                      FROM alert_rules r
                      LEFT JOIN alert_events e ON e.rule_id = r.rule_id);

\echo '=== S11 | NOT EXISTS, correlated | FIX: count ticks that never fired an alert, using NOT EXISTS'
SELECT count(*) AS ticks_that_never_fired
FROM price_ticks t
WHERE NOT EXISTS (SELECT 1 FROM alert_events e WHERE e.tick_id = t.tick_id);
