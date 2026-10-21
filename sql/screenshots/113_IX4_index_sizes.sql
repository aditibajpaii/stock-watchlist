\echo '========================================================================'
\echo ' IX4 | Size of the table and each of its indexes (benchmark database)'
\echo '========================================================================'
SELECT indexrelid::regclass AS index_name,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size,
       left(pg_get_indexdef(indexrelid), 90) AS definition
FROM pg_index WHERE indrelid = 'price_ticks'::regclass ORDER BY 1;
SELECT pg_size_pretty(pg_relation_size('price_ticks')) AS table_only,
       pg_size_pretty(pg_indexes_size('price_ticks'))  AS all_indexes;
