SELECT upper(username), length(email), split_part(email, '@', 2) AS domain,
       username || ' <' || email || '>' AS contact
FROM users;

SELECT concat(exchange, ':', symbol) AS ticker, lower(symbol), replace(name, ' Ltd', '') AS short_name,
       substring(name, 1, 10) AS first_10
FROM instruments;
