\echo '========================================================================'
\echo ' U1 | User-defined function reporting.fn_latest_price(instrument_id)'
\echo '========================================================================'
\sf reporting.fn_latest_price
SELECT exchange, symbol, reporting.fn_latest_price(instrument_id)::numeric(12,2) AS latest_price
FROM instruments ORDER BY instrument_id;
