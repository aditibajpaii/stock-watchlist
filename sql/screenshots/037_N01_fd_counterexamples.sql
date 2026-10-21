\echo '========================================================================'
\echo ' N01 | Normalization: the rejected functional dependencies are false'
\echo '       symbol is NOT a key; exchange does NOT determine quote_currency'
\echo '       (inside a transaction that is rolled back)'
\echo '========================================================================'
BEGIN;
INSERT INTO instruments (exchange, symbol, name, quote_currency) VALUES
  ('BSE', 'RELIANCE', 'Reliance Industries Ltd', 'INR'),
  ('BINANCE', 'ETHBTC', 'Ether / Bitcoin', 'BTC');

SELECT exchange, symbol, quote_currency FROM instruments
WHERE symbol IN ('RELIANCE', 'BTCUSDT', 'ETHUSDT', 'ETHBTC')
ORDER BY exchange, symbol;

SELECT exchange, count(DISTINCT quote_currency) AS currencies
FROM instruments GROUP BY exchange ORDER BY exchange;
ROLLBACK;
