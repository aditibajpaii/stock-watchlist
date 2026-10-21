\echo '========================================================================'
\echo ' CN06 | Duplicate market event: UNIQUE (source, instrument_id, source_event_id)'
\echo '        + ON CONFLICT DO NOTHING inside ingest_tick() -> stored only once'
\echo '========================================================================'
SELECT tick_id, source, source_event_id, price::numeric(12,2), observed_at
FROM price_ticks WHERE source = 'REPLAY' ORDER BY tick_id LIMIT 1;

SELECT source_event_id AS first_id FROM price_ticks
WHERE source = 'REPLAY' ORDER BY tick_id LIMIT 1 \gset

SELECT * FROM ingest_tick('NSE', 'RELIANCE', now(), 2985.50, 1200, 'REPLAY', :'first_id');

SELECT count(*) AS rows_with_this_event_id
FROM price_ticks WHERE source = 'REPLAY' AND source_event_id = :'first_id';
