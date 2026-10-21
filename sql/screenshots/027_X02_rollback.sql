\echo '========================================================================'
\echo ' X02 | Transaction ROLLBACK: a mistaken DELETE is completely undone'
\echo '========================================================================'
SELECT count(*) AS alert_events_before FROM alert_events;
BEGIN;
DELETE FROM alert_events;
SELECT count(*) AS inside_transaction FROM alert_events;
ROLLBACK;
SELECT count(*) AS alert_events_after_rollback FROM alert_events;
