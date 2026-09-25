-- =====================================================================
-- 03_functions_triggers.sql
-- Phase 4: ingestion function + alert engine (database logic only).
--
--   ingest_tick(...)                      official ingestion path
--   evaluate_price_alerts()               trigger fn: edge-triggered alerts
--     trg_price_ticks_evaluate_alerts     AFTER INSERT ON price_ticks
--   check_alert_event_instrument()        trigger fn: integrity check
--     trg_alert_events_check_instrument   BEFORE INSERT/UPDATE ON alert_events
--
-- Prerequisite: 00_schema.sql
-- Run:  psql -d stock_watchlist -v ON_ERROR_STOP=1 -f sql/03_functions_triggers.sql
-- Re-runnable: CREATE OR REPLACE for functions and triggers. No data is
-- touched.
--
-- Custom SQLSTATEs raised by ingest_tick (class "SW" = stock watchlist):
--   SW001  unknown instrument (no row for exchange + symbol)
--   SW002  instrument exists but is_active = false
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 1. Integrity: an alert event must pair a rule and a tick of the SAME
--    instrument. alert_events stores no instrument_id (it stays
--    normalized), so this cannot be a FK or CHECK; a trigger reads both
--    parents instead.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION check_alert_event_instrument()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_rule_instrument BIGINT;
    v_tick_instrument BIGINT;
BEGIN
    SELECT r.instrument_id INTO v_rule_instrument
    FROM alert_rules r WHERE r.rule_id = NEW.rule_id;

    SELECT t.instrument_id INTO v_tick_instrument
    FROM price_ticks t WHERE t.tick_id = NEW.tick_id;

    -- A missing rule or tick is left to the foreign keys to report.
    IF v_rule_instrument IS NOT NULL
       AND v_tick_instrument IS NOT NULL
       AND v_rule_instrument <> v_tick_instrument THEN
        RAISE EXCEPTION
            'alert_events: rule % is for instrument %, but tick % is for instrument %',
            NEW.rule_id, v_rule_instrument, NEW.tick_id, v_tick_instrument
        USING ERRCODE    = 'check_violation',
              CONSTRAINT = 'trg_alert_events_check_instrument',
              HINT       = 'An alert event must pair a rule and a price tick of the same instrument.';
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER trg_alert_events_check_instrument
    BEFORE INSERT OR UPDATE OF rule_id, tick_id ON alert_events
    FOR EACH ROW
    EXECUTE FUNCTION check_alert_event_instrument();

-- ---------------------------------------------------------------------
-- 2. Alert engine: evaluate every active rule of the tick's instrument.
--    Runs AFTER INSERT on price_ticks, inside the inserting transaction.
--    Edge-triggered: fires only when the price moves from one side of
--    the threshold to the other between the previous tick and this one.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION evaluate_price_alerts()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev_price     NUMERIC;
    v_rule           RECORD;
    v_last_fired_obs TIMESTAMPTZ;
    v_event_id       BIGINT;
BEGIN
    -- A. Late tick: a tick of this instrument with a later market time
    --    already exists. Keep NEW as history, but evaluate nothing.
    IF EXISTS (SELECT 1 FROM price_ticks t
               WHERE t.instrument_id = NEW.instrument_id
                 AND t.observed_at > NEW.observed_at) THEN
        RETURN NULL;
    END IF;

    -- B. Previous tick = greatest (observed_at, tick_id) below NEW's.
    SELECT t.price INTO v_prev_price
    FROM price_ticks t
    WHERE t.instrument_id = NEW.instrument_id
      AND (t.observed_at, t.tick_id) < (NEW.observed_at, NEW.tick_id)
    ORDER BY t.observed_at DESC, t.tick_id DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN NULL;   -- first tick: no previous price, so no crossing
    END IF;

    -- C. Active rules of this instrument only.
    FOR v_rule IN
        SELECT r.rule_id, r.direction, r.threshold, r.cooldown_seconds
        FROM alert_rules r
        WHERE r.instrument_id = NEW.instrument_id
          AND r.is_active
        ORDER BY r.rule_id
    LOOP
        IF NOT (   (v_rule.direction = 'ABOVE'
                    AND v_prev_price <  v_rule.threshold
                    AND NEW.price    >= v_rule.threshold)
                OR (v_rule.direction = 'BELOW'
                    AND v_prev_price >  v_rule.threshold
                    AND NEW.price    <= v_rule.threshold)) THEN
            CONTINUE;
        END IF;

        -- D. Cooldown in market time: observed_at of the tick behind
        --    this rule's most recent event (not fired_at).
        SELECT t.observed_at INTO v_last_fired_obs
        FROM alert_events e
        JOIN price_ticks t ON t.tick_id = e.tick_id
        WHERE e.rule_id = v_rule.rule_id
        ORDER BY t.observed_at DESC, t.tick_id DESC
        LIMIT 1;

        IF v_last_fired_obs IS NOT NULL
           AND NEW.observed_at < v_last_fired_obs
                                 + make_interval(secs => v_rule.cooldown_seconds) THEN
            CONTINUE;  -- suppressed; dropped, not retried later
        END IF;

        -- E. Record the event; UNIQUE (rule_id, tick_id) is the last guard.
        INSERT INTO alert_events (rule_id, tick_id)
        VALUES (v_rule.rule_id, NEW.tick_id)
        ON CONFLICT ON CONSTRAINT uq_alert_events_rule_tick DO NOTHING
        RETURNING event_id INTO v_event_id;

        -- F. Wake-up signal only; delivered on COMMIT, discarded on ROLLBACK.
        IF FOUND THEN
            PERFORM pg_notify('alert_events', v_event_id::TEXT);
        END IF;
    END LOOP;

    RETURN NULL;   -- AFTER trigger: return value is ignored
END;
$$;

CREATE OR REPLACE TRIGGER trg_price_ticks_evaluate_alerts
    AFTER INSERT ON price_ticks
    FOR EACH ROW
    EXECUTE FUNCTION evaluate_price_alerts();

-- ---------------------------------------------------------------------
-- 3. ingest_tick: the ONE operational way to insert a price tick
--    (replay, Binance and manual demo all call this).
--
--    Returns one row (status, tick_id):
--      ('INSERTED', <new tick_id>)   tick stored, alerts evaluated
--      ('DUPLICATE', NULL)           same (source, instrument, event id)
--                                    already stored; nothing changed
--
--    The instrument row is locked BEFORE the insert, so ticks for the
--    same instrument are processed one transaction at a time; the lock
--    is held until the caller's transaction ends. Different instruments
--    do not block each other. Designed for READ COMMITTED.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ingest_tick(
    p_exchange        TEXT,
    p_symbol          TEXT,
    p_observed_at     TIMESTAMPTZ,
    p_price           NUMERIC,
    p_volume          NUMERIC,
    p_source          TEXT,
    p_source_event_id TEXT
)
RETURNS TABLE (status TEXT, tick_id BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_instrument_id BIGINT;
    v_is_active     BOOLEAN;
    v_tick_id       BIGINT;
BEGIN
    -- 1-4. Find the instrument and lock it before inserting.
    SELECT i.instrument_id, i.is_active
    INTO v_instrument_id, v_is_active
    FROM instruments i
    WHERE i.exchange = p_exchange
      AND i.symbol   = p_symbol
    FOR NO KEY UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'ingest_tick: unknown instrument %:%', p_exchange, p_symbol
        USING ERRCODE = 'SW001';
    END IF;

    IF NOT v_is_active THEN
        RAISE EXCEPTION 'ingest_tick: instrument %:% is inactive', p_exchange, p_symbol
        USING ERRCODE = 'SW002';
    END IF;

    -- 5. Insert exactly one tick; a repeated source event inserts nothing.
    --    The AFTER INSERT alert trigger runs inside this statement.
    INSERT INTO price_ticks AS pt
        (instrument_id, observed_at, price, volume, source, source_event_id)
    VALUES
        (v_instrument_id, p_observed_at, p_price, p_volume, p_source, p_source_event_id)
    ON CONFLICT ON CONSTRAINT uq_price_ticks_source_event DO NOTHING
    RETURNING pt.tick_id INTO v_tick_id;

    -- 6-7. Report the outcome.
    IF v_tick_id IS NULL THEN
        status  := 'DUPLICATE';
        tick_id := NULL;
    ELSE
        status  := 'INSERTED';
        tick_id := v_tick_id;
    END IF;
    RETURN NEXT;
END;
$$;

COMMIT;
