SELECT e.event_id, i.symbol, r.direction, t.price, t.ingested_at, e.fired_at,
       e.fired_at - t.ingested_at AS delay
FROM alert_events e
JOIN alert_rules r ON r.rule_id = e.rule_id
JOIN price_ticks t ON t.tick_id = e.tick_id
JOIN instruments i ON i.instrument_id = t.instrument_id
ORDER BY e.event_id;
