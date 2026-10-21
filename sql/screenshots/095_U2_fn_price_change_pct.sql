\echo '========================================================================'
\echo ' U2 | User-defined function reporting.fn_price_change_pct(instrument_id)'
\echo '      % change from the first tick to the latest tick'
\echo '========================================================================'
\sf reporting.fn_price_change_pct
SELECT symbol, reporting.fn_price_change_pct(instrument_id) AS change_pct
FROM instruments
ORDER BY change_pct DESC NULLS LAST;
