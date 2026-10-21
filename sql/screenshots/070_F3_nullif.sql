\echo '========================================================================'
\echo ' F3 | Function: NULLIF (avoid division by zero)'
\echo '      Q: Ratio of ticks with a known volume to ticks with an unknown volume'
\echo '         (INFY has 0 unknown-volume ticks: NULLIF turns 0 into NULL, no error)'
\echo '========================================================================'
SELECT i.symbol,
       count(t.volume)                                   AS known_volume,
       count(*) - count(t.volume)                        AS unknown_volume,
       round(count(t.volume)::numeric
             / NULLIF(count(*) - count(t.volume), 0), 2) AS known_to_unknown_ratio
FROM price_ticks t
JOIN instruments i ON i.instrument_id = t.instrument_id
GROUP BY i.symbol
ORDER BY i.symbol;

-- the same division WITHOUT NULLIF fails for INFY:
SELECT count(volume)::numeric / (count(*) - count(volume)) AS ratio
FROM price_ticks WHERE instrument_id = 3;
