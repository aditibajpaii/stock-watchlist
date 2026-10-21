\echo '========================================================================'
\echo ' P3 | Stored procedure reporting.sp_set_rule_active (enable / disable a rule)'
\echo '      inside a transaction that is rolled back'
\echo '========================================================================'
\sf reporting.sp_set_rule_active
BEGIN;
SELECT rule_id, direction, threshold::numeric(12,2), is_active FROM alert_rules WHERE rule_id = 5;
CALL reporting.sp_set_rule_active(5, true);
SELECT rule_id, direction, threshold::numeric(12,2), is_active FROM alert_rules WHERE rule_id = 5;
CALL reporting.sp_set_rule_active(999, false);
ROLLBACK;
