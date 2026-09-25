-- =====================================================================
-- verify_spec.sql
-- Compares the LIVE PostgreSQL catalog against docs/PHASE1_SPEC.md.
-- Read-only. Every expected fact is written below as data, then diffed
-- against pg_catalog. Any mismatch is printed; psql exits non-zero if
-- anything differs.
--
-- Run:  psql -d stock_watchlist -v ON_ERROR_STOP=1 -f sql/verify_spec.sql
-- =====================================================================

\pset footer off

-- ---------------------------------------------------------------------
-- 1. Columns: table, column, type, nullability, default
-- ---------------------------------------------------------------------
CREATE TEMP TABLE expected_columns (tbl TEXT, col TEXT, typ TEXT, nullable BOOLEAN, dflt TEXT);
INSERT INTO expected_columns VALUES
 ('users','user_id','bigint',false,'identity'),
 ('users','username','text',false,NULL),
 ('users','email','text',false,NULL),
 ('users','created_at','timestamp with time zone',false,'now()'),
 ('instruments','instrument_id','bigint',false,'identity'),
 ('instruments','exchange','text',false,NULL),
 ('instruments','symbol','text',false,NULL),
 ('instruments','name','text',false,NULL),
 ('instruments','quote_currency','text',false,NULL),
 ('instruments','is_active','boolean',false,'true'),
 ('watchlists','watchlist_id','bigint',false,'identity'),
 ('watchlists','user_id','bigint',false,NULL),
 ('watchlists','name','text',false,NULL),
 ('watchlists','created_at','timestamp with time zone',false,'now()'),
 ('watchlist_items','watchlist_id','bigint',false,NULL),
 ('watchlist_items','instrument_id','bigint',false,NULL),
 ('watchlist_items','added_at','timestamp with time zone',false,'now()'),
 ('price_ticks','tick_id','bigint',false,'identity'),
 ('price_ticks','instrument_id','bigint',false,NULL),
 ('price_ticks','observed_at','timestamp with time zone',false,NULL),
 ('price_ticks','price','numeric(18,8)',false,NULL),
 ('price_ticks','volume','numeric(24,8)',true,NULL),
 ('price_ticks','source','text',false,NULL),
 ('price_ticks','source_event_id','text',false,NULL),
 ('price_ticks','ingested_at','timestamp with time zone',false,'now()'),
 ('alert_rules','rule_id','bigint',false,'identity'),
 ('alert_rules','user_id','bigint',false,NULL),
 ('alert_rules','instrument_id','bigint',false,NULL),
 ('alert_rules','direction','text',false,NULL),
 ('alert_rules','threshold','numeric(18,8)',false,NULL),
 ('alert_rules','cooldown_seconds','integer',false,'300'),
 ('alert_rules','is_active','boolean',false,'true'),
 ('alert_rules','created_at','timestamp with time zone',false,'now()'),
 ('alert_events','event_id','bigint',false,'identity'),
 ('alert_events','rule_id','bigint',false,NULL),
 ('alert_events','tick_id','bigint',false,NULL),
 ('alert_events','fired_at','timestamp with time zone',false,'now()');

CREATE TEMP VIEW live_columns AS
SELECT c.relname::TEXT AS tbl,
       a.attname::TEXT AS col,
       format_type(a.atttypid, a.atttypmod) AS typ,
       NOT a.attnotnull AS nullable,
       CASE WHEN a.attidentity = 'a' THEN 'identity'
            ELSE pg_get_expr(d.adbin, d.adrelid) END AS dflt
FROM pg_class c
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r';

\echo '===== 1. Column mismatches (expect 0 rows) ====='
SELECT coalesce(e.tbl, l.tbl) AS tbl, coalesce(e.col, l.col) AS col,
       CASE WHEN l.col IS NULL THEN 'MISSING in live DB'
            WHEN e.col IS NULL THEN 'EXTRA in live DB'
            ELSE 'DIFFERENT' END AS problem,
       e.typ AS expected_type, l.typ AS live_type,
       e.nullable AS expected_null, l.nullable AS live_null,
       e.dflt AS expected_default, l.dflt AS live_default
FROM expected_columns e
FULL JOIN live_columns l ON l.tbl = e.tbl AND l.col = e.col
WHERE l.col IS NULL OR e.col IS NULL
   OR e.typ <> l.typ OR e.nullable <> l.nullable
   OR e.dflt IS DISTINCT FROM l.dflt;

-- ---------------------------------------------------------------------
-- 2. Constraints: name, table, type, exact definition
-- ---------------------------------------------------------------------
CREATE TEMP TABLE expected_constraints (tbl TEXT, conname TEXT, def TEXT);
INSERT INTO expected_constraints VALUES
 ('users','pk_users','PRIMARY KEY (user_id)'),
 ('users','uq_users_username','UNIQUE (username)'),
 ('users','uq_users_email','UNIQUE (email)'),
 ('users','ck_users_username_format','CHECK ((username ~ ''^[a-z0-9_]{3,30}$''::text))'),
 ('users','ck_users_email_format','CHECK (((email = lower(email)) AND (email ~~ ''%_@_%''::text)))'),
 ('instruments','pk_instruments','PRIMARY KEY (instrument_id)'),
 ('instruments','uq_instruments_exchange_symbol','UNIQUE (exchange, symbol)'),
 ('instruments','ck_instruments_exchange','CHECK ((exchange = ANY (ARRAY[''NSE''::text, ''BSE''::text, ''BINANCE''::text])))'),
 ('instruments','ck_instruments_symbol_format','CHECK ((symbol ~ ''^[A-Z0-9&._-]{1,20}$''::text))'),
 ('instruments','ck_instruments_name_not_blank','CHECK ((btrim(name) <> ''''::text))'),
 ('instruments','ck_instruments_quote_currency','CHECK ((quote_currency ~ ''^[A-Z]{3,5}$''::text))'),
 ('watchlists','pk_watchlists','PRIMARY KEY (watchlist_id)'),
 ('watchlists','fk_watchlists_user','FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE'),
 ('watchlists','uq_watchlists_user_name','UNIQUE (user_id, name)'),
 ('watchlists','ck_watchlists_name','CHECK (((btrim(name) <> ''''::text) AND (char_length(name) <= 50)))'),
 ('watchlist_items','pk_watchlist_items','PRIMARY KEY (watchlist_id, instrument_id)'),
 ('watchlist_items','fk_watchlist_items_watchlist','FOREIGN KEY (watchlist_id) REFERENCES watchlists(watchlist_id) ON DELETE CASCADE'),
 ('watchlist_items','fk_watchlist_items_instrument','FOREIGN KEY (instrument_id) REFERENCES instruments(instrument_id) ON DELETE RESTRICT'),
 ('price_ticks','pk_price_ticks','PRIMARY KEY (tick_id)'),
 ('price_ticks','fk_price_ticks_instrument','FOREIGN KEY (instrument_id) REFERENCES instruments(instrument_id) ON DELETE RESTRICT'),
 ('price_ticks','uq_price_ticks_source_event','UNIQUE (source, instrument_id, source_event_id)'),
 ('price_ticks','ck_price_ticks_price_pos','CHECK ((price > (0)::numeric))'),
 ('price_ticks','ck_price_ticks_volume_nonneg','CHECK (((volume IS NULL) OR (volume >= (0)::numeric)))'),
 ('price_ticks','ck_price_ticks_source','CHECK ((source = ANY (ARRAY[''REPLAY''::text, ''BINANCE''::text, ''MANUAL''::text])))'),
 ('price_ticks','ck_price_ticks_source_event_not_blank','CHECK ((btrim(source_event_id) <> ''''::text))'),
 ('alert_rules','pk_alert_rules','PRIMARY KEY (rule_id)'),
 ('alert_rules','fk_alert_rules_user','FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE'),
 ('alert_rules','fk_alert_rules_instrument','FOREIGN KEY (instrument_id) REFERENCES instruments(instrument_id) ON DELETE RESTRICT'),
 ('alert_rules','uq_alert_rules_definition','UNIQUE (user_id, instrument_id, direction, threshold)'),
 ('alert_rules','ck_alert_rules_direction','CHECK ((direction = ANY (ARRAY[''ABOVE''::text, ''BELOW''::text])))'),
 ('alert_rules','ck_alert_rules_threshold_pos','CHECK ((threshold > (0)::numeric))'),
 ('alert_rules','ck_alert_rules_cooldown_nonneg','CHECK ((cooldown_seconds >= 0))'),
 ('alert_events','pk_alert_events','PRIMARY KEY (event_id)'),
 ('alert_events','fk_alert_events_rule','FOREIGN KEY (rule_id) REFERENCES alert_rules(rule_id) ON DELETE CASCADE'),
 ('alert_events','fk_alert_events_tick','FOREIGN KEY (tick_id) REFERENCES price_ticks(tick_id) ON DELETE RESTRICT'),
 ('alert_events','uq_alert_events_rule_tick','UNIQUE (rule_id, tick_id)');

CREATE TEMP VIEW live_constraints AS
SELECT conrelid::regclass::TEXT AS tbl, conname::TEXT AS conname,
       pg_get_constraintdef(oid) AS def
FROM pg_constraint
WHERE connamespace = 'public'::regnamespace AND contype IN ('p','f','u','c');

\echo '===== 2. Constraint mismatches (expect 0 rows) ====='
SELECT coalesce(e.conname, l.conname) AS constraint_name,
       CASE WHEN l.conname IS NULL THEN 'MISSING in live DB'
            WHEN e.conname IS NULL THEN 'EXTRA in live DB'
            ELSE 'DIFFERENT' END AS problem,
       e.tbl AS expected_table, l.tbl AS live_table,
       e.def AS expected_def, l.def AS live_def
FROM expected_constraints e
FULL JOIN live_constraints l ON l.conname = e.conname
WHERE l.conname IS NULL OR e.conname IS NULL
   OR e.tbl <> l.tbl OR e.def <> l.def;

-- ---------------------------------------------------------------------
-- 3. Objects that must NOT exist yet (Phase 2/3 scope)
-- ---------------------------------------------------------------------
\echo '===== 3. Unexpected objects: triggers, functions, non-constraint indexes (expect 0 rows) ====='
SELECT 'trigger' AS kind, tgname::TEXT AS name FROM pg_trigger
 WHERE NOT tgisinternal AND tgrelid::regclass::TEXT IN
   ('users','instruments','watchlists','watchlist_items','price_ticks','alert_rules','alert_events')
UNION ALL
SELECT 'function', proname::TEXT FROM pg_proc WHERE pronamespace = 'public'::regnamespace
UNION ALL
SELECT 'index', indexrelid::regclass::TEXT FROM pg_index i
 WHERE indrelid::regclass::TEXT IN
   ('users','instruments','watchlists','watchlist_items','price_ticks','alert_rules','alert_events')
   AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = i.indexrelid);

-- ---------------------------------------------------------------------
-- 4. Relationship cardinalities derived from the catalog (for the ER)
--    child side "many" unless the FK columns are themselves unique;
--    child participation mandatory if all FK columns are NOT NULL.
-- ---------------------------------------------------------------------
\echo '===== 4. Relationships derived from foreign keys ====='
SELECT c.confrelid::regclass AS parent,
       c.conrelid::regclass  AS child,
       c.conname             AS fk,
       (SELECT string_agg(a.attname, ', ' ORDER BY a.attnum)
          FROM pg_attribute a WHERE a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)) AS fk_columns,
       CASE WHEN EXISTS (SELECT 1 FROM pg_index i
                         WHERE i.indrelid = c.conrelid AND i.indisunique
                           AND i.indkey::int2[] @> c.conkey AND c.conkey @> i.indkey::int2[])
            THEN '1 : 0..1' ELSE '1 : 0..N' END AS cardinality,
       CASE WHEN (SELECT bool_and(a.attnotnull) FROM pg_attribute a
                  WHERE a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey))
            THEN 'child must have exactly 1 parent' ELSE 'child parent optional' END AS child_participation,
       CASE c.confdeltype WHEN 'c' THEN 'CASCADE' WHEN 'r' THEN 'RESTRICT' ELSE c.confdeltype::TEXT END AS on_delete
FROM pg_constraint c
WHERE c.connamespace = 'public'::regnamespace AND c.contype = 'f'
ORDER BY c.confrelid::regclass::TEXT, c.conrelid::regclass::TEXT;

-- ---------------------------------------------------------------------
-- Verdict
-- ---------------------------------------------------------------------
DO $$
DECLARE
    n_col INT; n_con INT; n_obj INT;
BEGIN
    SELECT count(*) INTO n_col
    FROM expected_columns e FULL JOIN live_columns l ON l.tbl = e.tbl AND l.col = e.col
    WHERE l.col IS NULL OR e.col IS NULL OR e.typ <> l.typ
       OR e.nullable <> l.nullable OR e.dflt IS DISTINCT FROM l.dflt;

    SELECT count(*) INTO n_con
    FROM expected_constraints e FULL JOIN live_constraints l ON l.conname = e.conname
    WHERE l.conname IS NULL OR e.conname IS NULL OR e.tbl <> l.tbl OR e.def <> l.def;

    SELECT count(*) INTO n_obj FROM (
        SELECT 1 FROM pg_trigger WHERE NOT tgisinternal AND tgrelid::regclass::TEXT IN
          ('users','instruments','watchlists','watchlist_items','price_ticks','alert_rules','alert_events')
        UNION ALL SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace
        UNION ALL SELECT 1 FROM pg_index i WHERE indrelid::regclass::TEXT IN
          ('users','instruments','watchlists','watchlist_items','price_ticks','alert_rules','alert_events')
          AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = i.indexrelid)) x;

    RAISE NOTICE 'columns checked: %, constraints checked: %',
        (SELECT count(*) FROM expected_columns), (SELECT count(*) FROM expected_constraints);
    IF n_col + n_con + n_obj > 0 THEN
        RAISE EXCEPTION 'SPEC MISMATCH: % column, % constraint, % unexpected object differences',
            n_col, n_con, n_obj;
    END IF;
    RAISE NOTICE 'LIVE SCHEMA MATCHES docs/PHASE1_SPEC.md';
END $$;
