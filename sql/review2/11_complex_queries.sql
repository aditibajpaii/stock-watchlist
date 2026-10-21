-- =====================================================================
-- 11_complex_queries.sql  -  Template "Complex Business Queries", minimum 10
-- Each uses >= 3 tables OR a nested/analytic construct.
-- The @expected line of every query was written from the seed data and
-- data/replay_prices.csv BEFORE the query was first executed; it is not
-- edited afterwards. QUERY_EVIDENCE.md shows the actual output next to it.
-- Read-only.
-- =====================================================================
\ir _guard.sql

\echo '=== CQ01 | 3 tables, aggregate | Which users have the most alert rules, how many are active, and how many alerts did they receive?'
-- @expected: 3 rows: arjun 3 rules / 3 active / 5 alerts; priya 2 / 1 / 2; kavya 1 / 1 / 1.
-- @explain: users -> alert_rules (inner: users with rules) -> alert_events (LEFT, so a rule with no events still counts). count(DISTINCT rule_id) avoids the fan-out caused by joining many events per rule; FILTER counts only active rules.
SELECT u.username,
       count(DISTINCT r.rule_id)                            AS rules,
       count(DISTINCT r.rule_id) FILTER (WHERE r.is_active) AS active_rules,
       count(e.event_id)                                    AS alerts_received
FROM users u
JOIN alert_rules r       ON r.user_id = u.user_id
LEFT JOIN alert_events e ON e.rule_id = r.rule_id
GROUP BY u.username
ORDER BY rules DESC, alerts_received DESC, u.username;

\echo '=== CQ02 | 5 tables, CTE, window RANK | Which instrument moved the most (first to last tick), and which watchlists hold it?'
-- @expected: 2 rows, both RELIANCE 2985.50 -> 2788.00 (-6.62 %): arjun "Long Term" and kavya "Main".
-- @explain: The CTE takes each instrument's first and last price with ordered array_agg; RANK orders instruments by absolute percentage move; the outer query keeps rank 1 and joins watchlist_items -> watchlists -> users to list where it is held.
WITH moves AS (
    SELECT t.instrument_id,
           (array_agg(t.price ORDER BY t.observed_at, t.tick_id))[1]           AS first_price,
           (array_agg(t.price ORDER BY t.observed_at DESC, t.tick_id DESC))[1] AS last_price
    FROM price_ticks t
    GROUP BY t.instrument_id
), ranked AS (
    SELECT m.*,
           rank() OVER (ORDER BY abs(m.last_price - m.first_price) / m.first_price DESC) AS move_rank
    FROM moves m
)
SELECT i.symbol,
       round(r.first_price, 2) AS first_price,
       round(r.last_price, 2)  AS last_price,
       round(100 * (r.last_price - r.first_price) / r.first_price, 2) AS change_pct,
       u.username, w.name AS watchlist
FROM ranked r
JOIN instruments i      ON i.instrument_id = r.instrument_id
JOIN watchlist_items wi ON wi.instrument_id = r.instrument_id
JOIN watchlists w       ON w.watchlist_id = wi.watchlist_id
JOIN users u            ON u.user_id = w.user_id
WHERE r.move_rank = 1
ORDER BY u.username, w.name;

\echo '=== CQ03 | 6 tables, aggregate | Which watchlists contain instruments that triggered alerts, and how many alerts were there?'
-- @expected: 4 rows: arjun Long Term 5 alerts on 2 instruments (RELIANCE, TCS); kavya Main 5 on 2 (BTCUSDT, RELIANCE); arjun Crypto 3 on 2 (BTCUSDT, ETHUSDT); priya Tech 2 on 1 (TCS). priya Auto (M&M, no ticks) does not appear.
-- @explain: Inner joins from watchlists through watchlist_items and price_ticks to alert_events keep only watchlists holding an instrument with at least one alert event. Alerts are market events on the instrument (any user rule), not only the list owner alerts.
SELECT u.username, w.name AS watchlist,
       count(DISTINCT t.instrument_id) AS instruments_with_alerts,
       count(e.event_id)               AS alerts_on_those_instruments,
       string_agg(DISTINCT i.symbol, ', ' ORDER BY i.symbol) AS symbols
FROM watchlists w
JOIN users u            ON u.user_id = w.user_id
JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
JOIN instruments i      ON i.instrument_id = wi.instrument_id
JOIN price_ticks t      ON t.instrument_id = wi.instrument_id
JOIN alert_events e     ON e.tick_id = t.tick_id
GROUP BY u.username, w.name
ORDER BY alerts_on_those_instruments DESC, u.username, w.name;

\echo '=== CQ04 | 5 tables, window LAG, HAVING | Which rules produced repeated alerts, and did the gap between alerts always respect the cooldown?'
-- @expected: 3 rows: rule 1 arjun RELIANCE ABOVE 3000 (cooldown 300) 2 events, gap 380 s, true; rule 3 arjun BTCUSDT ABOVE 100000 (60) 2 events, 130 s, true; rule 4 priya TCS BELOW 3500 (0) 2 events, 95 s, true.
-- @explain: LAG over each rule events (ordered by the market time of the tick that fired them) gives the gap since the previous alert of the same rule; HAVING count > 1 keeps repeated rules; bool_and checks every gap >= cooldown, which is the rule the trigger enforces.
WITH ev AS (
    SELECT e.rule_id,
           t.observed_at - lag(t.observed_at) OVER (PARTITION BY e.rule_id
                                                    ORDER BY t.observed_at, t.tick_id) AS gap
    FROM alert_events e
    JOIN price_ticks t ON t.tick_id = e.tick_id
)
SELECT r.rule_id, u.username, i.symbol, r.direction, r.threshold, r.cooldown_seconds,
       count(*)                                  AS events,
       min(extract(epoch FROM ev.gap))::int      AS smallest_gap_s,
       bool_and(ev.gap IS NULL
                OR ev.gap >= make_interval(secs => r.cooldown_seconds)) AS cooldown_respected
FROM ev
JOIN alert_rules r ON r.rule_id = ev.rule_id
JOIN users u       ON u.user_id = r.user_id
JOIN instruments i ON i.instrument_id = r.instrument_id
GROUP BY r.rule_id, u.username, i.symbol, r.direction, r.threshold, r.cooldown_seconds
HAVING count(*) > 1
ORDER BY r.rule_id;

\echo '=== CQ05 | 3 tables, EXISTS / NOT EXISTS | Which instruments have price data but no active alert rule?'
-- @expected: 1 row: INFY (Infosys Ltd), 2 ticks, 1 inactive rule (priya rule 5).
-- @explain: EXISTS keeps instruments with at least one tick; NOT EXISTS removes those with an active rule; the scalar subqueries in the SELECT list show the supporting counts.
SELECT i.symbol, i.name,
       (SELECT count(*) FROM price_ticks t
         WHERE t.instrument_id = i.instrument_id)                        AS ticks,
       (SELECT count(*) FROM alert_rules r
         WHERE r.instrument_id = i.instrument_id AND NOT r.is_active)    AS inactive_rules
FROM instruments i
WHERE EXISTS     (SELECT 1 FROM price_ticks t WHERE t.instrument_id = i.instrument_id)
  AND NOT EXISTS (SELECT 1 FROM alert_rules r
                  WHERE r.instrument_id = i.instrument_id AND r.is_active)
ORDER BY i.symbol;

\echo '=== CQ06 | 4 tables, LATERAL | Which active rules can fire on the next crossing, and how far is the latest price from each threshold?'
-- @expected: 5 rows. Armed: rule 1 arjun RELIANCE ABOVE 3000, latest 2788.00, 7.60 %. Past threshold (must move back first): rule 6 kavya ETHUSDT BELOW 3000, 2994.60, 0.18 %; rule 4 priya TCS BELOW 3500, 3490.00, 0.29 %; rule 3 arjun BTCUSDT ABOVE 100000, 100400.00, 0.40 %; rule 2 arjun RELIANCE BELOW 2800, 2788.00, 0.43 %.
-- @explain: LATERAL fetches each rule instrument latest tick (served by ix_price_ticks_instrument_time). Edge-triggered rules can only fire when the price is on the non-triggered side (ABOVE: below the threshold; BELOW: above it); the cooldown can still suppress that alert.
SELECT r.rule_id, u.username, i.symbol, r.direction, r.threshold,
       lp.price AS latest_price,
       CASE WHEN (r.direction = 'ABOVE' AND lp.price < r.threshold)
              OR (r.direction = 'BELOW' AND lp.price > r.threshold)
            THEN 'armed: can fire on next crossing'
            ELSE 'past threshold: must move back first' END AS state,
       round(100 * abs(r.threshold - lp.price) / lp.price, 2) AS distance_pct
FROM alert_rules r
JOIN users u       ON u.user_id = r.user_id
JOIN instruments i ON i.instrument_id = r.instrument_id
JOIN LATERAL (SELECT t.price
              FROM price_ticks t
              WHERE t.instrument_id = r.instrument_id
              ORDER BY t.observed_at DESC, t.tick_id DESC
              LIMIT 1) AS lp ON true
WHERE r.is_active
ORDER BY state, distance_pct;

\echo '=== CQ07 | 5 tables, derived table, scalar subqueries | Give a per-instrument activity dashboard: ticks, price range, alerts and watching users'
-- @expected: 7 rows ordered by ticks: RELIANCE 12 ticks 2788.00-3030.00, 3 alerts, 2 users; BTCUSDT 8, 99450.00-100400.00, 2, 2; TCS 6, 3485.50-3552.00, 2, 2; ETHUSDT 2, 2994.60-3048.10, 1, 1; INFY 2, 1585.00-1612.00, 0, 2; HDFCBANK 0, no range, 0, 1; M&M 0, no range, 0, 1.
-- @explain: A derived table aggregates ticks per instrument and is LEFT JOINed so untraded instruments stay; correlated scalar subqueries count alerts (via the firing tick) and distinct watching users, avoiding the row multiplication a single multi-join GROUP BY would cause.
SELECT i.exchange, i.symbol,
       coalesce(ts.ticks, 0)  AS ticks,
       round(ts.min_price, 2) AS min_price,
       round(ts.max_price, 2) AS max_price,
       (SELECT count(*)
          FROM alert_events e JOIN price_ticks t ON t.tick_id = e.tick_id
         WHERE t.instrument_id = i.instrument_id)           AS alerts,
       (SELECT count(DISTINCT w.user_id)
          FROM watchlist_items wi JOIN watchlists w ON w.watchlist_id = wi.watchlist_id
         WHERE wi.instrument_id = i.instrument_id)          AS watching_users
FROM instruments i
LEFT JOIN (SELECT instrument_id, count(*) AS ticks,
                  min(price) AS min_price, max(price) AS max_price
           FROM price_ticks
           GROUP BY instrument_id) AS ts ON ts.instrument_id = i.instrument_id
ORDER BY ticks DESC, i.symbol;

\echo '=== CQ08 | 7 tables, NOT EXISTS | Which users received an alert for an instrument that is not on any of their own watchlists?'
-- @expected: 1 row: kavya, ETHUSDT, BELOW 3000, event 4, tick price 2994.60 (ETHUSDT is not in kavya "Main").
-- @explain: The inner join chain identifies who owns the rule behind each event and which instrument the tick was for; the correlated NOT EXISTS checks that user own watchlists for that instrument.
SELECT u.username, i.symbol, r.direction, r.threshold, e.event_id, t.price AS tick_price
FROM alert_events e
JOIN alert_rules r ON r.rule_id = e.rule_id
JOIN users u       ON u.user_id = r.user_id
JOIN price_ticks t ON t.tick_id = e.tick_id
JOIN instruments i ON i.instrument_id = t.instrument_id
WHERE NOT EXISTS (SELECT 1
                  FROM watchlists w
                  JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
                  WHERE w.user_id = r.user_id
                    AND wi.instrument_id = t.instrument_id)
ORDER BY e.event_id;

\echo '=== CQ09 | 5 tables, CTE, window LAG | By how much did the price cross the threshold for each alert, and was it a genuine crossing?'
-- @expected: 8 rows, all genuine_crossing = true, ordered by overshoot_pct: event 7 RELIANCE 2990.00->3021.50 (21.50, 0.717); event 6 BTCUSDT 99800->100400 (400, 0.400); event 5 TCS 3512.00->3490.00 (10, 0.286); event 4 ETHUSDT 3048.10->2994.60 (5.40, 0.180); event 8 RELIANCE 3030.00->2795.00 (5, 0.179); event 3 BTCUSDT 99880->100120 (120, 0.120); event 1 RELIANCE 2994.00->3002.40 (2.40, 0.080); event 2 TCS 3531.25->3498.00 (2, 0.057).
-- @explain: LAG gives the previous tick of the same instrument in (observed_at, tick_id) order, the same ordering the alert trigger uses. genuine_crossing re-checks the edge condition on the stored data: previous price on one side, firing price on or past the threshold.
WITH seq AS (
    SELECT t.tick_id, t.price,
           lag(t.price) OVER (PARTITION BY t.instrument_id
                              ORDER BY t.observed_at, t.tick_id) AS previous_price
    FROM price_ticks t
)
SELECT e.event_id, u.username, i.symbol, r.direction, round(r.threshold, 2) AS threshold,
       round(s.previous_price, 2) AS previous_price,
       round(s.price, 2)          AS firing_price,
       round(abs(s.price - r.threshold), 2)                   AS overshoot,
       round(100 * abs(s.price - r.threshold) / r.threshold, 3) AS overshoot_pct,
       (r.direction = 'ABOVE' AND s.previous_price < r.threshold AND s.price >= r.threshold)
    OR (r.direction = 'BELOW' AND s.previous_price > r.threshold AND s.price <= r.threshold)
                                                              AS genuine_crossing
FROM alert_events e
JOIN alert_rules r ON r.rule_id = e.rule_id
JOIN users u       ON u.user_id = r.user_id
JOIN seq s         ON s.tick_id = e.tick_id
JOIN instruments i ON i.instrument_id = r.instrument_id
ORDER BY overshoot_pct DESC;

\echo '=== CQ10 | 5 tables, scalar subqueries | Give a per-user dashboard: watchlists, instruments watched, active rules and alerts received'
-- @expected: 3 rows: arjun 2 watchlists, 5 instruments, 3 active rules, 5 alerts; kavya 1, 3, 1, 1; priya 2, 3, 1, 2.
-- @explain: Each figure is an independent correlated scalar subquery, so counts from different child tables cannot multiply each other.
SELECT u.username,
       (SELECT count(*) FROM watchlists w WHERE w.user_id = u.user_id) AS watchlists,
       (SELECT count(DISTINCT wi.instrument_id)
          FROM watchlists w JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
         WHERE w.user_id = u.user_id)                                AS instruments_watched,
       (SELECT count(*) FROM alert_rules r
         WHERE r.user_id = u.user_id AND r.is_active)                AS active_rules,
       (SELECT count(*)
          FROM alert_events e JOIN alert_rules r ON r.rule_id = e.rule_id
         WHERE r.user_id = u.user_id)                                AS alerts_received
FROM users u
ORDER BY u.username;

\echo '=== CQ11 | CTE, window RANK PARTITION BY | Which instrument was the biggest mover on each exchange?'
-- @expected: 2 rows: BINANCE ETHUSDT -1.76 %; NSE RELIANCE -6.62 %.
-- @explain: Nested/analytic (2 tables): the CTE computes every instrument first-to-last % change, RANK() restarts per exchange (PARTITION BY exchange) and the outer filter keeps rank 1.
WITH moves AS (
    SELECT i.exchange, i.symbol,
           100 * ((array_agg(t.price ORDER BY t.observed_at DESC, t.tick_id DESC))[1]
                  - (array_agg(t.price ORDER BY t.observed_at, t.tick_id))[1])
               / (array_agg(t.price ORDER BY t.observed_at, t.tick_id))[1] AS change_pct
    FROM price_ticks t
    JOIN instruments i ON i.instrument_id = t.instrument_id
    GROUP BY i.exchange, i.symbol
)
SELECT exchange, symbol, round(change_pct, 2) AS change_pct, move_rank
FROM (SELECT m.*,
             rank() OVER (PARTITION BY m.exchange ORDER BY abs(m.change_pct) DESC) AS move_rank
      FROM moves m) AS x
WHERE move_rank = 1
ORDER BY exchange;

\echo '=== CQ12 | 5 tables, CTE, LEFT JOIN | Which watchlist performed best (equal-weighted average % change of its instruments)?'
-- @expected: 5 rows: priya Tech 2 instruments / 2 priced / -0.02; arjun Crypto 2 / 2 / -0.40; kavya Main 3 / 3 / -1.32; arjun Long Term 3 / 2 / -4.18 (HDFCBANK has no ticks); priya Auto 1 / 0 / null.
-- @explain: The CTE gives each instrument % move; LEFT JOIN keeps watchlist items without prices, avg() ignores their NULLs, and count(m.change_pct) shows how many instruments were actually averaged.
WITH moves AS (
    SELECT t.instrument_id,
           100 * ((array_agg(t.price ORDER BY t.observed_at DESC, t.tick_id DESC))[1]
                  - (array_agg(t.price ORDER BY t.observed_at, t.tick_id))[1])
               / (array_agg(t.price ORDER BY t.observed_at, t.tick_id))[1] AS change_pct
    FROM price_ticks t
    GROUP BY t.instrument_id
)
SELECT u.username, w.name AS watchlist,
       count(wi.instrument_id)     AS instruments,
       count(m.change_pct)         AS instruments_with_prices,
       round(avg(m.change_pct), 2) AS avg_change_pct
FROM watchlists w
JOIN users u            ON u.user_id = w.user_id
JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
LEFT JOIN moves m       ON m.instrument_id = wi.instrument_id
GROUP BY u.username, w.name
ORDER BY avg_change_pct DESC NULLS LAST, u.username, w.name;
