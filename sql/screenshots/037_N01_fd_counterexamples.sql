BEGIN;
INSERT INTO instruments (exchange, symbol, name, quote_currency) VALUES
  ('BSE', 'RELIANCE', 'Reliance Industries Ltd', 'INR'),
  ('BINANCE', 'ETHBTC', 'Ether / Bitcoin', 'BTC');

SELECT exchange, symbol, quote_currency FROM instruments ORDER BY exchange, symbol;

SELECT exchange, count(DISTINCT quote_currency) FROM instruments GROUP BY exchange;
ROLLBACK;
