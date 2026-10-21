SELECT e.event_id, i.symbol, r.direction, r.threshold, x.prev_price, x.price
FROM alert_events e
JOIN alert_rules r ON r.rule_id = e.rule_id
JOIN instruments i ON i.instrument_id = r.instrument_id
JOIN (SELECT tick_id, price,
             LAG(price) OVER (PARTITION BY instrument_id ORDER BY observed_at) AS prev_price
      FROM price_ticks) x ON x.tick_id = e.tick_id
ORDER BY e.event_id;
