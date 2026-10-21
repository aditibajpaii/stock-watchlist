\echo '========================================================================'
\echo ' E1 | Set operation: UNION (duplicates removed)'
\echo '      Q: Which instruments does arjun care about (watched OR has a rule)?'
\echo '========================================================================'
SELECT i.symbol FROM watchlist_items wi
JOIN watchlists w  ON w.watchlist_id = wi.watchlist_id
JOIN instruments i ON i.instrument_id = wi.instrument_id
WHERE w.user_id = 1
UNION
SELECT i.symbol FROM alert_rules r
JOIN instruments i ON i.instrument_id = r.instrument_id
WHERE r.user_id = 1
ORDER BY symbol;
