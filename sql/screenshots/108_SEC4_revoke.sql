\echo '========================================================================'
\echo ' SEC4 | REVOKE demonstration: before / after (inside a transaction, rolled back)'
\echo '========================================================================'
BEGIN;
SELECT has_table_privilege('sw_analyst', 'price_ticks', 'SELECT') AS before_revoke;
SET ROLE sw_analyst;
SELECT count(*) AS analyst_can_read FROM price_ticks;
RESET ROLE;

REVOKE SELECT ON price_ticks FROM sw_analyst;
SELECT has_table_privilege('sw_analyst', 'price_ticks', 'SELECT') AS after_revoke;
SET ROLE sw_analyst;
SELECT count(*) FROM price_ticks;
ROLLBACK;
SELECT has_table_privilege('sw_analyst', 'price_ticks', 'SELECT') AS after_rollback;
