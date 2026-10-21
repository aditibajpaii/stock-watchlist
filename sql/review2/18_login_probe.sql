-- =====================================================================
-- 18_login_probe.sql  -  "Login as restricted user -> attempt forbidden
-- operation -> show error" (template, SQL Security, least privilege).
--
-- Run as a REAL separate login of r2_analyst, not by SET ROLE. The runner
-- (scripts/review2_sandbox.sh) does:
--     ALTER ROLE r2_analyst LOGIN
--     psql -U r2_analyst -d stock_watchlist_review2_sandbox -f sql/review2/18_login_probe.sql
--     ALTER ROLE r2_analyst NOLOGIN
-- Prerequisite: 17_security.sql.
-- Two ways this file is run:
--   * by scripts/review2_sandbox.sh on the classroom server, whose
--     pg_hba.conf says "trust": a real, separate, non-superuser session,
--     but NO credential is checked (system_user below is NULL);
--   * by scripts/review2_auth_demo.sh on a throwaway server that demands
--     a SCRAM password (system_user = 'scram-sha-256:r2_analyst').
-- =====================================================================
\ir _guard.sql

\echo '===== Who is connected, and how was the connection authenticated? ====='
-- system_user (PostgreSQL 16+) = '<auth method>:<identity>', or NULL when
-- the server did not authenticate the user (pg_hba method "trust").
SELECT session_user, current_user, system_user AS authenticated_as,
       (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) AS is_superuser;

\echo '===== Allowed: the aggregated view (no user data in it) ====='
SELECT symbol, ticks, alerts FROM review2.v_instrument_activity ORDER BY symbol;

\set ON_ERROR_STOP off
\echo '>>> EXPECTED ERROR [42501] the users table (emails) is not readable'
SELECT username, email FROM users;
\echo '<<< actual SQLSTATE:' :SQLSTATE

\echo '>>> EXPECTED ERROR [42501] price ticks cannot be written directly'
INSERT INTO price_ticks (instrument_id, observed_at, price, source, source_event_id)
VALUES (1, now(), 1, 'MANUAL', 'r2-probe-1');
\echo '<<< actual SQLSTATE:' :SQLSTATE

\echo '>>> EXPECTED ERROR [42501] the support procedure cannot be called'
CALL review2.sp_set_rule_active(4, false);
\echo '<<< actual SQLSTATE:' :SQLSTATE

\echo '>>> EXPECTED ERROR [42501] no privilege escalation: SET ROLE to a role it is not a member of'
SET ROLE r2_support;
\echo '<<< actual SQLSTATE:' :SQLSTATE

\echo '>>> EXPECTED ERROR [42501] no new tables in schema public (PostgreSQL 15+ default)'
CREATE TABLE public.r2_probe (x INT);
\echo '<<< actual SQLSTATE:' :SQLSTATE
\set ON_ERROR_STOP on
