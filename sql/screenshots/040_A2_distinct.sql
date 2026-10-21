\echo '========================================================================'
\echo ' A2 | Basic: DISTINCT'
\echo '      Q: Which exchange / currency combinations and which data sources exist?'
\echo '========================================================================'
SELECT DISTINCT exchange, quote_currency
FROM instruments
ORDER BY exchange, quote_currency;

SELECT DISTINCT source FROM price_ticks ORDER BY source;
