-- =====================================================================
-- 06_join_queries.sql  -  Template category C (Joins), minimum 6
-- Coverage: INNER, LEFT, RIGHT, FULL OUTER, SELF, CROSS
-- Read-only.
-- =====================================================================
\ir _guard.sql

\echo '=== J01 | INNER JOIN | Which user, rule and tick price are behind each alert event?'
SELECT e.event_id, u.username, i.symbol, r.direction, r.threshold,
       t.price AS tick_price, t.source_event_id
FROM alert_events e
INNER JOIN alert_rules r ON r.rule_id = e.rule_id
INNER JOIN users u       ON u.user_id = r.user_id
INNER JOIN price_ticks t ON t.tick_id = e.tick_id
INNER JOIN instruments i ON i.instrument_id = t.instrument_id
ORDER BY e.event_id;

\echo '=== J02 | LEFT JOIN | List every instrument with its alert rules, including instruments nobody monitors'
SELECT i.symbol, r.rule_id, r.direction, r.threshold, r.is_active
FROM instruments i
LEFT JOIN alert_rules r ON r.instrument_id = i.instrument_id
ORDER BY i.symbol, r.rule_id;

\echo '=== J03 | RIGHT JOIN | List every alert rule with the events it produced, including rules that never fired'
-- RIGHT JOIN keeps every row of the right-hand table (alert_rules).
-- It is the same as alert_rules LEFT JOIN alert_events.
SELECT r.rule_id, u.username, r.direction, r.threshold, r.is_active,
       e.event_id, e.tick_id
FROM alert_events e
RIGHT JOIN alert_rules r ON r.rule_id = e.rule_id
JOIN users u ON u.user_id = r.user_id
ORDER BY r.rule_id, e.event_id;

\echo '=== J04 | FULL OUTER JOIN | Where are watchlists and alert rules out of sync for each user?'
-- Left side: (user, instrument) pairs that are watched.
-- Right side: (user, instrument) pairs that have an alert rule.
-- FULL OUTER JOIN keeps unmatched pairs from BOTH sides.
SELECT u.username, i.symbol,
       CASE WHEN a.user_id IS NULL THEN 'watched, no alert rule'
            WHEN w.user_id IS NULL THEN 'alert rule, not on own watchlists'
            ELSE 'watched and alerted' END AS status
FROM (SELECT DISTINCT wl.user_id, wi.instrument_id
      FROM watchlists wl
      JOIN watchlist_items wi ON wi.watchlist_id = wl.watchlist_id) AS w
FULL OUTER JOIN
     (SELECT DISTINCT user_id, instrument_id FROM alert_rules) AS a
  ON a.user_id = w.user_id AND a.instrument_id = w.instrument_id
JOIN users u       ON u.user_id = coalesce(w.user_id, a.user_id)
JOIN instruments i ON i.instrument_id = coalesce(w.instrument_id, a.instrument_id)
ORDER BY u.username, i.symbol;

\echo '=== J05 | SELF JOIN | Which users have an ABOVE and a BELOW rule on the same instrument (a price band)?'
SELECT u.username, i.symbol,
       lo.threshold AS below_threshold,
       hi.threshold AS above_threshold,
       hi.threshold - lo.threshold AS band_width
FROM alert_rules hi
JOIN alert_rules lo ON lo.user_id = hi.user_id
                   AND lo.instrument_id = hi.instrument_id
                   AND hi.direction = 'ABOVE'
                   AND lo.direction = 'BELOW'
                   AND lo.threshold < hi.threshold
JOIN users u       ON u.user_id = hi.user_id
JOIN instruments i ON i.instrument_id = hi.instrument_id
ORDER BY u.username, i.symbol;

\echo '=== J06 | SELF JOIN | Pair each TCS tick with the previous TCS tick and the price change'
SELECT cur.tick_id, prev.tick_id AS previous_tick_id,
       prev.price AS previous_price, cur.price,
       cur.price - prev.price AS change
FROM price_ticks cur
JOIN price_ticks prev
  ON prev.instrument_id = cur.instrument_id
 AND prev.tick_id = (SELECT p.tick_id
                     FROM price_ticks p
                     WHERE p.instrument_id = cur.instrument_id
                       AND (p.observed_at, p.tick_id) < (cur.observed_at, cur.tick_id)
                     ORDER BY p.observed_at DESC, p.tick_id DESC
                     LIMIT 1)
WHERE cur.instrument_id = 2            -- NSE TCS (instrument_id from the seed)
ORDER BY cur.observed_at, cur.tick_id;

\echo '=== J07 | CROSS JOIN, LEFT JOIN | How many instruments does each user watch on each exchange, including zero?'
-- CROSS JOIN builds the complete user x exchange grid first, so a
-- combination with nothing in it still appears (with 0).
SELECT u.username, x.exchange,
       count(DISTINCT i.instrument_id) AS instruments_watched
FROM users u
CROSS JOIN (SELECT DISTINCT exchange FROM instruments) AS x
LEFT JOIN watchlists wl      ON wl.user_id = u.user_id
LEFT JOIN watchlist_items wi ON wi.watchlist_id = wl.watchlist_id
LEFT JOIN instruments i      ON i.instrument_id = wi.instrument_id
                            AND i.exchange = x.exchange
GROUP BY u.username, x.exchange
ORDER BY u.username, x.exchange;
