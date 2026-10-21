BEGIN;
SELECT has_table_privilege('sw_analyst', 'price_ticks', 'SELECT');
SET ROLE sw_analyst;
SELECT count(*) FROM price_ticks;
RESET ROLE;

REVOKE SELECT ON price_ticks FROM sw_analyst;
SELECT has_table_privilege('sw_analyst', 'price_ticks', 'SELECT');
SET ROLE sw_analyst;
SELECT count(*) FROM price_ticks;
ROLLBACK;

SELECT has_table_privilege('sw_analyst', 'price_ticks', 'SELECT');
