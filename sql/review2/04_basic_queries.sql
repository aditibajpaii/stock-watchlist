-- =====================================================================
-- 04_basic_queries.sql  -  Template category A (Basic), minimum 6
-- Coverage: SELECT, WHERE, ORDER BY, DISTINCT, BETWEEN, IN, LIKE, IS NULL
-- Read-only. Data: seed + replay run r2demo in the sandbox.
-- =====================================================================
\ir _guard.sql

\echo '=== B01 | SELECT, WHERE, ORDER BY | Which NSE instruments are active, in symbol order?'
SELECT exchange, symbol, name, quote_currency
FROM instruments
WHERE exchange = 'NSE' AND is_active
ORDER BY symbol;

\echo '=== B02 | SELECT, DISTINCT, ORDER BY | Which exchange and quote-currency combinations are listed?'
SELECT DISTINCT exchange, quote_currency
FROM instruments
ORDER BY exchange;

\echo '=== B03 | SELECT, WHERE, BETWEEN, ORDER BY | Which RELIANCE ticks traded between 3000 and 3020 (inclusive)?'
SELECT tick_id, price, volume, source_event_id
FROM price_ticks
WHERE instrument_id = 1                 -- NSE RELIANCE (instrument_id from the seed)
  AND price BETWEEN 3000 AND 3020
ORDER BY observed_at, tick_id;

\echo '=== B04 | SELECT, WHERE, IN, ORDER BY | Show the IT stocks TCS and INFY and the bank HDFCBANK'
SELECT symbol, name, exchange
FROM instruments
WHERE exchange = 'NSE'
  AND symbol IN ('TCS', 'INFY', 'HDFCBANK')
ORDER BY symbol;

\echo '=== B05 | SELECT, WHERE, LIKE, ORDER BY | Which instruments are quoted against Tether (symbol ends in USDT)?'
SELECT exchange, symbol, name, quote_currency
FROM instruments
WHERE symbol LIKE '%USDT'
ORDER BY symbol;

\echo '=== B06 | SELECT, WHERE, IS NULL, ORDER BY | Which ticks arrived with an unknown volume (NULL, not zero)?'
SELECT tick_id, instrument_id, price, volume, source_event_id
FROM price_ticks
WHERE volume IS NULL
ORDER BY tick_id;

\echo '=== B07 | SELECT, ORDER BY | What are the five most recent ticks by market time?'
SELECT tick_id, instrument_id, price, observed_at
FROM price_ticks
ORDER BY observed_at DESC, tick_id DESC
LIMIT 5;
