\echo '========================================================================'
\echo ' D2 | Subquery: single-row (compared with =)'
\echo '      Q: Which other instruments use the same currency as BTCUSDT?'
\echo '         At what moment was BTCUSDT at its highest price?'
\echo '========================================================================'
SELECT symbol, name, quote_currency
FROM instruments
WHERE quote_currency = (SELECT quote_currency FROM instruments WHERE symbol = 'BTCUSDT')
  AND symbol <> 'BTCUSDT';

SELECT tick_id, price::numeric(12,2) AS price, observed_at
FROM price_ticks
WHERE instrument_id = 6
  AND price = (SELECT max(price) FROM price_ticks WHERE instrument_id = 6);
