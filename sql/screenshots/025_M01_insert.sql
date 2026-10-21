\echo '========================================================================'
\echo ' M01 | DML INSERT (autocommit: each statement is committed)'
\echo '       arjun creates a new watchlist and adds 2 instruments'
\echo '========================================================================'
INSERT INTO watchlists (user_id, name)
SELECT user_id, 'Review 2 Demo' FROM users WHERE username = 'arjun'
RETURNING watchlist_id, user_id, name;

INSERT INTO watchlist_items (watchlist_id, instrument_id)
SELECT w.watchlist_id, i.instrument_id
FROM watchlists w, instruments i
WHERE w.name = 'Review 2 Demo' AND i.exchange = 'NSE' AND i.symbol IN ('INFY', 'M&M')
RETURNING watchlist_id, instrument_id;

SELECT username, watchlist_name, exchange, symbol
FROM reporting.v_watchlist_contents
WHERE watchlist_name = 'Review 2 Demo' ORDER BY symbol;
