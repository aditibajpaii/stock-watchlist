\echo '========================================================================'
\echo ' T2 | AFTER INSERT trigger trg_price_ticks_evaluate_alerts fires an alert'
\echo '      new rule: arjun HDFCBANK ABOVE 1700. Ticks 1690 -> 1710 -> 1720.'
\echo '      Only the crossing (1690 -> 1710) creates an event (edge-triggered).'
\echo '      Everything is rolled back.'
\echo '========================================================================'
BEGIN;
INSERT INTO alert_rules (user_id, instrument_id, direction, threshold, cooldown_seconds)
VALUES (1, 4, 'ABOVE', 1700, 300)
RETURNING rule_id, direction, threshold::numeric(12,2), cooldown_seconds;

SELECT v.sec, v.price, r.status, r.tick_id
FROM (VALUES (0, 1690), (10, 1710), (20, 1720)) AS v(sec, price)
CROSS JOIN LATERAL ingest_tick('NSE', 'HDFCBANK', now() + v.sec * interval '1 second',
                               v.price, NULL, 'MANUAL', 'ss-t2:' || v.sec) AS r
ORDER BY v.sec;

SELECT e.event_id, e.rule_id, t.price::numeric(12,2) AS tick_price, t.observed_at::time(0)
FROM alert_events e JOIN price_ticks t ON t.tick_id = e.tick_id
WHERE t.instrument_id = 4;
ROLLBACK;
