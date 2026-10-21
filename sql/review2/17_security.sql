-- =====================================================================
-- 17_security.sql  -  Template "SQL Security Implementation"
--
-- PostgreSQL roles are CLUSTER-WIDE (shared by every database on this
-- server). Isolation here therefore means: every demo role is named r2_*,
-- is created NOLOGIN, receives privileges ONLY inside this sandbox
-- database, and is dropped by  bash scripts/review2_sandbox.sh --cleanup.
-- No passwords are used or stored. 18_login_probe.sql is a real,
-- separate login as r2_analyst (the runner enables LOGIN only for that
-- step; this local server authenticates local connections with "trust").
-- The classroom database stock_watchlist is not touched.
--
--   r2_owner    NOLOGIN, not superuser: owns the review2 objects the
--               restricted roles use, with only the base-table rights
--               those objects need
--   r2_analyst  market analyst: instruments, price_ticks and the
--               aggregated view V2; no user data, no rules, no writes
--   r2_support  support desk: active rules ONLY through view V3 (and may
--               change only cooldown_seconds), switches rules on/off ONLY
--               through procedure sp_set_rule_active; no base-table access
--   r2_feed     price-feed service: may ONLY call review2.fn_feed_ingest
--               (SECURITY DEFINER wrapper around ingest_tick)
-- Data changes made while demonstrating are rolled back.
-- =====================================================================
\ir _guard.sql

\echo '===== 0. Start clean: remove r2_* roles left by an earlier run ====='
DO $$
DECLARE
    r TEXT;
BEGIN
    FOREACH r IN ARRAY ARRAY['r2_analyst', 'r2_support', 'r2_feed', 'r2_owner'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('REASSIGN OWNED BY %I TO CURRENT_USER', r);
            EXECUTE format('DROP OWNED BY %I', r);
            EXECUTE format('DROP ROLE %I', r);
        END IF;
    END LOOP;
END $$;

\echo '===== 1. CREATE ROLE (no LOGIN, no password, no superuser) ====='
CREATE ROLE r2_owner   NOLOGIN;
CREATE ROLE r2_analyst NOLOGIN;
CREATE ROLE r2_support NOLOGIN;
CREATE ROLE r2_feed    NOLOGIN;
SELECT rolname, rolcanlogin, rolsuper, rolcreaterole, rolcreatedb
FROM pg_roles WHERE rolname LIKE 'r2\_%' ORDER BY rolname;

\echo '===== 2. Database and schema access: only the demo roles may connect to the sandbox ====='
REVOKE CONNECT ON DATABASE stock_watchlist_review2_sandbox FROM PUBLIC;
GRANT  CONNECT ON DATABASE stock_watchlist_review2_sandbox TO r2_analyst, r2_support, r2_feed;
GRANT  USAGE ON SCHEMA review2 TO r2_owner, r2_analyst, r2_support, r2_feed;

\echo 'Functions and procedures are executable by PUBLIC by default. BEFORE the REVOKE:'
SELECT has_function_privilege('r2_analyst',
       'review2.sp_set_rule_active(bigint, boolean, boolean)', 'EXECUTE') AS analyst_can_execute;
REVOKE ALL ON ALL ROUTINES IN SCHEMA review2 FROM PUBLIC;
\echo 'AFTER REVOKE ALL ON ALL ROUTINES IN SCHEMA review2 FROM PUBLIC:'
SELECT has_function_privilege('r2_analyst',
       'review2.sp_set_rule_active(bigint, boolean, boolean)', 'EXECUTE') AS analyst_can_execute;

\echo '===== 3. The owner gets only what its objects need ====='
GRANT SELECT ON instruments, price_ticks, alert_rules, alert_events TO r2_owner;
GRANT UPDATE (cooldown_seconds, is_active) ON alert_rules TO r2_owner;  -- view V3, procedure
GRANT INSERT ON price_ticks, alert_events TO r2_owner;                  -- ingest_tick + its trigger
GRANT UPDATE (is_active) ON instruments TO r2_owner;  -- PostgreSQL requires an UPDATE right for the
                                                      -- SELECT ... FOR NO KEY UPDATE lock in ingest_tick
ALTER VIEW review2.v_instrument_activity OWNER TO r2_owner;
ALTER VIEW review2.v_active_alert_rules  OWNER TO r2_owner;

\echo '===== 4. Procedure as the only write path for support: SECURITY DEFINER, fixed search_path ====='
ALTER PROCEDURE review2.sp_set_rule_active(BIGINT, BOOLEAN, BOOLEAN) SECURITY DEFINER;
ALTER PROCEDURE review2.sp_set_rule_active(BIGINT, BOOLEAN, BOOLEAN) SET search_path = public, pg_temp;
ALTER PROCEDURE review2.sp_set_rule_active(BIGINT, BOOLEAN, BOOLEAN) OWNER TO r2_owner;
GRANT EXECUTE ON PROCEDURE review2.sp_set_rule_active(BIGINT, BOOLEAN, BOOLEAN) TO r2_support;

\echo '===== 5. Function as the only write path for the feed ====='
CREATE OR REPLACE FUNCTION review2.fn_feed_ingest(
    p_exchange TEXT, p_symbol TEXT, p_observed_at TIMESTAMPTZ,
    p_price NUMERIC, p_volume NUMERIC, p_source_event_id TEXT)
RETURNS TABLE (status TEXT, tick_id BIGINT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT * FROM public.ingest_tick(p_exchange, p_symbol, p_observed_at,
                                     p_price, p_volume, 'BINANCE', p_source_event_id);
$$;
ALTER FUNCTION review2.fn_feed_ingest(TEXT, TEXT, TIMESTAMPTZ, NUMERIC, NUMERIC, TEXT) OWNER TO r2_owner;
REVOKE ALL ON FUNCTION review2.fn_feed_ingest(TEXT, TEXT, TIMESTAMPTZ, NUMERIC, NUMERIC, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION review2.fn_feed_ingest(TEXT, TEXT, TIMESTAMPTZ, NUMERIC, NUMERIC, TEXT) TO r2_feed;

\echo '===== 6. GRANT per role ====='
GRANT SELECT ON instruments, price_ticks TO r2_analyst;
GRANT SELECT ON review2.v_instrument_activity TO r2_analyst;
GRANT SELECT ON review2.v_active_alert_rules TO r2_support;
GRANT UPDATE (cooldown_seconds) ON review2.v_active_alert_rules TO r2_support;

\echo '===== 7. Privilege matrix (computed by PostgreSQL with has_*_privilege) ====='
SELECT r.rolname AS role,
       has_table_privilege(r.rolname, 'public.users', 'SELECT')        AS users_select,
       has_table_privilege(r.rolname, 'public.instruments', 'SELECT')  AS instruments_select,
       has_table_privilege(r.rolname, 'public.price_ticks', 'SELECT')  AS ticks_select,
       has_table_privilege(r.rolname, 'public.price_ticks', 'INSERT')  AS ticks_insert,
       has_table_privilege(r.rolname, 'public.alert_rules', 'SELECT')  AS rules_select,
       has_table_privilege(r.rolname, 'public.alert_rules', 'UPDATE')  AS rules_update,
       has_table_privilege(r.rolname, 'review2.v_instrument_activity', 'SELECT') AS v2_select,
       has_table_privilege(r.rolname, 'review2.v_active_alert_rules', 'SELECT')  AS v3_select,
       has_column_privilege(r.rolname, 'review2.v_active_alert_rules', 'cooldown_seconds', 'UPDATE') AS v3_upd_cooldown,
       has_column_privilege(r.rolname, 'review2.v_active_alert_rules', 'is_active', 'UPDATE')        AS v3_upd_is_active,
       has_function_privilege(r.rolname, 'review2.sp_set_rule_active(bigint, boolean, boolean)', 'EXECUTE') AS exec_sp_set_rule,
       has_function_privilege(r.rolname,
           'review2.fn_feed_ingest(text, text, timestamptz, numeric, numeric, text)', 'EXECUTE')   AS exec_feed_ingest
FROM pg_roles r
WHERE r.rolname IN ('r2_analyst', 'r2_support', 'r2_feed')
ORDER BY r.rolname;

\echo '===== 8. Access privileges as stored in the catalog (psql \\dp) ====='
\dp public.price_ticks
\dp public.alert_rules
\dp review2.*

\echo '===== 9. Least privilege, tested by switching identity with SET ROLE ====='
SELECT max(observed_at) + interval '1 minute' AS t_feed
FROM price_ticks WHERE instrument_id = 6 \gset
BEGIN;
\set ON_ERROR_STOP off

\echo '--- r2_analyst ---'
SET ROLE r2_analyst;
SELECT current_user;
\echo 'allowed: aggregated view and market data'
SELECT symbol, ticks, alerts, active_rules FROM review2.v_instrument_activity ORDER BY symbol;
SELECT count(*) AS price_ticks_visible FROM price_ticks;
SAVEPOINT a;
\echo '>>> EXPECTED ERROR [42501] analyst may not read users (emails)'
SELECT username, email FROM users;
\echo '<<< actual SQLSTATE:' :SQLSTATE
ROLLBACK TO SAVEPOINT a;
\echo '>>> EXPECTED ERROR [42501] analyst may not read alert rules'
SELECT * FROM alert_rules;
\echo '<<< actual SQLSTATE:' :SQLSTATE
ROLLBACK TO SAVEPOINT a;
\echo '>>> EXPECTED ERROR [42501] analyst may not insert ticks'
INSERT INTO price_ticks (instrument_id, observed_at, price, source, source_event_id)
VALUES (1, now(), 1, 'MANUAL', 'r2-analyst-1');
\echo '<<< actual SQLSTATE:' :SQLSTATE
ROLLBACK TO SAVEPOINT a;
\echo '>>> EXPECTED ERROR [42501] analyst may not call the support procedure'
CALL review2.sp_set_rule_active(4, false);
\echo '<<< actual SQLSTATE:' :SQLSTATE
ROLLBACK TO SAVEPOINT a;
RESET ROLE;

\echo '--- r2_support ---'
SET ROLE r2_support;
SELECT current_user;
\echo 'allowed: read active rules through view V3 (rule 5 is inactive, so it is not visible)'
SELECT rule_id, direction, threshold, cooldown_seconds FROM review2.v_active_alert_rules ORDER BY rule_id;
\echo 'allowed: change a cooldown through V3'
UPDATE review2.v_active_alert_rules SET cooldown_seconds = 45 WHERE rule_id = 4
RETURNING rule_id, cooldown_seconds;
\echo 'allowed: switch a rule off through the SECURITY DEFINER procedure (INOUT returns the previous state)'
CALL review2.sp_set_rule_active(3, false);
SAVEPOINT s;
\echo '>>> EXPECTED ERROR [42501] support may not bypass the view and read alert_rules directly'
SELECT * FROM alert_rules;
\echo '<<< actual SQLSTATE:' :SQLSTATE
ROLLBACK TO SAVEPOINT s;
\echo '>>> EXPECTED ERROR [42501] support may not update alert_rules directly'
UPDATE alert_rules SET cooldown_seconds = 1 WHERE rule_id = 4;
\echo '<<< actual SQLSTATE:' :SQLSTATE
ROLLBACK TO SAVEPOINT s;
\echo '>>> EXPECTED ERROR [42501] through V3 support may change only cooldown_seconds, not is_active'
UPDATE review2.v_active_alert_rules SET is_active = false WHERE rule_id = 4;
\echo '<<< actual SQLSTATE:' :SQLSTATE
ROLLBACK TO SAVEPOINT s;
\echo '>>> EXPECTED ERROR [42501] support may not read users'
SELECT email FROM users;
\echo '<<< actual SQLSTATE:' :SQLSTATE
ROLLBACK TO SAVEPOINT s;
RESET ROLE;

\echo '--- r2_feed ---'
SET ROLE r2_feed;
SELECT current_user;
\echo 'allowed: ingest a BTCUSDT tick through the definer function'
SELECT * FROM review2.fn_feed_ingest('BINANCE', 'BTCUSDT', :'t_feed'::timestamptz, 100500, 0.10, 'r2-feed-1');
SAVEPOINT f;
\echo '>>> EXPECTED ERROR [42501] the feed may not insert into price_ticks directly'
INSERT INTO price_ticks (instrument_id, observed_at, price, source, source_event_id)
VALUES (6, now(), 100500, 'BINANCE', 'r2-feed-2');
\echo '<<< actual SQLSTATE:' :SQLSTATE
ROLLBACK TO SAVEPOINT f;
\echo '>>> EXPECTED ERROR [42501] the feed may not call ingest_tick by name (it needs table rights it does not have)'
SELECT * FROM ingest_tick('BINANCE', 'BTCUSDT', :'t_feed'::timestamptz + interval '1 second', 100510, 0.10, 'BINANCE', 'r2-feed-3');
\echo '<<< actual SQLSTATE:' :SQLSTATE
ROLLBACK TO SAVEPOINT f;
RESET ROLE;

\set ON_ERROR_STOP on
\echo 'what the allowed actions changed inside the transaction:'
SELECT rule_id, cooldown_seconds, is_active FROM alert_rules WHERE rule_id IN (3, 4) ORDER BY rule_id;
SELECT source, source_event_id, price FROM price_ticks WHERE source_event_id = 'r2-feed-1';
ROLLBACK;
\echo 'after ROLLBACK the demo changes are gone:'
SELECT rule_id, cooldown_seconds, is_active FROM alert_rules WHERE rule_id IN (3, 4) ORDER BY rule_id;

\echo '===== 10. REVOKE with before / after evidence ====='
\echo 'before REVOKE:'
\dp public.price_ticks
BEGIN;
SET ROLE r2_analyst;
SELECT count(*) AS ticks_visible_to_analyst FROM price_ticks;
ROLLBACK;
REVOKE SELECT ON price_ticks FROM r2_analyst;
\echo 'after REVOKE SELECT ON price_ticks FROM r2_analyst:'
\dp public.price_ticks
BEGIN;
SET ROLE r2_analyst;
\set ON_ERROR_STOP off
\echo '>>> EXPECTED ERROR [42501] the same query now fails'
SELECT count(*) AS ticks_visible_to_analyst FROM price_ticks;
\echo '<<< actual SQLSTATE:' :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK;
\echo 'the aggregated view still works, because it reads price_ticks with its OWNER rights:'
BEGIN;
SET ROLE r2_analyst;
SELECT symbol, ticks FROM review2.v_instrument_activity WHERE ticks > 0 ORDER BY symbol;
ROLLBACK;
GRANT SELECT ON price_ticks TO r2_analyst;
\echo 'restored: GRANT SELECT ON price_ticks TO r2_analyst'

\echo '===== 11. Definer routines and their pinned search_path ====='
SELECT p.oid::regprocedure AS routine, p.prosecdef AS security_definer,
       pg_get_userbyid(p.proowner) AS owner, p.proconfig AS settings
FROM pg_proc p
WHERE p.pronamespace = 'review2'::regnamespace AND p.prosecdef
ORDER BY 1;
