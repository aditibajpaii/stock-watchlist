\echo '========================================================================'
\echo ' CN03 | FOREIGN KEY constraints reject references to missing rows'
\echo '========================================================================'
INSERT INTO watchlists (user_id, name) VALUES (999, 'Ghost list');
INSERT INTO watchlist_items (watchlist_id, instrument_id) VALUES (1, 999);
INSERT INTO alert_events (rule_id, tick_id) VALUES (1, 999999);
