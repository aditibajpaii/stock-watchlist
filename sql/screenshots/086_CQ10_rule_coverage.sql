\echo '========================================================================'
\echo ' CQ10 | Complex: 5 tables + conditional aggregation (FILTER)'
\echo '        Q: For every watched instrument, does its owner have an ABOVE rule,'
\echo '           a BELOW rule, both, or none?'
\echo '========================================================================'
SELECT u.username, i.symbol,
       count(r.rule_id) FILTER (WHERE r.direction = 'ABOVE') AS above_rules,
       count(r.rule_id) FILTER (WHERE r.direction = 'BELOW') AS below_rules,
       CASE WHEN count(r.rule_id) = 0 THEN 'no protection'
            WHEN count(DISTINCT r.direction) = 2 THEN 'both sides'
            ELSE 'one side only' END                         AS coverage
FROM users u
JOIN watchlists w       ON w.user_id = u.user_id
JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
JOIN instruments i      ON i.instrument_id = wi.instrument_id
LEFT JOIN alert_rules r ON r.user_id = u.user_id
                       AND r.instrument_id = i.instrument_id
                       AND r.is_active
GROUP BY u.username, i.symbol
ORDER BY u.username, i.symbol;
