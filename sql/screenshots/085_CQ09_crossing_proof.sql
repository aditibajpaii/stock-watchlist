\echo '========================================================================'
\echo ' CQ09 | Complex: window functions + 4 tables'
\echo '        Q: For every fired alert, prove it was a real crossing: show the'
\echo '           previous price, the new price and the tick''s position in history'
\echo '========================================================================'
WITH ordered AS (
    SELECT t.tick_id, t.instrument_id, t.price, t.observed_at,
           LAG(t.price)  OVER w AS prev_price,
           ROW_NUMBER()  OVER w AS tick_no
    FROM price_ticks t
    WINDOW w AS (PARTITION BY t.instrument_id ORDER BY t.observed_at, t.tick_id))
SELECT e.event_id, u.username, i.symbol, r.direction,
       r.threshold::numeric(12,2)   AS threshold,
       o.prev_price::numeric(12,2)  AS prev_price,
       o.price::numeric(12,2)       AS new_price,
       o.tick_no                    AS nth_tick,
       CASE WHEN r.direction = 'ABOVE' THEN o.prev_price < r.threshold AND o.price >= r.threshold
            ELSE o.prev_price > r.threshold AND o.price <= r.threshold END AS is_crossing
FROM alert_events e
JOIN ordered o     ON o.tick_id = e.tick_id
JOIN alert_rules r ON r.rule_id = e.rule_id
JOIN users u       ON u.user_id = r.user_id
JOIN instruments i ON i.instrument_id = r.instrument_id
ORDER BY e.event_id;
