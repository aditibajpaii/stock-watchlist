\echo '========================================================================'
\echo ' A1 | Basic: SELECT, WHERE, ORDER BY'
\echo '      Q: Which active NSE instruments do we track, alphabetically?'
\echo '========================================================================'
SELECT exchange, symbol, name, quote_currency
FROM instruments
WHERE exchange = 'NSE' AND is_active = true
ORDER BY symbol;
