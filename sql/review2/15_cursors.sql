-- =====================================================================
-- 15_cursors.sql  -  Template: cursors (>= 2)
--
-- SQL is set-oriented: one statement describes the whole result and the
-- planner decides how to compute it. A cursor hands the result over one
-- row (or a few rows) at a time. That is useful for paging through a
-- large result or for procedural, row-by-row logic, but it is NOT
-- automatically faster; C2 is checked against an equivalent set-based
-- query that gives the same answer. Production queries do not use cursors.
--
--   C1 SQL-level SCROLL cursor over RELIANCE ticks:
--      DECLARE (opens it) -> FETCH / MOVE -> CLOSE, inside a transaction
--   C2 PL/pgSQL explicit cursor in review2.fn_max_drawdown():
--      DECLARE -> OPEN -> FETCH in a loop -> CLOSE
-- Read-only.
-- =====================================================================
\ir _guard.sql

\echo '===== C1: SQL-level cursor ====='
BEGIN;
DECLARE c_reliance SCROLL CURSOR FOR
    SELECT t.tick_id, t.price, t.volume
    FROM price_ticks t
    JOIN instruments i ON i.instrument_id = t.instrument_id
    WHERE i.exchange = 'NSE' AND i.symbol = 'RELIANCE'
    ORDER BY t.observed_at, t.tick_id;

\echo 'the cursor is open (pg_cursors lists the cursors of this session):'
SELECT name, is_holdable, is_scrollable, statement IS NOT NULL AS has_query FROM pg_cursors;

\echo 'FETCH FORWARD 3 -> rows 1-3'
FETCH FORWARD 3 FROM c_reliance;
\echo 'FETCH NEXT -> row 4'
FETCH NEXT FROM c_reliance;
\echo 'FETCH PRIOR -> back to row 3 (needs SCROLL)'
FETCH PRIOR FROM c_reliance;
\echo 'MOVE ABSOLUTE 9 (no rows returned, only repositions), then FETCH NEXT -> row 10'
MOVE ABSOLUTE 9 IN c_reliance;
FETCH NEXT FROM c_reliance;
\echo 'FETCH LAST -> row 12'
FETCH LAST FROM c_reliance;

CLOSE c_reliance;
\echo 'after CLOSE no cursor is open:'
SELECT count(*) AS open_cursors FROM pg_cursors;
COMMIT;

\echo '===== C2: PL/pgSQL explicit cursor - maximum drawdown per instrument ====='
-- Maximum drawdown = the largest fall from a running peak price to a
-- later price, as a percentage of that peak. The loop keeps state
-- (current instrument, running peak, worst fall so far) while it walks
-- the ticks in market-time order.
CREATE OR REPLACE FUNCTION review2.fn_max_drawdown()
RETURNS TABLE (symbol TEXT, ticks INT, peak_price NUMERIC,
               trough_price NUMERIC, max_drawdown_pct NUMERIC)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    c_ticks CURSOR FOR
        SELECT i.symbol AS sym, t.price
        FROM price_ticks t
        JOIN instruments i ON i.instrument_id = t.instrument_id
        ORDER BY i.symbol, t.observed_at, t.tick_id;
    r        RECORD;
    v_symbol TEXT;
    v_n      INT;
    v_peak   NUMERIC;
    v_dd     NUMERIC;
    v_dd_peak   NUMERIC;
    v_dd_trough NUMERIC;
BEGIN
    OPEN c_ticks;
    LOOP
        FETCH c_ticks INTO r;
        EXIT WHEN NOT FOUND;

        IF v_symbol IS DISTINCT FROM r.sym THEN
            IF v_symbol IS NOT NULL THEN      -- emit the finished instrument
                symbol := v_symbol; ticks := v_n;
                peak_price := v_dd_peak; trough_price := v_dd_trough;
                max_drawdown_pct := round(100 * v_dd, 2);
                RETURN NEXT;
            END IF;
            v_symbol := r.sym; v_n := 0; v_peak := r.price;
            v_dd := 0; v_dd_peak := NULL; v_dd_trough := NULL;
        END IF;

        v_n := v_n + 1;
        IF r.price > v_peak THEN
            v_peak := r.price;
        ELSIF (v_peak - r.price) / v_peak > v_dd THEN
            v_dd := (v_peak - r.price) / v_peak;
            v_dd_peak := v_peak; v_dd_trough := r.price;
        END IF;
    END LOOP;
    CLOSE c_ticks;

    IF v_symbol IS NOT NULL THEN              -- emit the last instrument
        symbol := v_symbol; ticks := v_n;
        peak_price := v_dd_peak; trough_price := v_dd_trough;
        max_drawdown_pct := round(100 * v_dd, 2);
        RETURN NEXT;
    END IF;
END;
$$;
COMMENT ON FUNCTION review2.fn_max_drawdown() IS
    'Cursor demonstration: per-instrument maximum drawdown, computed row by row.';

\echo 'cursor result:'
SELECT * FROM review2.fn_max_drawdown() ORDER BY max_drawdown_pct DESC, symbol;

\echo '===== The same answer, set-based (window functions, no cursor) ====='
WITH running AS (
    SELECT i.symbol, t.price, t.observed_at, t.tick_id,
           max(t.price) OVER (PARTITION BY i.symbol ORDER BY t.observed_at, t.tick_id
                              ROWS UNBOUNDED PRECEDING) AS running_peak,
           count(*) OVER (PARTITION BY i.symbol) AS ticks
    FROM price_ticks t
    JOIN instruments i ON i.instrument_id = t.instrument_id
), ranked AS (
    SELECT symbol, ticks, running_peak, price,
           (running_peak - price) / running_peak AS dd,
           row_number() OVER (PARTITION BY symbol
                              ORDER BY (running_peak - price) / running_peak DESC,
                                       observed_at, tick_id) AS rn
    FROM running
)
SELECT symbol, ticks::int AS ticks,
       CASE WHEN dd > 0 THEN running_peak END AS peak_price,
       CASE WHEN dd > 0 THEN price END        AS trough_price,
       round(100 * dd, 2)                     AS max_drawdown_pct
FROM ranked
WHERE rn = 1
ORDER BY max_drawdown_pct DESC, symbol;

\echo 'rows that differ between the cursor version and the set-based version (expect 0):'
WITH running AS (
    SELECT i.symbol, t.price, t.observed_at, t.tick_id,
           max(t.price) OVER (PARTITION BY i.symbol ORDER BY t.observed_at, t.tick_id
                              ROWS UNBOUNDED PRECEDING) AS running_peak,
           count(*) OVER (PARTITION BY i.symbol) AS ticks
    FROM price_ticks t
    JOIN instruments i ON i.instrument_id = t.instrument_id
), ranked AS (
    SELECT symbol, ticks, running_peak, price,
           (running_peak - price) / running_peak AS dd,
           row_number() OVER (PARTITION BY symbol
                              ORDER BY (running_peak - price) / running_peak DESC,
                                       observed_at, tick_id) AS rn
    FROM running
), set_based AS (
    SELECT symbol, ticks::int AS ticks,
           CASE WHEN dd > 0 THEN running_peak END AS peak_price,
           CASE WHEN dd > 0 THEN price END        AS trough_price,
           round(100 * dd, 2)                     AS max_drawdown_pct
    FROM ranked WHERE rn = 1
)
SELECT count(*) AS differing_rows
FROM ((SELECT * FROM set_based EXCEPT SELECT * FROM review2.fn_max_drawdown())
      UNION ALL
      (SELECT * FROM review2.fn_max_drawdown() EXCEPT SELECT * FROM set_based)) AS diff;
