\echo '========================================================================'
\echo ' CQ07 | Complex: correlated scalar subqueries over 5 tables + RANK'
\echo '        Q: How engaged is each user (lists, items, active rules, alerts)?'
\echo '========================================================================'
SELECT username, watchlists, items, active_rules, alerts,
       RANK() OVER (ORDER BY alerts DESC, active_rules DESC) AS engagement_rank
FROM (
    SELECT u.username,
           (SELECT count(*) FROM watchlists w WHERE w.user_id = u.user_id) AS watchlists,
           (SELECT count(*) FROM watchlists w
              JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
             WHERE w.user_id = u.user_id)                                 AS items,
           (SELECT count(*) FROM alert_rules r
             WHERE r.user_id = u.user_id AND r.is_active)                 AS active_rules,
           (SELECT count(*) FROM alert_events e
              JOIN alert_rules r ON r.rule_id = e.rule_id
             WHERE r.user_id = u.user_id)                                 AS alerts
    FROM users u) s
ORDER BY engagement_rank, username;
