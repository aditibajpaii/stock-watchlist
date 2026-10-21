\echo '========================================================================'
\echo ' F1 | Function: CASE'
\echo '      Q: Classify each RELIANCE tick by trade size and by price zone'
\echo '========================================================================'
SELECT tick_id, price::numeric(12,2) AS price, volume,
       CASE WHEN volume IS NULL  THEN 'unknown'
            WHEN volume >= 1400  THEN 'large'
            WHEN volume >= 1000  THEN 'medium'
            ELSE 'small' END AS trade_size,
       CASE WHEN price >= 3000 THEN 'above 3000 (rule 1 zone)'
            WHEN price <= 2800 THEN 'below 2800 (rule 2 zone)'
            ELSE 'between' END AS price_zone
FROM price_ticks
WHERE instrument_id = 1
ORDER BY observed_at;
