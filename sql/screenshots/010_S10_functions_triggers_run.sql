\echo '========================================================================'
\echo ' S10 | Creating ingest_tick() and the 2 triggers (sql/03_functions_triggers.sql)'
\echo '========================================================================'
\set QUIET off
\set ECHO none
SET client_min_messages = warning;
\i sql/03_functions_triggers.sql
