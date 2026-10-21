\echo '========================================================================'
\echo ' X01 | Transaction with SAVEPOINT, ROLLBACK TO SAVEPOINT and COMMIT'
\echo '       a failed step is undone without losing the earlier work'
\echo '========================================================================'
BEGIN;
INSERT INTO watchlist_items (watchlist_id, instrument_id)
SELECT w.watchlist_id, i.instrument_id FROM watchlists w, instruments i
WHERE w.name = 'Review 2 Demo' AND i.symbol = 'HDFCBANK';

SAVEPOINT before_risky_step;
-- INFY is already in this watchlist: violates the composite primary key
INSERT INTO watchlist_items (watchlist_id, instrument_id)
SELECT w.watchlist_id, i.instrument_id FROM watchlists w, instruments i
WHERE w.name = 'Review 2 Demo' AND i.symbol = 'INFY';
ROLLBACK TO SAVEPOINT before_risky_step;

INSERT INTO watchlist_items (watchlist_id, instrument_id)
SELECT w.watchlist_id, i.instrument_id FROM watchlists w, instruments i
WHERE w.name = 'Review 2 Demo' AND i.symbol = 'TCS';
COMMIT;

SELECT watchlist_name, symbol FROM reporting.v_watchlist_contents
WHERE watchlist_name = 'Review 2 Demo' ORDER BY symbol;
