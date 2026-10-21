\echo '========================================================================'
\echo ' D4 | Subquery: multi-row with ALL and ANY'
\echo '      Q1 (ALL): RELIANCE ticks priced above EVERY RELIANCE rule threshold'
\echo '      Q2 (ANY): TCS ticks priced below AT LEAST ONE TCS rule threshold'
\echo '========================================================================'
SELECT tick_id, price::numeric(12,2) AS price
FROM price_ticks
WHERE instrument_id = 1
  AND price > ALL (SELECT threshold FROM alert_rules WHERE instrument_id = 1)
ORDER BY observed_at;

SELECT tick_id, price::numeric(12,2) AS price
FROM price_ticks
WHERE instrument_id = 2
  AND price < ANY (SELECT threshold FROM alert_rules WHERE instrument_id = 2)
ORDER BY observed_at;
