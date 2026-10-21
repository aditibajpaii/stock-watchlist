-- =====================================================================
-- 08_set_operations.sql  -  Template category E (Set operations), minimum 4
-- Coverage: UNION, UNION ALL, INTERSECT, EXCEPT
-- Both sides of every operation have the same column count and types.
-- Cross-check: SET03 + SET04 + SET05 rows = SET01 rows = J04 rows.
-- Read-only.
-- =====================================================================
\ir _guard.sql

\echo '=== SET01 | UNION | Which instruments is each user interested in (watched OR alerted), without duplicates?'
SELECT u.username, i.symbol
FROM watchlists w
JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
JOIN users u            ON u.user_id = w.user_id
JOIN instruments i      ON i.instrument_id = wi.instrument_id
UNION
SELECT u.username, i.symbol
FROM alert_rules r
JOIN users u       ON u.user_id = r.user_id
JOIN instruments i ON i.instrument_id = r.instrument_id
ORDER BY username, symbol;

\echo '=== SET02 | UNION ALL | Show one RELIANCE timeline of every tick and every alert, in market-time order'
-- UNION ALL keeps every row and skips the duplicate-removal step;
-- ticks and alerts are different kinds of rows, so nothing may be dropped.
SELECT t.observed_at AS market_time, 1 AS seq, 'tick' AS kind,
       t.price AS price, NULL AS detail
FROM price_ticks t
WHERE t.instrument_id = 1              -- NSE RELIANCE
UNION ALL
SELECT t.observed_at, 2, 'ALERT', t.price,
       u.username || ' ' || r.direction || ' ' || round(r.threshold, 2)
FROM alert_events e
JOIN alert_rules r ON r.rule_id = e.rule_id
JOIN users u       ON u.user_id = r.user_id
JOIN price_ticks t ON t.tick_id = e.tick_id
WHERE t.instrument_id = 1
ORDER BY market_time, seq;

\echo '=== SET03 | INTERSECT | Which (user, instrument) pairs are both watched AND covered by an alert rule?'
SELECT u.username, i.symbol
FROM watchlists w
JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
JOIN users u            ON u.user_id = w.user_id
JOIN instruments i      ON i.instrument_id = wi.instrument_id
INTERSECT
SELECT u.username, i.symbol
FROM alert_rules r
JOIN users u       ON u.user_id = r.user_id
JOIN instruments i ON i.instrument_id = r.instrument_id
ORDER BY username, symbol;

\echo '=== SET04 | EXCEPT | Which instruments does each user watch but has no alert rule for?'
SELECT u.username, i.symbol
FROM watchlists w
JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
JOIN users u            ON u.user_id = w.user_id
JOIN instruments i      ON i.instrument_id = wi.instrument_id
EXCEPT
SELECT u.username, i.symbol
FROM alert_rules r
JOIN users u       ON u.user_id = r.user_id
JOIN instruments i ON i.instrument_id = r.instrument_id
ORDER BY username, symbol;

\echo '=== SET05 | EXCEPT | Which alert rules are on instruments the user does not watch (the reverse difference)?'
SELECT u.username, i.symbol
FROM alert_rules r
JOIN users u       ON u.user_id = r.user_id
JOIN instruments i ON i.instrument_id = r.instrument_id
EXCEPT
SELECT u.username, i.symbol
FROM watchlists w
JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
JOIN users u            ON u.user_id = w.user_id
JOIN instruments i      ON i.instrument_id = wi.instrument_id
ORDER BY username, symbol;
