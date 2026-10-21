SELECT exchange, symbol, name, quote_currency
FROM instruments
WHERE exchange = 'NSE' AND is_active = true
ORDER BY symbol;
