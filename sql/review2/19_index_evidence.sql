-- =====================================================================
-- 19_index_evidence.sql  -  Review 2 checklist item 8: indexes + EXPLAIN
--
-- On this 30-row sandbox the planner is free to prefer a sequential scan
-- (reading 1 page is cheaper than using an index), so the sandbox shows
-- only WHAT the index is and that it CAN serve the alert-trigger query.
-- The real before/after comparison is the 500,000-row benchmark:
--   docs/INDEX_BENCHMARK.md, docs/benchmark_results/ (raw, 2026-09-25)
--   psql -d stock_watchlist_benchmark -f sql/07_benchmark_queries.sql
--   (bash scripts/review2_sandbox.sh --index-explain saves a fresh run to
--    docs/review2/sql_output/91_index_explain_benchmark.out)
-- Read-only.
-- =====================================================================
\ir _guard.sql

\echo '===== Table description, including its indexes ====='
\d price_ticks

\echo '===== Every index on price_ticks: who created it, definition, size ====='
SELECT i.indexrelid::regclass AS index_name,
       CASE WHEN c.conname IS NOT NULL THEN 'created by constraint ' || c.conname
            ELSE 'created explicitly (sql/06_indexes.sql)' END AS origin,
       pg_get_indexdef(i.indexrelid) AS definition,
       pg_size_pretty(pg_relation_size(i.indexrelid)) AS size_here
FROM pg_index i
LEFT JOIN pg_constraint c ON c.conindid = i.indexrelid
WHERE i.indrelid = 'price_ticks'::regclass
ORDER BY 1;

\echo '===== The alert trigger previous-tick lookup, as the planner chooses on 30 rows ====='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT t.price
FROM price_ticks t
WHERE t.instrument_id = 1
  AND (t.observed_at, t.tick_id) < (SELECT observed_at, tick_id FROM price_ticks WHERE tick_id = 30)
ORDER BY t.observed_at DESC, t.tick_id DESC
LIMIT 1;

\echo '===== Same query with sequential scans discouraged (DEMONSTRATION ONLY, not a performance claim) ====='
\echo 'shows that ix_price_ticks_instrument_time can answer it in index order, with no Sort node'
BEGIN;
SET LOCAL enable_seqscan = off;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT t.price
FROM price_ticks t
WHERE t.instrument_id = 1
  AND (t.observed_at, t.tick_id) < (SELECT observed_at, tick_id FROM price_ticks WHERE tick_id = 30)
ORDER BY t.observed_at DESC, t.tick_id DESC
LIMIT 1;
ROLLBACK;
