\echo '========================================================================'
\echo ' D8 | Subquery: NOT IN and the NULL pitfall'
\echo '      Q: Which TCS trade sizes (volume) never occurred on RELIANCE?'
\echo '      RELIANCE has NULL volumes, so x NOT IN (..., NULL) is never TRUE -> 0 rows.'
\echo '========================================================================'
-- 1) NOT IN with a NULL in the list: wrong answer (0 rows)
SELECT tick_id, volume FROM price_ticks
WHERE instrument_id = 2
  AND volume NOT IN (SELECT volume FROM price_ticks WHERE instrument_id = 1);

-- 2) fix A: exclude NULLs inside the subquery
SELECT tick_id, volume FROM price_ticks
WHERE instrument_id = 2
  AND volume NOT IN (SELECT volume FROM price_ticks
                     WHERE instrument_id = 1 AND volume IS NOT NULL)
ORDER BY tick_id;

-- 3) fix B: NOT EXISTS is NULL-safe
SELECT t.tick_id, t.volume FROM price_ticks t
WHERE t.instrument_id = 2 AND t.volume IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM price_ticks r
                  WHERE r.instrument_id = 1 AND r.volume = t.volume)
ORDER BY t.tick_id;
