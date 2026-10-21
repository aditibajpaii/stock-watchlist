SET ROLE sw_analyst;
SELECT current_user, count(*) FROM price_ticks;
DELETE FROM price_ticks;
SELECT * FROM users;
RESET ROLE;

SET ROLE arjun;
SELECT * FROM alert_rules;
CALL reporting.sp_set_rule_active(1, false);
SELECT current_user, count(*) FROM reporting.v_my_alerts;
RESET ROLE;
