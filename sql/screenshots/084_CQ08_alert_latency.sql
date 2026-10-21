\echo '========================================================================'
\echo ' CQ08 | Complex: 4 tables + interval arithmetic'
\echo '        Q: How quickly was each alert recorded after its tick was stored?'
\echo '           (the trigger runs inside the same INSERT -> fractions of a millisecond)'
\echo '========================================================================'
SELECT e.event_id, i.symbol, r.direction,
       t.price::numeric(12,2)                                            AS price,
       t.ingested_at::time(3)                                            AS tick_stored_at,
       e.fired_at::time(3)                                               AS alert_recorded_at,
       round(extract(epoch FROM e.fired_at - t.ingested_at) * 1000, 3)   AS delay_ms
FROM alert_events e
JOIN price_ticks t ON t.tick_id = e.tick_id
JOIN alert_rules r ON r.rule_id = e.rule_id
JOIN instruments i ON i.instrument_id = r.instrument_id
ORDER BY e.event_id;
