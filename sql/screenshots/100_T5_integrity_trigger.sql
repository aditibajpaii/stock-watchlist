SELECT rule_id, instrument_id FROM alert_rules WHERE rule_id = 1;
SELECT tick_id, instrument_id FROM price_ticks WHERE tick_id = 3;
INSERT INTO alert_events (rule_id, tick_id) VALUES (1, 3);
