\echo '========================================================================'
\echo ' CN04 | ON DELETE RESTRICT: shared market data cannot be deleted'
\echo '        while watchlists, rules or alert history still reference it'
\echo '========================================================================'
DELETE FROM instruments WHERE exchange = 'NSE' AND symbol = 'RELIANCE';

DELETE FROM price_ticks
WHERE tick_id = (SELECT e.tick_id FROM alert_events e ORDER BY e.event_id LIMIT 1);

SELECT (SELECT count(*) FROM instruments) AS instruments,
       (SELECT count(*) FROM price_ticks) AS price_ticks;
