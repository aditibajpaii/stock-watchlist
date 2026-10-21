SELECT conrelid::regclass AS table_name, conname, contype, pg_get_constraintdef(oid) AS key_columns
FROM pg_constraint
WHERE connamespace = 'public'::regnamespace AND contype IN ('p', 'u')
ORDER BY table_name, contype;
