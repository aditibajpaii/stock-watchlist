\echo '========================================================================'
\echo ' CQ01 | Complex: 5 tables (users, alert_rules, alert_events, price_ticks, instruments)'
\echo '        Q: For each user and instrument, how many alerts fired, and when / at'
\echo '           what price was the most recent one?'
\echo '========================================================================'
SELECT u.username,
       i.symbol,
       count(*)                                              AS alerts,
       max(t.observed_at)::timestamp(0)                      AS last_alert_market_time,
       ((array_agg(t.price ORDER BY t.observed_at DESC))[1])::numeric(12,2) AS last_alert_price
FROM alert_events e
JOIN alert_rules r ON r.rule_id = e.rule_id
JOIN users u       ON u.user_id = r.user_id
JOIN price_ticks t ON t.tick_id = e.tick_id
JOIN instruments i ON i.instrument_id = r.instrument_id
GROUP BY u.username, i.symbol
ORDER BY u.username, alerts DESC, i.symbol;
