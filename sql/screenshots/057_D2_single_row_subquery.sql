SELECT symbol, name, quote_currency
FROM instruments
WHERE quote_currency = (SELECT quote_currency FROM instruments WHERE symbol = 'BTCUSDT');

SELECT tick_id, price, observed_at
FROM price_ticks
WHERE price = (SELECT max(price) FROM price_ticks WHERE instrument_id = 6);
