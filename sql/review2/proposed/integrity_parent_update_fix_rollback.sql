-- =====================================================================
-- integrity_parent_update_fix_rollback.sql  -  undo the proposed fix
-- Removes exactly the three objects created by
-- integrity_parent_update_fix.sql. No data is touched.
-- =====================================================================
\set ON_ERROR_STOP on
BEGIN;
DROP TRIGGER IF EXISTS trg_alert_rules_instrument_immutable ON alert_rules;
DROP TRIGGER IF EXISTS trg_price_ticks_instrument_immutable ON price_ticks;
DROP FUNCTION IF EXISTS forbid_instrument_change();
COMMIT;
