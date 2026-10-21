\echo '========================================================================'
\echo ' S12 | Creating views, procedures, functions, cursors, roles and grants'
\echo '       (sql/09_review2_objects.sql, schema reporting)'
\echo '========================================================================'
\set QUIET off
\set ECHO none
SET client_min_messages = warning;
\i sql/09_review2_objects.sql
