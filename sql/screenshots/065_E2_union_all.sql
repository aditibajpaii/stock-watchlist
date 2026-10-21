\echo '========================================================================'
\echo ' E2 | Set operation: UNION ALL (duplicates kept)'
\echo '      Q: How many times is each instrument referenced by watchlists + rules?'
\echo '========================================================================'
SELECT symbol, count(*) AS references_total
FROM (
    SELECT i.symbol FROM watchlist_items wi
    JOIN watchlists w  ON w.watchlist_id = wi.watchlist_id
    JOIN instruments i ON i.instrument_id = wi.instrument_id
    UNION ALL
    SELECT i.symbol FROM alert_rules r
    JOIN instruments i ON i.instrument_id = r.instrument_id
) AS refs
GROUP BY symbol
ORDER BY references_total DESC, symbol;
