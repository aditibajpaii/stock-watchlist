\echo '========================================================================'
\echo ' S22 | Relationships: the 8 foreign keys and their ON DELETE rule'
\echo '       CASCADE = user-owned data, RESTRICT = shared market data'
\echo '========================================================================'
SELECT c.confrelid::regclass AS parent_table,
       c.conrelid::regclass  AS child_table,
       c.conname             AS foreign_key,
       (SELECT string_agg(a.attname, ', ') FROM pg_attribute a
         WHERE a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)) AS fk_column,
       CASE c.confdeltype WHEN 'c' THEN 'CASCADE' WHEN 'r' THEN 'RESTRICT' END AS on_delete
FROM pg_constraint c
WHERE c.connamespace = 'public'::regnamespace AND c.contype = 'f'
ORDER BY on_delete, c.confrelid::regclass::text, c.conrelid::regclass::text;
