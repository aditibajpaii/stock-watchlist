\echo '========================================================================'
\echo ' IX1 | All indexes: 14 created by PK / UNIQUE constraints + 1 performance index'
\echo '========================================================================'
SELECT tablename, indexname, left(indexdef, 95) AS definition
FROM pg_indexes
WHERE schemaname = 'public'
ORDER BY tablename, indexname;
