\echo '========================================================================'
\echo ' N02 | Normalization: primary key and candidate keys of every table'
\echo '       (every determinant is a key -> each table is in BCNF)'
\echo '========================================================================'
SELECT c.conrelid::regclass AS table_name,
       CASE c.contype WHEN 'p' THEN 'PRIMARY KEY' ELSE 'CANDIDATE KEY (UNIQUE)' END AS key_type,
       c.conname AS constraint_name,
       (SELECT string_agg(a.attname, ', ' ORDER BY k.ord)
          FROM unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
          JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum) AS key_columns
FROM pg_constraint c
WHERE c.connamespace = 'public'::regnamespace AND c.contype IN ('p', 'u')
ORDER BY c.conrelid::regclass::text, c.contype, c.conname;
