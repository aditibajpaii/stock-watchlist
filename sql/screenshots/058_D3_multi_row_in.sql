SELECT symbol
FROM instruments
WHERE instrument_id IN (SELECT instrument_id FROM alert_rules
                        WHERE rule_id IN (SELECT rule_id FROM alert_events));
