\echo '========================================================================'
\echo ' S21 | All 36 named constraints (7 PK, 8 FK, 7 UNIQUE, 14 CHECK)'
\echo '========================================================================'
SELECT conrelid::regclass AS table_name,
       conname            AS constraint_name,
       CASE contype WHEN 'p' THEN 'PRIMARY KEY' WHEN 'f' THEN 'FOREIGN KEY'
                    WHEN 'u' THEN 'UNIQUE'      WHEN 'c' THEN 'CHECK' END AS type,
       left(pg_get_constraintdef(oid), 100) AS definition
FROM pg_constraint
WHERE connamespace = 'public'::regnamespace AND contype IN ('p','f','u','c')
ORDER BY conrelid::regclass::text, contype, conname;
