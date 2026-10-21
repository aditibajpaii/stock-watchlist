SELECT tick_id, source, source_event_id, price FROM price_ticks WHERE source_event_id = 'demo1:000001';

SELECT * FROM ingest_tick('NSE', 'RELIANCE', now(), 2985.50, 1200, 'REPLAY', 'demo1:000001');

SELECT count(*) FROM price_ticks WHERE source_event_id = 'demo1:000001';
