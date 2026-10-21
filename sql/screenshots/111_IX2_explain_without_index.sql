SELECT count(*) FROM price_ticks;

BEGIN;
DROP INDEX ix_price_ticks_instrument_time;

EXPLAIN ANALYZE
SELECT tick_id, observed_at, price, volume
FROM price_ticks
WHERE instrument_id = 1
ORDER BY observed_at DESC, tick_id DESC
LIMIT 50;
ROLLBACK;
