\echo '========================================================================'
\echo ' IX3 | EXPLAIN ANALYZE WITH ix_price_ticks_instrument_time (same query, 500,000 rows)'
\echo '========================================================================'
SELECT current_database(), count(*) AS price_ticks_rows,
       pg_size_pretty(pg_total_relation_size('price_ticks')) AS table_plus_indexes
FROM price_ticks;
SELECT instrument_id AS iid FROM instruments WHERE exchange = 'NSE' AND symbol = 'RELIANCE' \gset

EXPLAIN (ANALYZE, BUFFERS)
SELECT tick_id, observed_at, price, volume FROM price_ticks
WHERE instrument_id = :iid
ORDER BY observed_at DESC, tick_id DESC
LIMIT 50;
