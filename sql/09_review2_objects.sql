-- =====================================================================
-- 09_review2_objects.sql
-- Review 2 add-on objects: views, stored procedures, user-defined
-- functions, cursors, and database roles with GRANTs.
--
-- Everything lives in a SEPARATE schema `reporting`. The 7 core tables,
-- their 36 constraints, ingest_tick() and the 2 triggers in `public` are
-- NOT changed, so sql/verify_spec.sql still matches the Phase 1 spec.
-- These objects only READ the core tables, except the 2 procedures,
-- which write user-owned data (watchlists, alert rule on/off).
--
-- Prerequisite: 00_schema.sql, 01_seed.sql, 03_functions_triggers.sql
-- Run:  psql -d stock_watchlist -v ON_ERROR_STOP=1 -f sql/09_review2_objects.sql
-- Re-runnable: drops and recreates schema `reporting`; roles are created
-- only if missing (roles belong to the whole server, not one database).
--
-- Roles (NOLOGIN groups + 2 end users; no passwords in this file):
--   sw_admin    full read/write on all tables         (administrator)
--   sw_analyst  read-only market data + summary view  (analyst)
--   sw_enduser  only reporting.v_my_alerts            (end-user group)
--   arjun, priya  members of sw_enduser; names match users.username, so
--                 v_my_alerts shows each one only their own alerts.
-- Demonstrate with SET ROLE <role> (as postgres), then RESET ROLE.
-- =====================================================================

BEGIN;

DROP SCHEMA IF EXISTS reporting CASCADE;
CREATE SCHEMA reporting;

-- ---------------------------------------------------------------------
-- 1. VIEWS
-- ---------------------------------------------------------------------

-- V1: joins 4 tables. Who watches what.
CREATE VIEW reporting.v_watchlist_contents AS
SELECT u.user_id, u.username,
       w.watchlist_id, w.name AS watchlist_name,
       i.instrument_id, i.exchange, i.symbol, i.quote_currency,
       wi.added_at
FROM users u
JOIN watchlists w       ON w.user_id = u.user_id
JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
JOIN instruments i      ON i.instrument_id = wi.instrument_id;

-- V2: aggregated. One row per instrument (LEFT JOIN keeps instruments
-- that have no ticks yet).
CREATE VIEW reporting.v_instrument_price_summary AS
SELECT i.instrument_id, i.exchange, i.symbol, i.quote_currency,
       count(t.tick_id)       AS tick_count,
       min(t.price)           AS min_price,
       max(t.price)           AS max_price,
       round(avg(t.price), 2) AS avg_price,
       min(t.observed_at)     AS first_tick_at,
       max(t.observed_at)     AS last_tick_at
FROM instruments i
LEFT JOIN price_ticks t ON t.instrument_id = i.instrument_id
GROUP BY i.instrument_id, i.exchange, i.symbol, i.quote_currency;

-- V3: row-restricting (security). Shows only the alerts of the database
-- role that is running the query (current_user = users.username).
-- security_barrier stops a caller's WHERE functions from peeking at
-- other users' rows before the filter is applied.
CREATE VIEW reporting.v_my_alerts WITH (security_barrier) AS
SELECT e.event_id, i.exchange, i.symbol, r.direction, r.threshold,
       t.price, t.observed_at, e.fired_at
FROM alert_events e
JOIN alert_rules r ON r.rule_id = e.rule_id
JOIN users u       ON u.user_id = r.user_id
JOIN price_ticks t ON t.tick_id = e.tick_id
JOIN instruments i ON i.instrument_id = r.instrument_id
WHERE u.username = current_user;

-- ---------------------------------------------------------------------
-- 2. USER-DEFINED FUNCTIONS
-- ---------------------------------------------------------------------

-- U1: latest price of one instrument (NULL if it has no ticks).
-- Same ORDER BY as the API, so it uses ix_price_ticks_instrument_time.
CREATE FUNCTION reporting.fn_latest_price(p_instrument_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT t.price
    FROM price_ticks t
    WHERE t.instrument_id = p_instrument_id
    ORDER BY t.observed_at DESC, t.tick_id DESC
    LIMIT 1;
$$;

-- U2: % change from the first to the latest tick of one instrument.
CREATE FUNCTION reporting.fn_price_change_pct(p_instrument_id BIGINT)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_first NUMERIC;
    v_last  NUMERIC;
BEGIN
    SELECT t.price INTO v_first FROM price_ticks t
    WHERE t.instrument_id = p_instrument_id
    ORDER BY t.observed_at, t.tick_id LIMIT 1;

    IF v_first IS NULL THEN
        RETURN NULL;
    END IF;

    v_last := reporting.fn_latest_price(p_instrument_id);
    RETURN round((v_last - v_first) / v_first * 100, 2);
END;
$$;

-- ---------------------------------------------------------------------
-- 3. STORED PROCEDURES
-- ---------------------------------------------------------------------

-- P1: create a watchlist and fill it in ONE call. If any symbol is
-- unknown, RAISE EXCEPTION undoes the whole call (nothing half-created).
CREATE PROCEDURE reporting.sp_create_watchlist(
    p_username TEXT, p_name TEXT, p_exchange TEXT, p_symbols TEXT[])
LANGUAGE plpgsql
AS $$
DECLARE
    v_user_id      BIGINT;
    v_watchlist_id BIGINT;
    v_added        INT;
BEGIN
    SELECT u.user_id INTO v_user_id FROM users u WHERE u.username = p_username;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown user %', p_username;
    END IF;

    INSERT INTO watchlists (user_id, name) VALUES (v_user_id, p_name)
    RETURNING watchlist_id INTO v_watchlist_id;

    INSERT INTO watchlist_items (watchlist_id, instrument_id)
    SELECT v_watchlist_id, i.instrument_id
    FROM instruments i
    WHERE i.exchange = p_exchange AND i.symbol = ANY (p_symbols);
    GET DIAGNOSTICS v_added = ROW_COUNT;

    IF v_added <> cardinality(p_symbols) THEN
        RAISE EXCEPTION 'only % of % symbols exist on %; nothing was created',
            v_added, cardinality(p_symbols), p_exchange;
    END IF;

    RAISE NOTICE 'watchlist % "%" created for % with % instruments',
        v_watchlist_id, p_name, p_username, v_added;
END;
$$;

-- P2: enable or disable an alert rule (the approved way to "change" a
-- rule: rules are disabled, not edited or deleted).
CREATE PROCEDURE reporting.sp_set_rule_active(p_rule_id BIGINT, p_active BOOLEAN)
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE alert_rules SET is_active = p_active WHERE rule_id = p_rule_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'alert rule % does not exist', p_rule_id;
    END IF;
    RAISE NOTICE 'alert rule % is now %', p_rule_id,
        CASE WHEN p_active THEN 'ACTIVE' ELSE 'DISABLED' END;
END;
$$;

-- ---------------------------------------------------------------------
-- 4. CURSORS
-- ---------------------------------------------------------------------

-- CR1: explicit, parameterised cursor (OPEN / FETCH / CLOSE) that walks
-- one user's rules and compares each with the latest price.
CREATE FUNCTION reporting.fn_rule_status_report(p_username TEXT)
RETURNS TABLE (rule_id BIGINT, symbol TEXT, direction TEXT, threshold NUMERIC,
               latest_price NUMERIC, distance_pct NUMERIC, status TEXT)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    c_rules CURSOR (p_user TEXT) FOR
        SELECT r.rule_id AS rid, i.symbol AS sym, r.direction AS dir,
               r.threshold AS thr, r.is_active AS active, r.instrument_id AS iid
        FROM alert_rules r
        JOIN users u       ON u.user_id = r.user_id
        JOIN instruments i ON i.instrument_id = r.instrument_id
        WHERE u.username = p_user
        ORDER BY r.rule_id;
    rec RECORD;
BEGIN
    OPEN c_rules(p_username);
    LOOP
        FETCH c_rules INTO rec;
        EXIT WHEN NOT FOUND;

        rule_id      := rec.rid;
        symbol       := rec.sym;
        direction    := rec.dir;
        threshold    := rec.thr;
        latest_price := reporting.fn_latest_price(rec.iid);
        distance_pct := round((latest_price - rec.thr) / rec.thr * 100, 2);
        status := CASE
            WHEN NOT rec.active          THEN 'DISABLED'
            WHEN latest_price IS NULL    THEN 'NO PRICE DATA'
            WHEN (rec.dir = 'ABOVE' AND latest_price >= rec.thr)
              OR (rec.dir = 'BELOW' AND latest_price <= rec.thr)
                                         THEN 'CONDITION MET'
            ELSE 'WAITING'
        END;
        RETURN NEXT;
    END LOOP;
    CLOSE c_rules;
END;
$$;

-- CR2: unbound cursor variable (refcursor) inside a procedure; prints a
-- text report with RAISE NOTICE, one line per watchlist item.
CREATE PROCEDURE reporting.sp_print_watchlist_report(p_username TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    c_items REFCURSOR;
    rec     RECORD;
    v_rows  INT := 0;
BEGIN
    OPEN c_items FOR
        SELECT v.watchlist_name, v.exchange, v.symbol, v.quote_currency,
               reporting.fn_latest_price(v.instrument_id) AS latest
        FROM reporting.v_watchlist_contents v
        WHERE v.username = p_username
        ORDER BY v.watchlist_name, v.symbol;

    RAISE NOTICE 'Watchlist report for %', p_username;
    LOOP
        FETCH c_items INTO rec;
        EXIT WHEN NOT FOUND;
        v_rows := v_rows + 1;
        RAISE NOTICE '  % | % | %', rpad(rec.watchlist_name, 10),
            rpad(rec.exchange || ':' || rec.symbol, 16),
            coalesce(rec.latest::TEXT || ' ' || rec.quote_currency, 'no price data yet');
    END LOOP;
    CLOSE c_items;
    RAISE NOTICE '% item(s) listed', v_rows;
END;
$$;

-- ---------------------------------------------------------------------
-- 5. ROLES AND PRIVILEGES (least privilege)
-- ---------------------------------------------------------------------
DO $$
DECLARE
    r TEXT;
BEGIN
    FOREACH r IN ARRAY ARRAY['sw_admin', 'sw_analyst', 'sw_enduser'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', r);
        END IF;
    END LOOP;
    FOREACH r IN ARRAY ARRAY['arjun', 'priya'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('CREATE ROLE %I LOGIN IN ROLE sw_enduser', r);
        END IF;
    END LOOP;
END;
$$;

-- functions/procedures are executable by PUBLIC by default: close that
REVOKE EXECUTE ON ALL ROUTINES IN SCHEMA reporting FROM PUBLIC;

-- administrator: everything on the data
GRANT USAGE ON SCHEMA public, reporting TO sw_admin;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO sw_admin;
GRANT SELECT ON ALL TABLES IN SCHEMA reporting TO sw_admin;
GRANT EXECUTE ON ALL ROUTINES IN SCHEMA reporting TO sw_admin;

-- analyst: read market data only (no user data, no writes)
GRANT USAGE ON SCHEMA reporting TO sw_analyst;
GRANT SELECT ON instruments, price_ticks TO sw_analyst;
GRANT SELECT ON reporting.v_instrument_price_summary TO sw_analyst;
GRANT EXECUTE ON FUNCTION reporting.fn_latest_price(BIGINT),
                          reporting.fn_price_change_pct(BIGINT) TO sw_analyst;

-- end users: NO table privileges at all; the view is the only way in
GRANT USAGE ON SCHEMA reporting TO sw_enduser;
GRANT SELECT ON reporting.v_my_alerts TO sw_enduser;

COMMIT;
