SELECT symbol, name FROM instruments WHERE name LIKE '% Ltd';

SELECT symbol, name FROM instruments WHERE symbol LIKE '%USDT';

SELECT symbol, name FROM instruments WHERE name ILIKE '%bank%';
