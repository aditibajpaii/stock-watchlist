\echo '========================================================================'
\echo ' CR4 | SQL-level SCROLL cursor: DECLARE, FETCH FIRST / FORWARD / LAST / ABSOLUTE, CLOSE'
\echo '       walks BTCUSDT ticks without loading them all at once'
\echo '========================================================================'
BEGIN;
DECLARE c_btc SCROLL CURSOR FOR
    SELECT tick_id, observed_at::time(0) AS time, price::numeric(12,2) AS price
    FROM price_ticks WHERE instrument_id = 6 ORDER BY observed_at, tick_id;
FETCH FIRST FROM c_btc;
FETCH FORWARD 2 FROM c_btc;
FETCH LAST FROM c_btc;
FETCH ABSOLUTE 4 FROM c_btc;
CLOSE c_btc;
COMMIT;
