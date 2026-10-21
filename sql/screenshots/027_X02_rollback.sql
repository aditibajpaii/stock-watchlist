SELECT count(*) FROM alert_events;
BEGIN;
DELETE FROM alert_events;
SELECT count(*) FROM alert_events;
ROLLBACK;
SELECT count(*) FROM alert_events;
