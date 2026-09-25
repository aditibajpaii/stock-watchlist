-- =====================================================================
-- 07_benchmark_queries.sql
-- Manual, screenshot-friendly BEFORE/AFTER comparison of the Phase 6
-- index on the THROWAWAY benchmark database.
--
-- Prerequisite: python tests/benchmark_indexes.py
--   (builds stock_watchlist_benchmark with 500,000 ticks and leaves the
--    production index ix_price_ticks_instrument_time installed)
-- Run:  psql -d stock_watchlist_benchmark -f sql/07_benchmark_queries.sql
--
-- "WITHOUT" sections run inside a transaction that DROPs the index and is
-- then ROLLED BACK (DDL is transactional in PostgreSQL), so nothing is
-- permanently changed. NEVER run this against stock_watchlist.
--
-- Query shapes are the same as QUERIES in tests/benchmark_indexes.py.
-- Timings vary between runs; the automated script reports medians.
-- =====================================================================

\pset footer off
\set ON_ERROR_STOP on

SELECT current_database() = 'stock_watchlist_benchmark' AS is_benchmark_db \gset
\if :is_benchmark_db
\else
  \echo 'Refusing to run: connect to stock_watchlist_benchmark, not ' :DBNAME
  \quit
\endif

\echo '================ DATA ================'
SELECT count(*) AS price_ticks_rows,
       count(DISTINCT instrument_id) AS instruments,
       pg_size_pretty(pg_relation_size('price_ticks')) AS table_size,
       pg_size_pretty(pg_total_relation_size('price_ticks')) AS table_plus_indexes
FROM price_ticks;

-- parameters taken from the data (RELIANCE, middle of its history)
SELECT instrument_id AS iid FROM instruments WHERE exchange = 'NSE' AND symbol = 'RELIANCE' \gset
SELECT min(observed_at) + (max(observed_at) - min(observed_at)) / 2 AS range_from,
       min(observed_at) + (max(observed_at) - min(observed_at)) / 2 + interval '30 minutes' AS range_to,
       max(observed_at) AS latest_obs,
       count(*) AS n
FROM price_ticks WHERE instrument_id = :iid \gset
SELECT observed_at AS c_obs, tick_id AS c_tid
FROM price_ticks WHERE instrument_id = :iid
ORDER BY observed_at, tick_id OFFSET (:n / 2) LIMIT 1 \gset

\echo
\echo '================ INDEXES ON price_ticks ================'
SELECT indexrelid::regclass AS index_name,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size,
       pg_get_indexdef(indexrelid) AS definition
FROM pg_index WHERE indrelid = 'price_ticks'::regclass ORDER BY 1;

-- ---------------------------------------------------------------------
\echo
\echo '################ WITHOUT ix_price_ticks_instrument_time ################'
BEGIN;
DROP INDEX ix_price_ticks_instrument_time;

\echo '---- A. latest 50 ticks for one instrument'
EXPLAIN (ANALYZE, BUFFERS)
SELECT tick_id, observed_at, price, volume FROM price_ticks
WHERE instrument_id = :iid ORDER BY observed_at DESC, tick_id DESC LIMIT 50;

\echo '---- B. 30-minute history for one instrument'
EXPLAIN (ANALYZE, BUFFERS)
SELECT tick_id, observed_at, price, volume FROM price_ticks
WHERE instrument_id = :iid AND observed_at >= :'range_from' AND observed_at < :'range_to'
ORDER BY observed_at, tick_id;

\echo '---- C. previous-tick lookup (alert trigger)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT t.price FROM price_ticks t
WHERE t.instrument_id = :iid AND (t.observed_at, t.tick_id) < (:'c_obs'::timestamptz, :c_tid)
ORDER BY t.observed_at DESC, t.tick_id DESC LIMIT 1;

\echo '---- E. late-tick check (alert trigger), new tick is the latest'
EXPLAIN (ANALYZE, BUFFERS)
SELECT EXISTS (SELECT 1 FROM price_ticks t
               WHERE t.instrument_id = :iid AND t.observed_at > :'latest_obs'::timestamptz);
ROLLBACK;

-- ---------------------------------------------------------------------
\echo
\echo '################ WITH ix_price_ticks_instrument_time ################'

\echo '---- A. latest 50 ticks for one instrument'
EXPLAIN (ANALYZE, BUFFERS)
SELECT tick_id, observed_at, price, volume FROM price_ticks
WHERE instrument_id = :iid ORDER BY observed_at DESC, tick_id DESC LIMIT 50;

\echo '---- B. 30-minute history for one instrument'
EXPLAIN (ANALYZE, BUFFERS)
SELECT tick_id, observed_at, price, volume FROM price_ticks
WHERE instrument_id = :iid AND observed_at >= :'range_from' AND observed_at < :'range_to'
ORDER BY observed_at, tick_id;

\echo '---- C. previous-tick lookup (alert trigger)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT t.price FROM price_ticks t
WHERE t.instrument_id = :iid AND (t.observed_at, t.tick_id) < (:'c_obs'::timestamptz, :c_tid)
ORDER BY t.observed_at DESC, t.tick_id DESC LIMIT 1;

\echo '---- E. late-tick check (alert trigger), new tick is the latest'
EXPLAIN (ANALYZE, BUFFERS)
SELECT EXISTS (SELECT 1 FROM price_ticks t
               WHERE t.instrument_id = :iid AND t.observed_at > :'latest_obs'::timestamptz);
