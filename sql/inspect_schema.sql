-- =====================================================================
-- inspect_schema.sql
-- Read-only metadata queries used for verification and report
-- screenshots. Changes nothing.
--
-- Run:  psql -d stock_watchlist -f sql/inspect_schema.sql
-- =====================================================================

\echo '===== Server version ====='
SELECT version();

\echo '===== Tables ====='
\dt

\echo '===== Columns (all 7 tables) ====='
SELECT c.table_name,
       c.ordinal_position AS pos,
       c.column_name,
       format_type(a.atttypid, a.atttypmod) AS data_type,
       CASE WHEN c.is_nullable = 'YES' THEN 'NULL' ELSE 'NOT NULL' END AS nullability,
       coalesce(c.column_default,
                CASE WHEN c.is_identity = 'YES'
                     THEN 'identity (' || c.identity_generation || ')' END,
                '') AS default_value
FROM information_schema.columns c
JOIN pg_attribute a
  ON a.attrelid = (quote_ident(c.table_schema) || '.' || quote_ident(c.table_name))::regclass
 AND a.attname = c.column_name
WHERE c.table_schema = 'public'
ORDER BY c.table_name, c.ordinal_position;

\echo '===== Constraints (PK / FK / UNIQUE / CHECK) ====='
SELECT conrelid::regclass AS table_name,
       conname            AS constraint_name,
       CASE contype WHEN 'p' THEN 'PRIMARY KEY'
                    WHEN 'f' THEN 'FOREIGN KEY'
                    WHEN 'u' THEN 'UNIQUE'
                    WHEN 'c' THEN 'CHECK' END AS type,
       pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE connamespace = 'public'::regnamespace
  AND contype IN ('p', 'f', 'u', 'c')
ORDER BY conrelid::regclass::text, contype, conname;

\echo '===== Foreign keys and ON DELETE actions ====='
SELECT conrelid::regclass  AS child_table,
       conname             AS constraint_name,
       confrelid::regclass AS parent_table,
       CASE confdeltype WHEN 'c' THEN 'CASCADE'
                        WHEN 'r' THEN 'RESTRICT'
                        WHEN 'a' THEN 'NO ACTION'
                        WHEN 'n' THEN 'SET NULL'
                        WHEN 'd' THEN 'SET DEFAULT' END AS on_delete
FROM pg_constraint
WHERE connamespace = 'public'::regnamespace AND contype = 'f'
ORDER BY child_table::text, conname;

\echo '===== Indexes (currently only those created by PK / UNIQUE) ====='
SELECT tablename, indexname, indexdef
FROM pg_indexes
WHERE schemaname = 'public'
ORDER BY tablename, indexname;

\echo '===== Row counts ====='
SELECT 'users' AS table_name, count(*) AS row_count FROM users
UNION ALL SELECT 'instruments',     count(*) FROM instruments
UNION ALL SELECT 'watchlists',      count(*) FROM watchlists
UNION ALL SELECT 'watchlist_items', count(*) FROM watchlist_items
UNION ALL SELECT 'price_ticks',     count(*) FROM price_ticks
UNION ALL SELECT 'alert_rules',     count(*) FROM alert_rules
UNION ALL SELECT 'alert_events',    count(*) FROM alert_events;
