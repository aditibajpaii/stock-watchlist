\echo '========================================================================'
\echo ' IX2 | EXPLAIN ANALYZE WITHOUT ix_price_ticks_instrument_time (500,000 rows)'
\echo '       query: latest 50 RELIANCE ticks. Index dropped inside a transaction,'
\echo '       then ROLLBACK restores it (DDL is transactional in PostgreSQL)'
\echo '========================================================================'
SELECT current_database(), count(*) AS price_ticks_rows,
       pg_size_pretty(pg_total_relation_size('price_ticks')) AS table_plus_indexes
FROM price_ticks;
SELECT instrument_id AS iid FROM instruments WHERE exchange = 'NSE' AND symbol = 'RELIANCE' \gset
BEGIN;
DROP INDEX ix_price_ticks_instrument_time;

EXPLAIN (ANALYZE, BUFFERS)
SELECT tick_id, observed_at, price, volume FROM price_ticks
WHERE instrument_id = :iid
ORDER BY observed_at DESC, tick_id DESC
LIMIT 50;
ROLLBACK;
