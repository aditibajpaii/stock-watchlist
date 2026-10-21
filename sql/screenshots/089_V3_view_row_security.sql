\sv reporting.v_my_alerts
SET ROLE arjun;
SELECT current_user, event_id, symbol, direction, threshold, price FROM reporting.v_my_alerts;
SET ROLE priya;
SELECT current_user, event_id, symbol, direction, threshold, price FROM reporting.v_my_alerts;
RESET ROLE;
