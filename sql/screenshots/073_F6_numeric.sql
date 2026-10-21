\echo '========================================================================'
\echo ' F6 | Function: numeric functions'
\echo '      Q: BTCUSDT trade value, rounding, and distance from the 100,000 rule'
\echo '========================================================================'
SELECT tick_id,
       price::numeric(12,2)              AS price,
       volume,
       round(price * volume, 2)          AS trade_value_usdt,
       ceil(price)                       AS ceil_price,
       floor(price / 1000) * 1000        AS price_floor_1000,
       trunc(price / 1000, 1)            AS price_k,
       abs(price - 100000)::numeric(12,2) AS distance_from_100k,
       sign(price - 100000)              AS side,
       mod(tick_id, 2)                   AS tick_id_parity
FROM price_ticks
WHERE instrument_id = 6
ORDER BY observed_at;
