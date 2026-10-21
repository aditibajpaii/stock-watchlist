-- =====================================================================
-- _guard.sql  (included by every sql/review2 script with \ir)
-- Stops the script unless it is connected to the academic sandbox
-- database. The classroom database stock_watchlist is never used for
-- Review 2 demonstrations.
-- =====================================================================
\set ECHO none
SELECT current_database() = 'stock_watchlist_review2_sandbox' AS in_review2_sandbox \gset
\if :in_review2_sandbox
\else
  \echo 'REFUSING TO RUN: connect to stock_watchlist_review2_sandbox, not' :DBNAME
  \set ON_ERROR_STOP on
  DO $$ BEGIN RAISE EXCEPTION 'Review 2 scripts run only on stock_watchlist_review2_sandbox'; END $$;
\endif
\pset pager off
\pset footer on
\pset null '(null)'
\set ECHO queries
