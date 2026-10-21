\echo '========================================================================'
\echo ' C4 | Join: FULL OUTER JOIN'
\echo '      Q: Per user, which instruments are watched, which have rules, which both?'
\echo '         (a rule on an unwatched instrument appears only from the right side)'
\echo '========================================================================'
WITH watched AS (
    SELECT DISTINCT w.user_id, wi.instrument_id
    FROM watchlists w JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id),
ruled AS (
    SELECT DISTINCT user_id, instrument_id FROM alert_rules)
SELECT u.username, i.symbol,
       (w.instrument_id IS NOT NULL) AS in_watchlist,
       (r.instrument_id IS NOT NULL) AS has_rule
FROM watched w
FULL OUTER JOIN ruled r ON r.user_id = w.user_id AND r.instrument_id = w.instrument_id
JOIN users u       ON u.user_id = coalesce(w.user_id, r.user_id)
JOIN instruments i ON i.instrument_id = coalesce(w.instrument_id, r.instrument_id)
ORDER BY u.username, i.symbol;
