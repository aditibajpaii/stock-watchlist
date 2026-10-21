\echo '========================================================================'
\echo ' SEC5 | Least privilege: restricted roles attempt forbidden operations'
\echo '        (SET ROLE switches this session to the restricted role)'
\echo '========================================================================'
SET ROLE sw_analyst;
SELECT current_user, count(*) AS ticks_visible FROM price_ticks;
DELETE FROM price_ticks;
SELECT * FROM users;
RESET ROLE;

SET ROLE arjun;
SELECT * FROM alert_rules;
CALL reporting.sp_set_rule_active(1, false);
SELECT current_user, count(*) AS my_alerts FROM reporting.v_my_alerts;
RESET ROLE;
