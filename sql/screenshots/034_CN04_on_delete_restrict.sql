DELETE FROM instruments WHERE symbol = 'RELIANCE';
DELETE FROM price_ticks WHERE tick_id IN (SELECT tick_id FROM alert_events);
SELECT count(*) FROM instruments;
SELECT count(*) FROM price_ticks;
