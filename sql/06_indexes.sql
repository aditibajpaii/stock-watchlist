-- =====================================================================
-- 06_indexes.sql
-- Phase 6: performance index for price history.
--
-- Kept separate from 00_schema.sql on purpose: 00 defines the logical
-- design (tables, keys, constraints); this file adds a physical access
-- path chosen from benchmark evidence (docs/INDEX_BENCHMARK.md).
--
-- Prerequisite: 00_schema.sql
-- Run:  psql -d stock_watchlist -v ON_ERROR_STOP=1 -f sql/06_indexes.sql
-- Re-runnable (IF NOT EXISTS). No data is changed.
--
-- Serves, for ONE instrument, ordered by (observed_at, tick_id):
--   * latest N ticks                (web UI, "latest price")
--   * time-range history            (charts / history view)
--   * previous-tick lookup          (alert trigger evaluate_price_alerts)
--   * late-tick check               (alert trigger evaluate_price_alerts)
--
-- Why not already covered: the only existing price_ticks indexes are
--   pk_price_ticks (tick_id) and
--   uq_price_ticks_source_event (source, instrument_id, source_event_id);
-- neither starts with instrument_id, so neither can find one instrument's
-- ticks in time order.
-- =====================================================================

BEGIN;

CREATE INDEX IF NOT EXISTS ix_price_ticks_instrument_time
    ON price_ticks (instrument_id, observed_at DESC, tick_id DESC);

COMMIT;
