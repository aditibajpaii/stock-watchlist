-- =====================================================================
-- 04_alert_tests.sql
-- Executable tests for ingest_tick, the alert trigger and the
-- alert_events integrity trigger.
--
-- Prerequisite: 00_schema.sql, 01_seed.sql, 03_functions_triggers.sql
-- Run:  psql -d stock_watchlist -v ON_ERROR_STOP=1 -f sql/04_alert_tests.sql
--
-- Seed data is untouched:
--   * Part 1 (top-level ROLLBACK test) creates its own fixtures and rolls
--     them back.
--   * Part 2 creates its own test users/instruments/rules inside one
--     transaction that is ROLLED BACK at the end.
-- Every test compares an exact expected value with the actual value.
-- Ticks use fixed market times (base 2026-01-05 09:15:00 IST + N s) on
-- dedicated test instruments, so existing data cannot affect results.
-- Concurrency and NOTIFY delivery need several sessions:
-- see tests/concurrency_test.sh.
-- =====================================================================

\set QUIET on
\pset footer off
\o /dev/null

-- =====================================================================
-- PART 1. Test 18 (top level): a real transaction that would create an
-- alert is ROLLED BACK; afterwards nothing it did may remain.
-- =====================================================================
SELECT count(*) AS rb_events_before FROM alert_events \gset
SELECT count(*) AS rb_ticks_before  FROM price_ticks  \gset

BEGIN;
INSERT INTO users (username, email) VALUES ('rb_user', 'rb_user@example.com');
INSERT INTO instruments (exchange, symbol, name, quote_currency)
VALUES ('NSE', 'TSTRBTOP', 'Test: top-level rollback', 'INR');
INSERT INTO alert_rules (user_id, instrument_id, direction, threshold, cooldown_seconds)
SELECT u.user_id, i.instrument_id, 'ABOVE', 3000, 0
FROM users u, instruments i
WHERE u.username = 'rb_user' AND i.exchange = 'NSE' AND i.symbol = 'TSTRBTOP';
SELECT * FROM ingest_tick('NSE', 'TSTRBTOP', '2026-01-05 09:15:00+05:30', 2990, NULL, 'MANUAL', 'rbtop:1');
SELECT * FROM ingest_tick('NSE', 'TSTRBTOP', '2026-01-05 09:15:01+05:30', 3010, NULL, 'MANUAL', 'rbtop:2');
SELECT count(*) AS rb_events_inside FROM alert_events \gset
ROLLBACK;

SELECT count(*) AS rb_events_after FROM alert_events \gset
SELECT count(*) AS rb_ticks_after  FROM price_ticks  \gset
SELECT count(*) AS rb_instr_after  FROM instruments WHERE symbol = 'TSTRBTOP' \gset

-- =====================================================================
-- PART 2. Main test transaction (rolled back at the end)
-- =====================================================================
BEGIN;

CREATE TEMP TABLE test_results (
    test_no   INT GENERATED ALWAYS AS IDENTITY,
    test_name TEXT,
    expected  TEXT,
    actual    TEXT,
    result    TEXT
) ON COMMIT DROP;

CREATE TEMP TABLE test_rules (
    name    TEXT PRIMARY KEY,
    rule_id BIGINT NOT NULL
) ON COMMIT DROP;

-- ---- harness --------------------------------------------------------
CREATE FUNCTION pg_temp.record(p_test TEXT, p_expected TEXT, p_actual TEXT)
RETURNS VOID LANGUAGE sql AS $$
    INSERT INTO test_results (test_name, expected, actual, result)
    VALUES (p_test, p_expected, coalesce(p_actual, 'null'),
            CASE WHEN p_actual IS NOT DISTINCT FROM p_expected THEN 'PASS' ELSE 'FAIL' END);
$$;

-- run a query returning one value; compare its text form with p_expected
CREATE FUNCTION pg_temp.expect_eq(p_test TEXT, p_sql TEXT, p_expected TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_actual TEXT;
BEGIN
    EXECUTE p_sql INTO v_actual;
    PERFORM pg_temp.record(p_test, p_expected, v_actual);
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.record(p_test, p_expected, 'ERROR ' || SQLSTATE || ' ' || SQLERRM);
END $$;

-- statement must fail with this SQLSTATE and (if given) this constraint name
CREATE FUNCTION pg_temp.expect_error(p_test TEXT, p_sql TEXT,
                                     p_state TEXT, p_constraint TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_state TEXT;
    v_con   TEXT;
BEGIN
    BEGIN
        EXECUTE p_sql;
        RAISE EXCEPTION 'statement succeeded' USING ERRCODE = 'P0001';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE,
                                v_con   = CONSTRAINT_NAME;
    END;
    PERFORM pg_temp.record(
        p_test,
        p_state || ' ' || coalesce(p_constraint, '-'),
        CASE WHEN v_state = 'P0001' THEN 'no error'
             ELSE v_state || ' ' || coalesce(nullif(v_con, ''), '-') END);
END $$;

-- ---- fixture helpers ------------------------------------------------
-- market time = base + p_sec seconds
CREATE FUNCTION pg_temp.ts(p_sec INT) RETURNS TIMESTAMPTZ
LANGUAGE sql AS $$ SELECT '2026-01-05 09:15:00+05:30'::timestamptz + make_interval(secs => p_sec) $$;

-- ingest a MANUAL tick on an NSE test instrument; returns the status
CREATE FUNCTION pg_temp.tick(p_symbol TEXT, p_sec INT, p_price NUMERIC, p_eid TEXT)
RETURNS TEXT LANGUAGE sql AS $$
    SELECT status FROM ingest_tick('NSE', p_symbol, pg_temp.ts(p_sec), p_price, NULL,
                                   'MANUAL', 'test:' || p_symbol || ':' || p_eid);
$$;

CREATE FUNCTION pg_temp.rid(p_name TEXT) RETURNS BIGINT
LANGUAGE sql AS $$ SELECT rule_id FROM test_rules WHERE name = p_name $$;

-- number of events for a named test rule
CREATE FUNCTION pg_temp.events(p_name TEXT) RETURNS BIGINT
LANGUAGE sql AS $$ SELECT count(*) FROM alert_events WHERE rule_id = pg_temp.rid(p_name) $$;

-- number of stored ticks for an NSE test instrument
CREATE FUNCTION pg_temp.ticks(p_symbol TEXT) RETURNS BIGINT
LANGUAGE sql AS $$
    SELECT count(*) FROM price_ticks t JOIN instruments i USING (instrument_id)
    WHERE i.exchange = 'NSE' AND i.symbol = p_symbol $$;

CREATE FUNCTION pg_temp.mkrule(p_name TEXT, p_user TEXT, p_symbol TEXT, p_dir TEXT,
                               p_threshold NUMERIC, p_cooldown INT, p_active BOOLEAN)
RETURNS VOID LANGUAGE sql AS $$
    WITH r AS (
        INSERT INTO alert_rules (user_id, instrument_id, direction, threshold,
                                 cooldown_seconds, is_active)
        SELECT u.user_id, i.instrument_id, p_dir, p_threshold, p_cooldown, p_active
        FROM users u, instruments i
        WHERE u.username = p_user AND i.exchange = 'NSE' AND i.symbol = p_symbol
        RETURNING rule_id)
    INSERT INTO test_rules SELECT p_name, rule_id FROM r;
$$;

-- ---- fixtures -------------------------------------------------------
INSERT INTO users (username, email) VALUES
    ('test_user1', 'test_user1@example.com'),
    ('test_user2', 'test_user2@example.com');

INSERT INTO instruments (exchange, symbol, name, quote_currency, is_active) VALUES
    ('NSE', 'TSTUP',    'Test: ABOVE crossing',   'INR', true),
    ('NSE', 'TSTDN',    'Test: BELOW crossing',   'INR', true),
    ('NSE', 'TSTEQA',   'Test: ABOVE equality',   'INR', true),
    ('NSE', 'TSTEQB',   'Test: BELOW equality',   'INR', true),
    ('NSE', 'TSTCOOL',  'Test: cooldown',         'INR', true),
    ('NSE', 'TSTDUP',   'Test: duplicate input',  'INR', true),
    ('NSE', 'TSTSAME',  'Test: same observed_at', 'INR', true),
    ('NSE', 'TSTLATE',  'Test: late tick',        'INR', true),
    ('NSE', 'TSTINACT', 'Test: inactive rule',    'INR', true),
    ('NSE', 'TSTMULTI', 'Test: multiple rules',   'INR', true),
    ('NSE', 'TSTRB',    'Test: savepoint rollback','INR', true),
    ('NSE', 'TSTOFF',   'Test: inactive instrument','INR', false);

SELECT pg_temp.mkrule('up',    'test_user1', 'TSTUP',    'ABOVE', 3000,  60, true);
SELECT pg_temp.mkrule('dn',    'test_user1', 'TSTDN',    'BELOW', 2800,   0, true);
SELECT pg_temp.mkrule('eqa',   'test_user1', 'TSTEQA',   'ABOVE', 3000,   0, true);
SELECT pg_temp.mkrule('eqb',   'test_user1', 'TSTEQB',   'BELOW', 2800,   0, true);
SELECT pg_temp.mkrule('cool',  'test_user1', 'TSTCOOL',  'ABOVE', 3000, 300, true);
SELECT pg_temp.mkrule('dup',   'test_user1', 'TSTDUP',   'ABOVE', 3000,   0, true);
SELECT pg_temp.mkrule('same',  'test_user1', 'TSTSAME',  'ABOVE', 3000,   0, true);
SELECT pg_temp.mkrule('late',  'test_user1', 'TSTLATE',  'ABOVE', 3000,   0, true);
SELECT pg_temp.mkrule('inact', 'test_user1', 'TSTINACT', 'ABOVE', 3000,   0, false);
SELECT pg_temp.mkrule('m1',    'test_user1', 'TSTMULTI', 'ABOVE', 3000,   0, true);
SELECT pg_temp.mkrule('m2',    'test_user1', 'TSTMULTI', 'ABOVE', 3050,   0, true);
SELECT pg_temp.mkrule('m3',    'test_user2', 'TSTMULTI', 'ABOVE', 3000,   0, true);
SELECT pg_temp.mkrule('m4',    'test_user1', 'TSTMULTI', 'BELOW', 2900,   0, true);
SELECT pg_temp.mkrule('m5',    'test_user1', 'TSTMULTI', 'ABOVE', 3200,   0, true);
SELECT pg_temp.mkrule('rb',    'test_user1', 'TSTRB',    'ABOVE', 3000,   0, true);

-- =====================================================================
-- 1-4. ABOVE rule 'up' on TSTUP (threshold 3000, cooldown 60 s)
-- =====================================================================
SELECT pg_temp.expect_eq('01a first tick: ingest_tick returns INSERTED with a tick_id',
  $q$ SELECT r.status || ' ' || (r.tick_id IS NOT NULL)
      FROM ingest_tick('NSE','TSTUP', pg_temp.ts(0), 2990, 100, 'MANUAL', 'test:TSTUP:0') r $q$,
  'INSERTED true');
SELECT pg_temp.expect_eq('01b first tick stored exactly once',
  $q$ SELECT pg_temp.ticks('TSTUP') $q$, '1');
SELECT pg_temp.expect_eq('01c first tick creates no alert (no previous price)',
  $q$ SELECT pg_temp.events('up') $q$, '0');

SELECT pg_temp.tick('TSTUP', 1, 2999, '1');
SELECT pg_temp.expect_eq('02a 2990 -> 2999 (still below): no alert',
  $q$ SELECT pg_temp.events('up') $q$, '0');
SELECT pg_temp.tick('TSTUP', 2, 3001, '2');
SELECT pg_temp.expect_eq('02b 2999 -> 3001 crosses ABOVE: exactly one event',
  $q$ SELECT pg_temp.events('up') $q$, '1');
SELECT pg_temp.expect_eq('02c the event references the 3001 tick',
  $q$ SELECT t.price::TEXT FROM alert_events e JOIN price_ticks t USING (tick_id)
      WHERE e.rule_id = pg_temp.rid('up') $q$, '3001.00000000');

SELECT pg_temp.tick('TSTUP', 3, 3010, '3');
SELECT pg_temp.tick('TSTUP', 4, 3020, '4');
SELECT pg_temp.expect_eq('03 staying ABOVE 3001 -> 3010 -> 3020: still exactly one event',
  $q$ SELECT pg_temp.events('up') $q$, '1');

SELECT pg_temp.tick('TSTUP', 10, 2950, '10');
SELECT pg_temp.expect_eq('04a drop below 3000 (2950): no event for a downward move',
  $q$ SELECT pg_temp.events('up') $q$, '1');
SELECT pg_temp.tick('TSTUP', 100, 3005, '100');
SELECT pg_temp.expect_eq('04b re-cross ABOVE at t=100 s (last fire t=2 s, cooldown 60 s): fires again',
  $q$ SELECT pg_temp.events('up') $q$, '2');

-- =====================================================================
-- 5-6. BELOW rule 'dn' on TSTDN (threshold 2800)
-- =====================================================================
SELECT pg_temp.tick('TSTDN', 0, 2850, '0');
SELECT pg_temp.tick('TSTDN', 1, 2790, '1');
SELECT pg_temp.expect_eq('05 2850 -> 2790 crosses BELOW: exactly one event',
  $q$ SELECT pg_temp.events('dn') $q$, '1');
SELECT pg_temp.tick('TSTDN', 2, 2780, '2');
SELECT pg_temp.tick('TSTDN', 3, 2700, '3');
SELECT pg_temp.expect_eq('06 staying BELOW 2790 -> 2780 -> 2700: still exactly one event',
  $q$ SELECT pg_temp.events('dn') $q$, '1');

-- =====================================================================
-- 7-8. Threshold equality
-- =====================================================================
SELECT pg_temp.tick('TSTEQA', 0, 2990, '0');
SELECT pg_temp.tick('TSTEQA', 1, 3000, '1');
SELECT pg_temp.expect_eq('07a ABOVE equality 2990 -> 3000 (= threshold): fires',
  $q$ SELECT pg_temp.events('eqa') $q$, '1');
SELECT pg_temp.tick('TSTEQA', 2, 3010, '2');
SELECT pg_temp.expect_eq('07b from exactly 3000 up to 3010: no second event (already above side)',
  $q$ SELECT pg_temp.events('eqa') $q$, '1');

SELECT pg_temp.tick('TSTEQB', 0, 2810, '0');
SELECT pg_temp.tick('TSTEQB', 1, 2800, '1');
SELECT pg_temp.expect_eq('08a BELOW equality 2810 -> 2800 (= threshold): fires',
  $q$ SELECT pg_temp.events('eqb') $q$, '1');
SELECT pg_temp.tick('TSTEQB', 2, 2790, '2');
SELECT pg_temp.expect_eq('08b from exactly 2800 down to 2790: no second event',
  $q$ SELECT pg_temp.events('eqb') $q$, '1');

-- =====================================================================
-- 9-10. Cooldown: rule 'cool' on TSTCOOL (ABOVE 3000, cooldown 300 s)
-- =====================================================================
SELECT pg_temp.tick('TSTCOOL',   0, 2990, '0');
SELECT pg_temp.tick('TSTCOOL',  10, 3010, '10');     -- fires (1)
SELECT pg_temp.tick('TSTCOOL',  20, 2990, '20');
SELECT pg_temp.tick('TSTCOOL', 100, 3010, '100');    -- crossing inside 10+300
SELECT pg_temp.expect_eq('09a crossing at t=100 s within cooldown of t=10 s fire: suppressed',
  $q$ SELECT pg_temp.events('cool') $q$, '1');
SELECT pg_temp.tick('TSTCOOL', 150, 3020, '150');
SELECT pg_temp.expect_eq('09b suppressed crossing is dropped, not retried while price stays above',
  $q$ SELECT pg_temp.events('cool') $q$, '1');

SELECT pg_temp.tick('TSTCOOL', 200, 2990, '200');
SELECT pg_temp.tick('TSTCOOL', 400, 3010, '400');    -- 400 >= 10+300
SELECT pg_temp.expect_eq('10a crossing at t=400 s, after cooldown (10+300): fires',
  $q$ SELECT pg_temp.events('cool') $q$, '2');
SELECT pg_temp.tick('TSTCOOL', 410, 2990, '410');
SELECT pg_temp.tick('TSTCOOL', 700, 3010, '700');    -- exactly 400+300
SELECT pg_temp.expect_eq('10b crossing exactly at last fire + cooldown (t=700 s): fires',
  $q$ SELECT pg_temp.events('cool') $q$, '3');
SELECT pg_temp.expect_eq('10c fired ticks are t=10, 400, 700 s (cooldown uses observed_at)',
  $q$ SELECT string_agg(extract(epoch FROM t.observed_at - pg_temp.ts(0))::INT::TEXT, ','
                        ORDER BY t.observed_at)
      FROM alert_events e JOIN price_ticks t USING (tick_id)
      WHERE e.rule_id = pg_temp.rid('cool') $q$, '10,400,700');
SELECT pg_temp.expect_eq('10d all 3 events share one fired_at (so fired_at could not drive cooldown)',
  $q$ SELECT count(DISTINCT fired_at) FROM alert_events WHERE rule_id = pg_temp.rid('cool') $q$, '1');

-- =====================================================================
-- 11. Duplicate source event
-- =====================================================================
SELECT pg_temp.tick('TSTDUP', 0, 2990, 'a');
SELECT pg_temp.tick('TSTDUP', 1, 3010, 'b');         -- fires
SELECT pg_temp.expect_eq('11a same (source, instrument, event id) again: returns DUPLICATE, tick_id NULL',
  $q$ SELECT r.status || ' ' || coalesce(r.tick_id::TEXT, 'NULL')
      FROM ingest_tick('NSE','TSTDUP', pg_temp.ts(1), 3010, NULL, 'MANUAL', 'test:TSTDUP:b') r $q$,
  'DUPLICATE NULL');
SELECT pg_temp.expect_eq('11b same event id with a different price/time: still DUPLICATE',
  $q$ SELECT status FROM ingest_tick('NSE','TSTDUP', pg_temp.ts(5), 2000, NULL, 'MANUAL', 'test:TSTDUP:b') $q$,
  'DUPLICATE');
SELECT pg_temp.expect_eq('11c no second tick stored (2 ticks total)',
  $q$ SELECT pg_temp.ticks('TSTDUP') $q$, '2');
SELECT pg_temp.expect_eq('11d no second alert (1 event total)',
  $q$ SELECT pg_temp.events('dup') $q$, '1');

-- =====================================================================
-- 12. Same observed_at, different source events
-- =====================================================================
SELECT pg_temp.tick('TSTSAME', 0, 2990, 's1');
SELECT pg_temp.expect_eq('12a second event at the SAME observed_at: INSERTED',
  $q$ SELECT pg_temp.tick('TSTSAME', 0, 3010, 's2') $q$, 'INSERTED');
SELECT pg_temp.expect_eq('12b both ticks exist with one shared observed_at',
  $q$ SELECT count(*) || ' ticks, ' || count(DISTINCT observed_at) || ' timestamp'
      FROM price_ticks WHERE source_event_id IN ('test:TSTSAME:s1','test:TSTSAME:s2') $q$,
  '2 ticks, 1 timestamp');
SELECT pg_temp.expect_eq('12c tie broken by tick_id: s1 (2990) is previous of s2 (3010) -> one event on s2',
  $q$ SELECT string_agg(t.source_event_id, ',')
      FROM alert_events e JOIN price_ticks t USING (tick_id)
      WHERE e.rule_id = pg_temp.rid('same') $q$, 'test:TSTSAME:s2');
SELECT pg_temp.tick('TSTSAME', 0, 3020, 's3');
SELECT pg_temp.expect_eq('12d third tick at same time, still above: no extra event',
  $q$ SELECT pg_temp.events('same') $q$, '1');

-- =====================================================================
-- 13. Late tick
-- =====================================================================
SELECT pg_temp.tick('TSTLATE',   0, 2990, '0');
SELECT pg_temp.tick('TSTLATE', 100, 2995, '100');
SELECT pg_temp.expect_eq('13a late tick (t=50 s after t=100 s exists) at 3050: INSERTED (stored)',
  $q$ SELECT pg_temp.tick('TSTLATE', 50, 3050, '50') $q$, 'INSERTED');
SELECT pg_temp.expect_eq('13b late tick is kept: 3 ticks stored',
  $q$ SELECT pg_temp.ticks('TSTLATE') $q$, '3');
SELECT pg_temp.expect_eq('13c late tick above threshold produced NO event',
  $q$ SELECT pg_temp.events('late') $q$, '0');
SELECT pg_temp.tick('TSTLATE', 200, 3010, '200');
SELECT pg_temp.expect_eq('13d next tick 3010 compares with 2995 (t=100 s), not the late 3050: fires',
  $q$ SELECT pg_temp.events('late') $q$, '1');

-- =====================================================================
-- 14. Integrity trigger: rule and tick must share an instrument
-- =====================================================================
SELECT pg_temp.expect_error('14a manual INSERT pairing TSTUP rule with TSTDN tick rejected',
  $q$ INSERT INTO alert_events (rule_id, tick_id)
      SELECT pg_temp.rid('up'), min(t.tick_id)
      FROM price_ticks t JOIN instruments i USING (instrument_id)
      WHERE i.symbol = 'TSTDN' $q$,
  '23514', 'trg_alert_events_check_instrument');
SELECT pg_temp.expect_error('14b UPDATE moving an event onto another instrument''s tick rejected',
  $q$ UPDATE alert_events
      SET tick_id = (SELECT min(t.tick_id) FROM price_ticks t
                     JOIN instruments i USING (instrument_id) WHERE i.symbol = 'TSTDN')
      WHERE rule_id = pg_temp.rid('up') $q$,
  '23514', 'trg_alert_events_check_instrument');
SELECT pg_temp.expect_eq('14c after the rejections, rule up still has its 2 events, both on TSTUP ticks',
  $q$ SELECT count(*) FILTER (WHERE i.symbol = 'TSTUP') || '/' || count(*)
      FROM alert_events e JOIN price_ticks t USING (tick_id) JOIN instruments i USING (instrument_id)
      WHERE e.rule_id = pg_temp.rid('up') $q$, '2/2');

-- =====================================================================
-- 15. Inactive rule
-- =====================================================================
SELECT pg_temp.tick('TSTINACT', 0, 2990, '0');
SELECT pg_temp.tick('TSTINACT', 1, 3010, '1');
SELECT pg_temp.expect_eq('15 crossing with an inactive rule: 2 ticks stored, 0 events',
  $q$ SELECT pg_temp.ticks('TSTINACT') || ' ticks, ' || pg_temp.events('inact') || ' events' $q$,
  '2 ticks, 0 events');

-- =====================================================================
-- 16-17. ingest_tick rejects inactive / unknown instruments
-- =====================================================================
SELECT pg_temp.expect_error('16a ingest_tick on inactive instrument rejected (SW002)',
  $q$ SELECT * FROM ingest_tick('NSE','TSTOFF', pg_temp.ts(0), 100, NULL, 'MANUAL', 'test:TSTOFF:0') $q$,
  'SW002', NULL);
SELECT pg_temp.expect_eq('16b no tick stored for the inactive instrument',
  $q$ SELECT pg_temp.ticks('TSTOFF') $q$, '0');
SELECT pg_temp.expect_error('17a ingest_tick on unknown symbol rejected (SW001)',
  $q$ SELECT * FROM ingest_tick('NSE','NOSUCH', pg_temp.ts(0), 100, NULL, 'MANUAL', 'test:NOSUCH:0') $q$,
  'SW001', NULL);
SELECT pg_temp.expect_error('17b known symbol on the wrong exchange rejected (SW001)',
  $q$ SELECT * FROM ingest_tick('BINANCE','RELIANCE', pg_temp.ts(0), 100, NULL, 'MANUAL', 'test:x:0') $q$,
  'SW001', NULL);

-- =====================================================================
-- 18. Rollback
-- =====================================================================
-- 18a-c: result of the top-level transaction in PART 1
SELECT pg_temp.record('18a top-level: inside the transaction the crossing created 1 event',
  '1', (:rb_events_inside - :rb_events_before)::TEXT);
SELECT pg_temp.record('18b top-level: after ROLLBACK, no tick and no event remain',
  '0 ticks, 0 events',
  (:rb_ticks_after - :rb_ticks_before) || ' ticks, ' || (:rb_events_after - :rb_events_before) || ' events');
SELECT pg_temp.record('18c top-level: after ROLLBACK, the fixture instrument is gone too',
  '0', :rb_instr_after::TEXT);

-- 18d: same idea inside a subtransaction (savepoint rollback)
CREATE FUNCTION pg_temp.savepoint_rollback_probe() RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_inside BIGINT;
BEGIN
    BEGIN
        PERFORM pg_temp.tick('TSTRB', 0, 2990, '0');
        PERFORM pg_temp.tick('TSTRB', 1, 3010, '1');
        v_inside := pg_temp.events('rb');
        RAISE EXCEPTION 'force rollback' USING ERRCODE = 'P0001';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
        NULL;   -- everything since the inner BEGIN is rolled back
    END;
    RETURN 'inside ' || v_inside || ' event; after ' || pg_temp.ticks('TSTRB')
           || ' ticks, ' || pg_temp.events('rb') || ' events';
END $$;
SELECT pg_temp.expect_eq('18d savepoint rollback: tick and alert vanish together',
  $q$ SELECT pg_temp.savepoint_rollback_probe() $q$, 'inside 1 event; after 0 ticks, 0 events');

-- =====================================================================
-- 19. Duplicate alert_event inserted by hand
-- =====================================================================
SELECT pg_temp.expect_error('19 same (rule_id, tick_id) inserted again by hand: UNIQUE rejects it',
  $q$ INSERT INTO alert_events (rule_id, tick_id)
      SELECT rule_id, tick_id FROM alert_events WHERE rule_id = pg_temp.rid('dn') $q$,
  '23505', 'uq_alert_events_rule_tick');

-- =====================================================================
-- 20. One tick fires several rules
-- =====================================================================
SELECT pg_temp.tick('TSTMULTI', 0, 2990, '0');
SELECT pg_temp.tick('TSTMULTI', 1, 3100, '1');
SELECT pg_temp.expect_eq('20a tick 2990 -> 3100 fires exactly m1 (>=3000), m2 (>=3050), m3 (other user >=3000)',
  $q$ SELECT string_agg(tr.name, ',' ORDER BY tr.name)
      FROM alert_events e
      JOIN test_rules tr ON tr.rule_id = e.rule_id
      JOIN price_ticks t ON t.tick_id = e.tick_id
      WHERE t.source_event_id = 'test:TSTMULTI:1' $q$, 'm1,m2,m3');
SELECT pg_temp.expect_eq('20b BELOW 2900 (m4) and ABOVE 3200 (m5) did not fire',
  $q$ SELECT pg_temp.events('m4') + pg_temp.events('m5') $q$, '0');

-- =====================================================================
-- Global consistency checks over everything created above
-- =====================================================================
SELECT pg_temp.expect_eq('21 every event pairs a rule and tick of the same instrument',
  $q$ SELECT count(*) FROM alert_events e
      JOIN alert_rules r USING (rule_id) JOIN price_ticks t USING (tick_id)
      WHERE r.instrument_id <> t.instrument_id $q$, '0');
-- up 2 + dn 1 + eqa 1 + eqb 1 + cool 3 + dup 1 + same 1 + late 1 + m1..m3 3 = 14
SELECT pg_temp.expect_eq('22 total events created by this test run (no extras anywhere)',
  $q$ SELECT count(*) FROM alert_events e JOIN test_rules tr USING (rule_id) $q$, '14');

-- =====================================================================
-- Results
-- =====================================================================
\o
\echo
\echo '===== PHASE 4 ALERT TEST RESULTS ====='
SELECT test_no AS "#", result, test_name, expected, actual
FROM test_results ORDER BY test_no;

SELECT count(*) FILTER (WHERE result = 'PASS') AS passed,
       count(*) FILTER (WHERE result = 'FAIL') AS failed,
       count(*) AS total
FROM test_results;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM test_results WHERE result = 'FAIL') THEN
        RAISE EXCEPTION 'ALERT TESTS FAILED';
    END IF;
END $$;

ROLLBACK;
\echo 'All changes rolled back; seed data unchanged.'
