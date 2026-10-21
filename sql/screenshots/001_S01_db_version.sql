\echo '========================================================================'
\echo ' S01 | Database server and session'
\echo '========================================================================'
SELECT version();
SELECT current_database() AS database, current_user AS connected_as,
       current_setting('TimeZone') AS time_zone,
       current_setting('default_transaction_isolation') AS isolation_level;
