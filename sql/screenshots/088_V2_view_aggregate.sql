\echo '========================================================================'
\echo ' V2 | Aggregated view: reporting.v_instrument_price_summary'
\echo '      Purpose: per-instrument statistics without repeating GROUP BY logic'
\echo '========================================================================'
\sv reporting.v_instrument_price_summary
SELECT symbol, tick_count, min_price::numeric(12,2) AS min, max_price::numeric(12,2) AS max,
       avg_price, last_tick_at::time(0) AS last_tick
FROM reporting.v_instrument_price_summary
ORDER BY tick_count DESC, symbol;
