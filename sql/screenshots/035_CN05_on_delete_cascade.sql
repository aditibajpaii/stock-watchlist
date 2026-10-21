BEGIN;
SELECT (SELECT count(*) FROM watchlists WHERE user_id = 1) AS watchlists,
       (SELECT count(*) FROM alert_rules WHERE user_id = 1) AS rules,
       (SELECT count(*) FROM alert_events) AS alerts,
       (SELECT count(*) FROM price_ticks) AS ticks;

DELETE FROM users WHERE user_id = 1;

SELECT (SELECT count(*) FROM watchlists WHERE user_id = 1) AS watchlists,
       (SELECT count(*) FROM alert_rules WHERE user_id = 1) AS rules,
       (SELECT count(*) FROM alert_events) AS alerts,
       (SELECT count(*) FROM price_ticks) AS ticks;
ROLLBACK;

SELECT * FROM users;
