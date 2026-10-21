-- =====================================================================
-- integrity_parent_update_fix.sql  -  PROPOSED, NOT APPLIED
--
-- Closes the gap shown in sql/review2/22_integrity_scope.sql:
-- trg_alert_events_check_instrument checks "an alert event's rule and
-- tick are for the same instrument" only when alert_events rows are
-- written. A later UPDATE of instrument_id on the PARENT rows
-- (alert_rules, price_ticks) is accepted today and can break the rule
-- for existing events.
--
-- Proposed fix: instrument_id becomes immutable on both parent tables.
--   forbid_instrument_change()              trigger function
--     trg_alert_rules_instrument_immutable  BEFORE UPDATE OF instrument_id ON alert_rules
--     trg_price_ticks_instrument_immutable  BEFORE UPDATE OF instrument_id ON price_ticks
--
-- Why immutability, and not "only while alert events exist": the check
-- needs no other row, so two concurrent transactions cannot slip past it
-- (an "only if no events" check would race with the alert trigger under
-- READ COMMITTED). It also matches the documented design: a rule's
-- definition (user, instrument, direction, threshold) is immutable and
-- the API never changes it; a tick is a historical fact.
--
-- Rejected:  UPDATE alert_rules SET instrument_id = <different value> ...
--            UPDATE price_ticks SET instrument_id = <different value> ...
--            (SQLSTATE 23514 check_violation, for every role, superuser included)
-- Allowed:   every other UPDATE (is_active, cooldown_seconds, price, ...),
--            an UPDATE that sets instrument_id to its current value,
--            all INSERTs and DELETEs (ON DELETE CASCADE / RESTRICT unchanged).
--
-- Status: NOT applied to stock_watchlist, stock_watchlist_benchmark or the
-- Review 2 sandbox. Tested only in a throwaway database by
-- scripts/review2_integrity_fix_test.sh. If the team approves it, apply it with
--   psql -d stock_watchlist -v ON_ERROR_STOP=1 -v confirm_apply=yes -f <this file>
-- and update sql/verify_spec.sql and docs/SCHEMA_DESIGN.md (they list the
-- functions and triggers). Undo: integrity_parent_update_fix_rollback.sql.
-- =====================================================================
\set ON_ERROR_STOP on
\set confirmed false
\if :{?confirm_apply}
  SELECT :'confirm_apply' = 'yes' AS confirmed \gset
\endif
SELECT :'confirmed'::boolean
       OR current_database() NOT IN ('stock_watchlist', 'stock_watchlist_benchmark',
                                     'stock_watchlist_review2_sandbox') AS fix_target_ok \gset
\if :fix_target_ok
\else
  \echo 'REFUSING: proposed fix, not approved. Database:' :DBNAME
  DO $$ BEGIN RAISE EXCEPTION 'proposed integrity fix: pass -v confirm_apply=yes only after approval'; END $$;
\endif

BEGIN;

CREATE OR REPLACE FUNCTION forbid_instrument_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.instrument_id IS DISTINCT FROM OLD.instrument_id THEN
        RAISE EXCEPTION '%: instrument_id cannot be changed (row %, % -> %)',
            TG_TABLE_NAME,
            to_jsonb(OLD) ->> CASE TG_TABLE_NAME WHEN 'alert_rules' THEN 'rule_id'
                                                 ELSE 'tick_id' END,
            OLD.instrument_id, NEW.instrument_id
        USING ERRCODE    = 'check_violation',
              CONSTRAINT = TG_NAME,
              HINT       = 'An alert event''s rule and tick must stay on the same instrument. '
                           'Create a new rule (or ingest a new tick) instead.';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER trg_alert_rules_instrument_immutable
    BEFORE UPDATE OF instrument_id ON alert_rules
    FOR EACH ROW
    EXECUTE FUNCTION forbid_instrument_change();

CREATE OR REPLACE TRIGGER trg_price_ticks_instrument_immutable
    BEFORE UPDATE OF instrument_id ON price_ticks
    FOR EACH ROW
    EXECUTE FUNCTION forbid_instrument_change();

COMMIT;
