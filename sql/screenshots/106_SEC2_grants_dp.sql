\echo '========================================================================'
\echo ' SEC2 | Granted privileges (psql command: dp) on core tables and the reporting views'
\echo '        r=SELECT a=INSERT w=UPDATE d=DELETE'
\echo '========================================================================'
\dp price_ticks
\dp users
\dp reporting.*
