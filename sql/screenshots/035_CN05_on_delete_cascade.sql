\echo '========================================================================'
\echo ' CN05 | ON DELETE CASCADE: deleting a user removes only user-owned data'
\echo '        (watchlists, items, rules, alert history). Rolled back afterwards.'
\echo '========================================================================'
BEGIN;
SELECT (SELECT count(*) FROM watchlists  WHERE user_id = 1) AS arjun_watchlists,
       (SELECT count(*) FROM alert_rules WHERE user_id = 1) AS arjun_rules,
       (SELECT count(*) FROM alert_events e JOIN alert_rules r USING (rule_id)
         WHERE r.user_id = 1)                               AS arjun_alerts,
       (SELECT count(*) FROM price_ticks)                   AS price_ticks;

DELETE FROM users WHERE username = 'arjun';

SELECT (SELECT count(*) FROM watchlists  WHERE user_id = 1) AS arjun_watchlists,
       (SELECT count(*) FROM alert_rules WHERE user_id = 1) AS arjun_rules,
       (SELECT count(*) FROM alert_events e JOIN alert_rules r USING (rule_id)
         WHERE r.user_id = 1)                               AS arjun_alerts,
       (SELECT count(*) FROM price_ticks)                   AS price_ticks;
ROLLBACK;

SELECT user_id, username FROM users ORDER BY user_id;
