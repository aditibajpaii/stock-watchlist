\echo '========================================================================'
\echo ' E3 | Set operation: INTERSECT'
\echo '      Q: Which (user, instrument) pairs are BOTH watched AND have an alert rule?'
\echo '========================================================================'
SELECT w.user_id, wi.instrument_id
FROM watchlists w JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
INTERSECT
SELECT user_id, instrument_id FROM alert_rules
ORDER BY user_id, instrument_id;
