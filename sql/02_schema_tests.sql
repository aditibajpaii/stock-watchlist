-- =====================================================================
-- 02_schema_tests.sql
-- Executable tests for the base schema constraints.
--
-- Prerequisite: 00_schema.sql and 01_seed.sql have been run.
-- Run:  psql -d stock_watchlist -v ON_ERROR_STOP=1 -f sql/02_schema_tests.sql
--
-- Everything runs inside one transaction that is ROLLED BACK at the end,
-- so the seed data is unchanged afterwards.
--
-- A negative test PASSES only if PostgreSQL raises the expected SQLSTATE
-- from the expected named constraint:
--   23505 unique_violation       23514 check_violation
--   23503 foreign_key_violation  23001 restrict_violation
-- Each attempt runs in its own subtransaction (plpgsql EXCEPTION block),
-- so one expected error does not abort the rest of the script.
--
-- NOTE: price_ticks / alert_events rows are inserted directly here only to
-- test constraints. Operational ingestion will go through ingest_tick
-- (Phase 4).
-- =====================================================================

\set QUIET on
\pset footer off
BEGIN;

CREATE TEMP TABLE test_results (
    test_no   INT GENERATED ALWAYS AS IDENTITY,
    test_name TEXT,
    expected  TEXT,
    actual    TEXT,
    result    TEXT
) ON COMMIT DROP;

-- ---- helpers (temporary, session-only) ------------------------------

-- id lookups by natural key
CREATE FUNCTION pg_temp.uid(p_username TEXT) RETURNS BIGINT
LANGUAGE sql AS $$ SELECT user_id FROM users WHERE username = p_username $$;

CREATE FUNCTION pg_temp.iid(p_exchange TEXT, p_symbol TEXT) RETURNS BIGINT
LANGUAGE sql AS $$
    SELECT instrument_id FROM instruments
    WHERE exchange = p_exchange AND symbol = p_symbol $$;

-- statement must FAIL with this SQLSTATE and this constraint
CREATE FUNCTION pg_temp.expect_error(p_test TEXT, p_sql TEXT,
                                     p_state TEXT, p_constraint TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_state TEXT;
    v_con   TEXT;
BEGIN
    BEGIN
        EXECUTE p_sql;
        -- reached only if no error: undo the change and record it
        RAISE EXCEPTION 'statement succeeded' USING ERRCODE = 'P0001';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE,
                                v_con   = CONSTRAINT_NAME;
    END;
    INSERT INTO test_results (test_name, expected, actual, result)
    VALUES (p_test,
            p_state || ' ' || p_constraint,
            CASE WHEN v_state = 'P0001' THEN 'no error'
                 ELSE v_state || ' ' || coalesce(nullif(v_con, ''), '-') END,
            CASE WHEN v_state = p_state AND v_con = p_constraint
                 THEN 'PASS' ELSE 'FAIL' END);
END $$;

-- statement must SUCCEED
CREATE FUNCTION pg_temp.expect_ok(p_test TEXT, p_sql TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_state TEXT;
    v_con   TEXT;
BEGIN
    EXECUTE p_sql;
    INSERT INTO test_results (test_name, expected, actual, result)
    VALUES (p_test, 'success', 'success', 'PASS');
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE,
                            v_con   = CONSTRAINT_NAME;
    INSERT INTO test_results (test_name, expected, actual, result)
    VALUES (p_test, 'success',
            v_state || ' ' || coalesce(nullif(v_con, ''), '-'), 'FAIL');
END $$;

-- query must return true
CREATE FUNCTION pg_temp.expect_true(p_test TEXT, p_sql TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_ok BOOLEAN;
BEGIN
    EXECUTE p_sql INTO v_ok;
    INSERT INTO test_results (test_name, expected, actual, result)
    VALUES (p_test, 'true', coalesce(v_ok::TEXT, 'null'),
            CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END);
END $$;

-- ---- test fixtures: a few ticks and one alert event ------------------
-- Inserted directly (constraint testing only).
INSERT INTO price_ticks (instrument_id, observed_at, price, volume, source, source_event_id)
VALUES (pg_temp.iid('NSE', 'RELIANCE'), '2026-09-25 10:00:00+05:30', 2990.00, 100, 'REPLAY', 'test:000001'),
       (pg_temp.iid('NSE', 'RELIANCE'), '2026-09-25 10:00:01+05:30', 3005.00, 150, 'REPLAY', 'test:000002'),
       (pg_temp.iid('NSE', 'TCS'),      '2026-09-25 10:00:00+05:30', 3600.00, NULL, 'REPLAY', 'test:000003');

-- arjun's "RELIANCE ABOVE 3000" rule fired on the 3005 tick.
-- Since Phase 4 the alert trigger already creates this event when the
-- ticks above are inserted; ON CONFLICT keeps the fixture valid with or
-- without the trigger.
INSERT INTO alert_events (rule_id, tick_id)
SELECT r.rule_id, t.tick_id
FROM alert_rules r
JOIN price_ticks t ON t.source = 'REPLAY' AND t.source_event_id = 'test:000002'
WHERE r.user_id = pg_temp.uid('arjun')
  AND r.instrument_id = pg_temp.iid('NSE', 'RELIANCE')
  AND r.direction = 'ABOVE'
ON CONFLICT ON CONSTRAINT uq_alert_events_rule_tick DO NOTHING;

\o /dev/null
-- (test calls return nothing useful; results are printed at the end)

-- =====================================================================
-- A. UNIQUE constraints
-- =====================================================================
SELECT pg_temp.expect_error('A1 duplicate username rejected',
  $q$ INSERT INTO users (username, email) VALUES ('arjun', 'other@example.com') $q$,
  '23505', 'uq_users_username');

SELECT pg_temp.expect_error('A2 duplicate email rejected',
  $q$ INSERT INTO users (username, email) VALUES ('arjun2', 'arjun@example.com') $q$,
  '23505', 'uq_users_email');

SELECT pg_temp.expect_error('A3 duplicate instrument (exchange, symbol) rejected',
  $q$ INSERT INTO instruments (exchange, symbol, name, quote_currency)
      VALUES ('NSE', 'RELIANCE', 'Duplicate', 'INR') $q$,
  '23505', 'uq_instruments_exchange_symbol');

SELECT pg_temp.expect_ok('A4 same symbol on a different exchange accepted',
  $q$ INSERT INTO instruments (exchange, symbol, name, quote_currency)
      VALUES ('BSE', 'RELIANCE', 'Reliance Industries Ltd', 'INR') $q$);

SELECT pg_temp.expect_error('A5 duplicate watchlist name for same user rejected',
  $q$ INSERT INTO watchlists (user_id, name) VALUES (pg_temp.uid('arjun'), 'Crypto') $q$,
  '23505', 'uq_watchlists_user_name');

SELECT pg_temp.expect_ok('A6 same watchlist name for a different user accepted',
  $q$ INSERT INTO watchlists (user_id, name) VALUES (pg_temp.uid('kavya'), 'Crypto') $q$);

SELECT pg_temp.expect_error('A7 duplicate watchlist item rejected',
  $q$ INSERT INTO watchlist_items (watchlist_id, instrument_id)
      SELECT watchlist_id, pg_temp.iid('BINANCE', 'BTCUSDT') FROM watchlists
      WHERE user_id = pg_temp.uid('arjun') AND name = 'Crypto' $q$,
  '23505', 'pk_watchlist_items');

SELECT pg_temp.expect_error('A8 duplicate tick identity (source, instrument, event id) rejected',
  $q$ INSERT INTO price_ticks (instrument_id, observed_at, price, source, source_event_id)
      VALUES (pg_temp.iid('NSE', 'RELIANCE'), '2026-09-25 11:00:00+05:30', 3100, 'REPLAY', 'test:000001') $q$,
  '23505', 'uq_price_ticks_source_event');

SELECT pg_temp.expect_ok('A9 same source_event_id on a different instrument accepted',
  $q$ INSERT INTO price_ticks (instrument_id, observed_at, price, source, source_event_id)
      VALUES (pg_temp.iid('NSE', 'INFY'), '2026-09-25 10:00:00+05:30', 1500, 'REPLAY', 'test:000001') $q$);

SELECT pg_temp.expect_ok('A10 same instrument + same observed_at, different event id accepted',
  $q$ INSERT INTO price_ticks (instrument_id, observed_at, price, source, source_event_id)
      VALUES (pg_temp.iid('NSE', 'RELIANCE'), '2026-09-25 10:00:00+05:30', 2991, 'REPLAY', 'test:000099') $q$);

SELECT pg_temp.expect_error('A11 duplicate alert rule definition rejected',
  $q$ INSERT INTO alert_rules (user_id, instrument_id, direction, threshold)
      VALUES (pg_temp.uid('arjun'), pg_temp.iid('NSE', 'RELIANCE'), 'ABOVE', 3000) $q$,
  '23505', 'uq_alert_rules_definition');

SELECT pg_temp.expect_error('A12 same rule firing twice on the same tick rejected',
  $q$ INSERT INTO alert_events (rule_id, tick_id) SELECT rule_id, tick_id FROM alert_events LIMIT 1 $q$,
  '23505', 'uq_alert_events_rule_tick');

-- =====================================================================
-- B. CHECK constraints
-- =====================================================================
SELECT pg_temp.expect_error('B1 negative price rejected',
  $q$ INSERT INTO price_ticks (instrument_id, observed_at, price, source, source_event_id)
      VALUES (pg_temp.iid('NSE', 'TCS'), now(), -1, 'MANUAL', 'manual:b1') $q$,
  '23514', 'ck_price_ticks_price_pos');

SELECT pg_temp.expect_error('B2 zero price rejected',
  $q$ INSERT INTO price_ticks (instrument_id, observed_at, price, source, source_event_id)
      VALUES (pg_temp.iid('NSE', 'TCS'), now(), 0, 'MANUAL', 'manual:b2') $q$,
  '23514', 'ck_price_ticks_price_pos');

SELECT pg_temp.expect_error('B3 negative volume rejected',
  $q$ INSERT INTO price_ticks (instrument_id, observed_at, price, volume, source, source_event_id)
      VALUES (pg_temp.iid('NSE', 'TCS'), now(), 3600, -5, 'MANUAL', 'manual:b3') $q$,
  '23514', 'ck_price_ticks_volume_nonneg');

SELECT pg_temp.expect_ok('B4 NULL (unknown) volume accepted',
  $q$ INSERT INTO price_ticks (instrument_id, observed_at, price, volume, source, source_event_id)
      VALUES (pg_temp.iid('NSE', 'TCS'), now(), 3600, NULL, 'MANUAL', 'manual:b4') $q$);

SELECT pg_temp.expect_ok('B5 zero volume accepted',
  $q$ INSERT INTO price_ticks (instrument_id, observed_at, price, volume, source, source_event_id)
      VALUES (pg_temp.iid('NSE', 'TCS'), now(), 3600, 0, 'MANUAL', 'manual:b5') $q$);

SELECT pg_temp.expect_error('B6 invalid tick source rejected',
  $q$ INSERT INTO price_ticks (instrument_id, observed_at, price, source, source_event_id)
      VALUES (pg_temp.iid('NSE', 'TCS'), now(), 3600, 'YAHOO', 'yahoo:1') $q$,
  '23514', 'ck_price_ticks_source');

SELECT pg_temp.expect_error('B7 blank source_event_id rejected',
  $q$ INSERT INTO price_ticks (instrument_id, observed_at, price, source, source_event_id)
      VALUES (pg_temp.iid('NSE', 'TCS'), now(), 3600, 'MANUAL', '  ') $q$,
  '23514', 'ck_price_ticks_source_event_not_blank');

SELECT pg_temp.expect_error('B8 invalid alert direction rejected',
  $q$ INSERT INTO alert_rules (user_id, instrument_id, direction, threshold)
      VALUES (pg_temp.uid('priya'), pg_temp.iid('NSE', 'TCS'), 'SIDEWAYS', 3000) $q$,
  '23514', 'ck_alert_rules_direction');

SELECT pg_temp.expect_error('B9 zero threshold rejected',
  $q$ INSERT INTO alert_rules (user_id, instrument_id, direction, threshold)
      VALUES (pg_temp.uid('priya'), pg_temp.iid('NSE', 'TCS'), 'ABOVE', 0) $q$,
  '23514', 'ck_alert_rules_threshold_pos');

SELECT pg_temp.expect_error('B10 negative threshold rejected',
  $q$ INSERT INTO alert_rules (user_id, instrument_id, direction, threshold)
      VALUES (pg_temp.uid('priya'), pg_temp.iid('NSE', 'TCS'), 'ABOVE', -10) $q$,
  '23514', 'ck_alert_rules_threshold_pos');

SELECT pg_temp.expect_error('B11 negative cooldown rejected',
  $q$ INSERT INTO alert_rules (user_id, instrument_id, direction, threshold, cooldown_seconds)
      VALUES (pg_temp.uid('priya'), pg_temp.iid('NSE', 'TCS'), 'ABOVE', 4000, -1) $q$,
  '23514', 'ck_alert_rules_cooldown_nonneg');

SELECT pg_temp.expect_ok('B12 zero cooldown accepted',
  $q$ INSERT INTO alert_rules (user_id, instrument_id, direction, threshold, cooldown_seconds)
      VALUES (pg_temp.uid('priya'), pg_temp.iid('NSE', 'TCS'), 'ABOVE', 4000, 0) $q$);

SELECT pg_temp.expect_error('B13 invalid username format rejected',
  $q$ INSERT INTO users (username, email) VALUES ('Bad Name', 'bad@example.com') $q$,
  '23514', 'ck_users_username_format');

SELECT pg_temp.expect_error('B14 invalid email rejected',
  $q$ INSERT INTO users (username, email) VALUES ('noemail', 'not-an-email') $q$,
  '23514', 'ck_users_email_format');

SELECT pg_temp.expect_error('B15 invalid exchange rejected',
  $q$ INSERT INTO instruments (exchange, symbol, name, quote_currency)
      VALUES ('NYSE', 'IBM', 'IBM', 'USD') $q$,
  '23514', 'ck_instruments_exchange');

SELECT pg_temp.expect_error('B16 blank watchlist name rejected',
  $q$ INSERT INTO watchlists (user_id, name) VALUES (pg_temp.uid('priya'), '   ') $q$,
  '23514', 'ck_watchlists_name');

-- =====================================================================
-- C. FOREIGN KEY violations on insert
-- =====================================================================
SELECT pg_temp.expect_error('C1 watchlist for non-existent user rejected',
  $q$ INSERT INTO watchlists (user_id, name) VALUES (999999, 'Ghost') $q$,
  '23503', 'fk_watchlists_user');

SELECT pg_temp.expect_error('C2 watchlist item for non-existent watchlist rejected',
  $q$ INSERT INTO watchlist_items (watchlist_id, instrument_id)
      VALUES (999999, pg_temp.iid('NSE', 'TCS')) $q$,
  '23503', 'fk_watchlist_items_watchlist');

SELECT pg_temp.expect_error('C3 watchlist item for non-existent instrument rejected',
  $q$ INSERT INTO watchlist_items (watchlist_id, instrument_id)
      SELECT min(watchlist_id), 999999 FROM watchlists $q$,
  '23503', 'fk_watchlist_items_instrument');

SELECT pg_temp.expect_error('C4 tick for non-existent instrument rejected',
  $q$ INSERT INTO price_ticks (instrument_id, observed_at, price, source, source_event_id)
      VALUES (999999, now(), 100, 'MANUAL', 'manual:c4') $q$,
  '23503', 'fk_price_ticks_instrument');

SELECT pg_temp.expect_error('C5 alert rule for non-existent user rejected',
  $q$ INSERT INTO alert_rules (user_id, instrument_id, direction, threshold)
      VALUES (999999, pg_temp.iid('NSE', 'TCS'), 'ABOVE', 5000) $q$,
  '23503', 'fk_alert_rules_user');

SELECT pg_temp.expect_error('C6 alert rule for non-existent instrument rejected',
  $q$ INSERT INTO alert_rules (user_id, instrument_id, direction, threshold)
      VALUES (pg_temp.uid('priya'), 999999, 'ABOVE', 5000) $q$,
  '23503', 'fk_alert_rules_instrument');

SELECT pg_temp.expect_error('C7 alert event for non-existent rule rejected',
  $q$ INSERT INTO alert_events (rule_id, tick_id) SELECT 999999, min(tick_id) FROM price_ticks $q$,
  '23503', 'fk_alert_events_rule');

SELECT pg_temp.expect_error('C8 alert event for non-existent tick rejected',
  $q$ INSERT INTO alert_events (rule_id, tick_id) SELECT min(rule_id), 999999 FROM alert_rules $q$,
  '23503', 'fk_alert_events_tick');

-- =====================================================================
-- D. ON DELETE RESTRICT (shared market / reference data)
-- Each case uses a fresh instrument referenced by exactly ONE table, so
-- the specific RESTRICT constraint is proven.
-- =====================================================================
INSERT INTO instruments (exchange, symbol, name, quote_currency) VALUES
    ('NSE', 'TSTITEM',  'Test: referenced by watchlist item', 'INR'),
    ('NSE', 'TSTRULE',  'Test: referenced by alert rule',     'INR'),
    ('NSE', 'TSTTICK',  'Test: referenced by price tick',     'INR'),
    ('NSE', 'TSTFREE',  'Test: unreferenced',                 'INR');

INSERT INTO watchlist_items (watchlist_id, instrument_id)
SELECT watchlist_id, pg_temp.iid('NSE', 'TSTITEM') FROM watchlists
WHERE user_id = pg_temp.uid('priya') AND name = 'Tech';

INSERT INTO alert_rules (user_id, instrument_id, direction, threshold)
VALUES (pg_temp.uid('priya'), pg_temp.iid('NSE', 'TSTRULE'), 'ABOVE', 100);

INSERT INTO price_ticks (instrument_id, observed_at, price, source, source_event_id)
VALUES (pg_temp.iid('NSE', 'TSTTICK'), now(), 100, 'MANUAL', 'manual:d3');

SELECT pg_temp.expect_error('D1 delete instrument used in a watchlist blocked',
  $q$ DELETE FROM instruments WHERE exchange = 'NSE' AND symbol = 'TSTITEM' $q$,
  '23001', 'fk_watchlist_items_instrument');

SELECT pg_temp.expect_error('D2 delete instrument used by an alert rule blocked',
  $q$ DELETE FROM instruments WHERE exchange = 'NSE' AND symbol = 'TSTRULE' $q$,
  '23001', 'fk_alert_rules_instrument');

SELECT pg_temp.expect_error('D3 delete instrument with price history blocked',
  $q$ DELETE FROM instruments WHERE exchange = 'NSE' AND symbol = 'TSTTICK' $q$,
  '23001', 'fk_price_ticks_instrument');

SELECT pg_temp.expect_error('D4 delete price tick referenced by an alert event blocked',
  $q$ DELETE FROM price_ticks WHERE tick_id = (SELECT min(tick_id) FROM alert_events) $q$,
  '23001', 'fk_alert_events_tick');

SELECT pg_temp.expect_ok('D5 delete unreferenced instrument allowed',
  $q$ DELETE FROM instruments WHERE exchange = 'NSE' AND symbol = 'TSTFREE' $q$);

-- =====================================================================
-- E. ON DELETE CASCADE (user-owned data) - never touches price history
-- =====================================================================
CREATE TEMP TABLE snap ON COMMIT DROP AS
SELECT (SELECT count(*) FROM price_ticks) AS ticks,
       (SELECT count(*) FROM alert_rules  WHERE user_id <> pg_temp.uid('arjun')) AS other_rules,
       (SELECT count(*) FROM watchlists   WHERE user_id <> pg_temp.uid('arjun')) AS other_lists,
       (SELECT count(*) FROM watchlist_items wi JOIN watchlists w USING (watchlist_id)
         WHERE w.user_id = pg_temp.uid('priya') AND w.name = 'Tech') AS tech_items,
       pg_temp.uid('arjun') AS arjun_id;

-- E1-E2: deleting a watchlist removes only its items
SELECT pg_temp.expect_ok('E0 delete watchlist priya/Tech succeeds',
  $q$ DELETE FROM watchlists WHERE user_id = pg_temp.uid('priya') AND name = 'Tech' $q$);

SELECT pg_temp.expect_true('E1 deleting a watchlist cascades to its items',
  $q$ SELECT (SELECT tech_items FROM snap) > 0
         AND NOT EXISTS (SELECT 1 FROM watchlist_items wi
                         LEFT JOIN watchlists w USING (watchlist_id)
                         WHERE w.watchlist_id IS NULL) $q$);

SELECT pg_temp.expect_true('E2 deleting a watchlist keeps all price ticks',
  $q$ SELECT count(*) = (SELECT ticks FROM snap) FROM price_ticks $q$);

-- E3-E8: delete user arjun (owns 2 watchlists, 3 rules, 1 alert event)
SELECT pg_temp.expect_ok('E2b delete user arjun succeeds',
  $q$ DELETE FROM users WHERE username = 'arjun' $q$);

SELECT pg_temp.expect_true('E3 user delete cascades to watchlists',
  $q$ SELECT NOT EXISTS (SELECT 1 FROM watchlists WHERE user_id = (SELECT arjun_id FROM snap)) $q$);

SELECT pg_temp.expect_true('E4 user delete cascades to watchlist items (via watchlists)',
  $q$ SELECT NOT EXISTS (SELECT 1 FROM watchlist_items wi
                         LEFT JOIN watchlists w USING (watchlist_id)
                         WHERE w.watchlist_id IS NULL) $q$);

SELECT pg_temp.expect_true('E5 user delete cascades to alert rules',
  $q$ SELECT NOT EXISTS (SELECT 1 FROM alert_rules WHERE user_id = (SELECT arjun_id FROM snap)) $q$);

SELECT pg_temp.expect_true('E6 user delete cascades to alert events (via rules)',
  $q$ SELECT count(*) = 0 FROM alert_events $q$);

SELECT pg_temp.expect_true('E7 user delete keeps ALL price ticks',
  $q$ SELECT count(*) = (SELECT ticks FROM snap) FROM price_ticks $q$);

SELECT pg_temp.expect_true('E8 user delete leaves other users'' rules and watchlists',
  $q$ SELECT (SELECT count(*) FROM alert_rules) = (SELECT other_rules FROM snap)
         AND (SELECT count(*) FROM watchlists)  = (SELECT other_lists FROM snap) - 1 $q$);
-- (other_lists - 1 because priya's 'Tech' list was deleted in E1)

\o
-- =====================================================================
-- Results
-- =====================================================================
\echo
\echo '===== SCHEMA TEST RESULTS ====='
SELECT test_no AS "#", result, test_name, expected, actual
FROM test_results ORDER BY test_no;

SELECT count(*) FILTER (WHERE result = 'PASS') AS passed,
       count(*) FILTER (WHERE result = 'FAIL') AS failed,
       count(*) AS total
FROM test_results;

-- make psql exit non-zero if anything failed
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM test_results WHERE result = 'FAIL') THEN
        RAISE EXCEPTION 'SCHEMA TESTS FAILED';
    END IF;
END $$;

ROLLBACK;
\echo 'All changes rolled back; seed data unchanged.'
