\echo '========================================================================'
\echo ' T3 | Trigger logic: cooldown (300 s, measured in market time)'
\echo '      crossing at +10s fires; re-cross at +30s is inside the cooldown (no alert);'
\echo '      re-cross at +410s is after the cooldown (fires). Rolled back.'
\echo '========================================================================'
BEGIN;
INSERT INTO alert_rules (user_id, instrument_id, direction, threshold, cooldown_seconds)
VALUES (1, 4, 'ABOVE', 1700, 300);

SELECT v.sec, v.price, r.status
FROM (VALUES (0, 1690), (10, 1710), (20, 1690), (30, 1710), (400, 1690), (410, 1710))
     AS v(sec, price)
CROSS JOIN LATERAL ingest_tick('NSE', 'HDFCBANK', now() + v.sec * interval '1 second',
                               v.price, NULL, 'MANUAL', 'ss-t3:' || v.sec) AS r
ORDER BY v.sec;

SELECT e.event_id, t.price::numeric(12,2) AS tick_price,
       extract(epoch FROM t.observed_at - now())::int AS at_second
FROM alert_events e JOIN price_ticks t ON t.tick_id = e.tick_id
WHERE t.instrument_id = 4 ORDER BY t.observed_at;
ROLLBACK;
