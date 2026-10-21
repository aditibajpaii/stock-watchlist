\echo '========================================================================'
\echo ' V3 | Security (row-restricting) view: reporting.v_my_alerts'
\echo '      Each database role sees ONLY its own alerts (username = current_user)'
\echo '========================================================================'
\sv reporting.v_my_alerts
SET ROLE arjun;
SELECT current_user, event_id, symbol, direction, threshold::numeric(12,2), price::numeric(12,2)
FROM reporting.v_my_alerts ORDER BY event_id;
SET ROLE priya;
SELECT current_user, event_id, symbol, direction, threshold::numeric(12,2), price::numeric(12,2)
FROM reporting.v_my_alerts ORDER BY event_id;
RESET ROLE;
