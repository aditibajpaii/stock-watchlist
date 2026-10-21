SELECT conrelid::regclass AS table_name, conname, contype, pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE connamespace = 'public'::regnamespace AND contype IN ('p', 'f', 'u', 'c')
ORDER BY table_name, contype, conname;
