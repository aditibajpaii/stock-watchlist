\echo '========================================================================'
\echo ' T5 | BEFORE INSERT trigger trg_alert_events_check_instrument'
\echo '      rejects an alert whose rule and tick belong to DIFFERENT instruments'
\echo '========================================================================'
\sf check_alert_event_instrument
INSERT INTO alert_events (rule_id, tick_id)
VALUES (1, (SELECT tick_id FROM price_ticks WHERE instrument_id = 6 ORDER BY tick_id LIMIT 1));
