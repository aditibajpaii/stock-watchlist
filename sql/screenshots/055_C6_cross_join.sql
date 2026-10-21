SELECT u.username, i.symbol
FROM users u
CROSS JOIN instruments i
ORDER BY u.username, i.symbol;
