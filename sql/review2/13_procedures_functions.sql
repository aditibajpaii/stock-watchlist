-- =====================================================================
-- 13_procedures_functions.sql  -  Template: stored procedures (>= 2) and
-- user-defined functions (>= 2); Review 2 checklist: >= 1 of each working.
--
-- 1. What already exists in the production schema (catalog): ingest_tick
--    is a callable FUNCTION; the other two are TRIGGER functions.
-- 2. Two new user-defined FUNCTIONS (CREATE FUNCTION, schema review2).
-- 3. Two new stored PROCEDURES (CREATE PROCEDURE, schema review2).
-- Procedure calls that change data run inside a transaction that is
-- ROLLED BACK. Production functions are not modified.
-- =====================================================================
\ir _guard.sql

\echo '===== 1. Existing routines in schema public (prokind f = function, p = procedure) ====='
SELECT p.proname AS routine,
       CASE p.prokind WHEN 'f' THEN 'FUNCTION' WHEN 'p' THEN 'PROCEDURE' END AS kind,
       pg_get_function_result(p.oid) AS returns,
       p.prorettype = 'trigger'::regtype AS is_trigger_function,
       CASE WHEN p.prorettype = 'trigger'::regtype
            THEN 'runs only when its trigger fires'
            ELSE 'callable: SELECT * FROM ' || p.proname || '(...)' END AS how_it_runs
FROM pg_proc p
WHERE p.pronamespace = 'public'::regnamespace
ORDER BY kind, routine;

\set ON_ERROR_STOP off
\echo '>>> EXPECTED ERROR [0A000] a trigger function cannot be called directly'
SELECT evaluate_price_alerts();
\echo '<<< actual SQLSTATE:' :SQLSTATE
\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------
\echo '===== 2a. FUNCTION review2.fn_latest_price(instrument_id) ====='
CREATE OR REPLACE FUNCTION review2.fn_latest_price(p_instrument_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    -- Latest tick by market time; ties broken by tick_id, the same order
    -- the alert trigger and ix_price_ticks_instrument_time use.
    SELECT t.price
    FROM price_ticks t
    WHERE t.instrument_id = p_instrument_id
    ORDER BY t.observed_at DESC, t.tick_id DESC
    LIMIT 1;
$$;
COMMENT ON FUNCTION review2.fn_latest_price(BIGINT) IS
    'Latest price of an instrument, NULL if it has no ticks.';

SELECT i.symbol, review2.fn_latest_price(i.instrument_id) AS latest_price
FROM instruments i
ORDER BY i.symbol;

\echo '===== 2b. FUNCTION review2.fn_rule_distance_pct(rule_id) ====='
CREATE OR REPLACE FUNCTION review2.fn_rule_distance_pct(p_rule_id BIGINT)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_direction TEXT;
    v_threshold NUMERIC;
    v_latest    NUMERIC;
BEGIN
    SELECT r.direction, r.threshold, review2.fn_latest_price(r.instrument_id)
    INTO v_direction, v_threshold, v_latest
    FROM alert_rules r
    WHERE r.rule_id = p_rule_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'fn_rule_distance_pct: rule % does not exist', p_rule_id
        USING ERRCODE = 'no_data_found';
    END IF;
    IF v_latest IS NULL THEN
        RETURN NULL;                     -- no price yet
    END IF;

    -- Positive: the price must still move this many % towards the
    -- threshold before the rule can fire. Zero or negative: the price is
    -- already on (or past) the threshold side.
    RETURN round(100 * CASE v_direction
                           WHEN 'ABOVE' THEN v_threshold - v_latest
                           ELSE v_latest - v_threshold
                       END / v_latest, 2);
END;
$$;
COMMENT ON FUNCTION review2.fn_rule_distance_pct(BIGINT) IS
    'Signed % distance from the latest price to a rule threshold (> 0: still has to move).';

SELECT r.rule_id, r.direction, r.threshold, r.is_active,
       review2.fn_rule_distance_pct(r.rule_id) AS distance_pct
FROM alert_rules r
ORDER BY r.rule_id;

\set ON_ERROR_STOP off
\echo '>>> EXPECTED ERROR [P0002] unknown rule id'
SELECT review2.fn_rule_distance_pct(999);
\echo '<<< actual SQLSTATE:' :SQLSTATE
\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------
\echo '===== 3a. PROCEDURE review2.sp_add_watchlist_item(username, watchlist, exchange, symbol) ====='
CREATE OR REPLACE PROCEDURE review2.sp_add_watchlist_item(
    p_username  TEXT,
    p_watchlist TEXT,
    p_exchange  TEXT,
    p_symbol    TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_watchlist_id  BIGINT;
    v_instrument_id BIGINT;
BEGIN
    SELECT w.watchlist_id INTO v_watchlist_id
    FROM watchlists w JOIN users u ON u.user_id = w.user_id
    WHERE u.username = p_username AND w.name = p_watchlist;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no watchlist "%" for user %', p_watchlist, p_username
        USING ERRCODE = 'no_data_found';
    END IF;

    SELECT i.instrument_id INTO v_instrument_id
    FROM instruments i
    WHERE i.exchange = p_exchange AND i.symbol = p_symbol;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown instrument %:%', p_exchange, p_symbol
        USING ERRCODE = 'no_data_found';
    END IF;

    INSERT INTO watchlist_items (watchlist_id, instrument_id)
    VALUES (v_watchlist_id, v_instrument_id)
    ON CONFLICT ON CONSTRAINT pk_watchlist_items DO NOTHING;

    IF FOUND THEN
        RAISE NOTICE 'added %:% to %/%', p_exchange, p_symbol, p_username, p_watchlist;
    ELSE
        RAISE NOTICE '%:% is already in %/% - nothing changed', p_exchange, p_symbol, p_username, p_watchlist;
    END IF;
END;
$$;

\echo '===== 3b. PROCEDURE review2.sp_set_rule_active(rule_id, active, INOUT previous) ====='
CREATE OR REPLACE PROCEDURE review2.sp_set_rule_active(
    p_rule_id  BIGINT,
    p_active   BOOLEAN,
    INOUT p_previous BOOLEAN DEFAULT NULL)
LANGUAGE plpgsql
AS $$
BEGIN
    SELECT is_active INTO p_previous
    FROM alert_rules WHERE rule_id = p_rule_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'rule % does not exist', p_rule_id
        USING ERRCODE = 'no_data_found';
    END IF;

    UPDATE alert_rules SET is_active = p_active WHERE rule_id = p_rule_id;
    RAISE NOTICE 'rule %: is_active % -> %', p_rule_id, p_previous, p_active;
END;
$$;

\echo '===== Routines now in schema review2 ====='
SELECT p.proname AS routine,
       CASE p.prokind WHEN 'f' THEN 'FUNCTION' WHEN 'p' THEN 'PROCEDURE' END AS kind,
       pg_get_function_arguments(p.oid) AS arguments,
       pg_get_function_result(p.oid)    AS returns
FROM pg_proc p
WHERE p.pronamespace = 'review2'::regnamespace
ORDER BY kind, routine;

\echo '===== Calling the procedures (transaction rolled back at the end) ====='
BEGIN;
\echo 'kavya receives ETHUSDT alerts but does not watch it (CQ08); add it to "Main":'
CALL review2.sp_add_watchlist_item('kavya', 'Main', 'BINANCE', 'ETHUSDT');
SELECT watchlist, symbol FROM review2.v_watchlist_contents WHERE username = 'kavya' ORDER BY symbol;
\echo 'calling it again changes nothing (ON CONFLICT DO NOTHING):'
CALL review2.sp_add_watchlist_item('kavya', 'Main', 'BINANCE', 'ETHUSDT');

\echo 're-enable priya INFY rule 5; the INOUT parameter returns the previous state:'
CALL review2.sp_set_rule_active(5, true);
SELECT rule_id, is_active FROM alert_rules WHERE rule_id = 5;

\set ON_ERROR_STOP off
SAVEPOINT before_bad_call;
\echo '>>> EXPECTED ERROR [P0002] unknown instrument'
CALL review2.sp_add_watchlist_item('kavya', 'Main', 'NSE', 'NOSUCH');
\echo '<<< actual SQLSTATE:' :SQLSTATE
ROLLBACK TO SAVEPOINT before_bad_call;
\echo '>>> EXPECTED ERROR [42809] a procedure is not called with SELECT (wrong_object_type: use CALL)'
SELECT review2.sp_set_rule_active(5, false);
\echo '<<< actual SQLSTATE:' :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK;

\echo '===== After ROLLBACK: kavya Main and rule 5 are unchanged ====='
SELECT (SELECT count(*) FROM watchlist_items wi JOIN watchlists w USING (watchlist_id)
         JOIN users u USING (user_id) WHERE u.username = 'kavya') AS kavya_items,
       (SELECT is_active FROM alert_rules WHERE rule_id = 5)       AS rule5_is_active;
