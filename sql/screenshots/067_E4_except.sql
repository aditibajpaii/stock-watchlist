\echo '========================================================================'
\echo ' E4 | Set operation: EXCEPT (PostgreSQL''s MINUS)'
\echo '      Q: Which (user, instrument) pairs are watched but have NO alert rule?'
\echo '========================================================================'
SELECT u.username, i.symbol
FROM (
    SELECT w.user_id, wi.instrument_id
    FROM watchlists w JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
    EXCEPT
    SELECT user_id, instrument_id FROM alert_rules
) AS gap
JOIN users u       ON u.user_id = gap.user_id
JOIN instruments i ON i.instrument_id = gap.instrument_id
ORDER BY u.username, i.symbol;
