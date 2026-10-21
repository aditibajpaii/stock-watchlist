\echo '========================================================================'
\echo ' F2 | Function: COALESCE (first non-NULL value)'
\echo '      Q: Latest price per instrument, with a readable text when there is none'
\echo '========================================================================'
SELECT i.symbol,
       COALESCE(lp.price::numeric(12,2)::text, 'no price data yet') AS latest_price,
       COALESCE(lp.volume::text, 'unknown')                         AS latest_volume
FROM instruments i
LEFT JOIN LATERAL (
    SELECT t.price, t.volume FROM price_ticks t
    WHERE t.instrument_id = i.instrument_id
    ORDER BY t.observed_at DESC, t.tick_id DESC
    LIMIT 1) lp ON true
ORDER BY i.symbol;
