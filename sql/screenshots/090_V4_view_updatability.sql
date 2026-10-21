SELECT table_name, is_updatable, is_insertable_into
FROM information_schema.views
WHERE table_schema = 'reporting';

UPDATE reporting.v_watchlist_contents SET symbol = 'X' WHERE username = 'arjun';
UPDATE reporting.v_instrument_price_summary SET tick_count = 0;
