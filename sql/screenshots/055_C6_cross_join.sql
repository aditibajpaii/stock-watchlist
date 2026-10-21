\echo '========================================================================'
\echo ' C6 | Join: CROSS JOIN (every user x every instrument = 3 x 7 = 21 rows)'
\echo '      Q: Rule-coverage matrix: how many rules does each user have per instrument?'
\echo '========================================================================'
SELECT u.username, i.symbol,
       (SELECT count(*) FROM alert_rules r
         WHERE r.user_id = u.user_id AND r.instrument_id = i.instrument_id) AS rules
FROM users u
CROSS JOIN instruments i
ORDER BY u.username, i.symbol;
