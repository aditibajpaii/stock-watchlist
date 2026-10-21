\echo '========================================================================'
\echo ' A5 | Basic: LIKE / ILIKE pattern matching'
\echo '      Q: Which instruments are ''Ltd'' companies, USDT pairs, or banks?'
\echo '========================================================================'
SELECT symbol, name FROM instruments WHERE name LIKE '% Ltd' ORDER BY symbol;

SELECT symbol, name FROM instruments WHERE symbol LIKE '%USDT' ORDER BY symbol;

SELECT symbol, name FROM instruments WHERE name ILIKE '%bank%';
