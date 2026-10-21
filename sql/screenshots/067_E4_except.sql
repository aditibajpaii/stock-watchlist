SELECT instrument_id FROM instruments
EXCEPT
SELECT instrument_id FROM alert_rules;
