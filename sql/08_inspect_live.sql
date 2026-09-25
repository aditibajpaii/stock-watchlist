-- =====================================================================
-- 08_inspect_live.sql
-- Small READ-ONLY "DB inspector" for demos and viva: proves the ticks
-- and alerts shown in the web UI are really stored in PostgreSQL.
--
-- Shows: row counts, ticks per source, latest 10 price_ticks, latest
-- 10 alert_events (joined to rule, user, instrument and tick).
--
-- Run:  psql -d stock_watchlist -f sql/08_inspect_live.sql
-- The transaction is READ ONLY: any write would fail. It changes nothing.
-- =====================================================================

\pset footer off
\set QUIET on
BEGIN TRANSACTION READ ONLY;

\echo '===== Row counts ====='
SELECT (SELECT count(*) FROM users)           AS users,
       (SELECT count(*) FROM instruments)     AS instruments,
       (SELECT count(*) FROM watchlists)      AS watchlists,
       (SELECT count(*) FROM watchlist_items) AS watchlist_items,
       (SELECT count(*) FROM price_ticks)     AS price_ticks,
       (SELECT count(*) FROM alert_rules)     AS alert_rules,
       (SELECT count(*) FROM alert_events)    AS alert_events;

\echo '===== Ticks per source and instrument ====='
SELECT t.source, i.exchange, i.symbol, count(*) AS ticks,
       min(t.observed_at) AS first_observed, max(t.observed_at) AS last_observed
FROM price_ticks t
JOIN instruments i ON i.instrument_id = t.instrument_id
GROUP BY t.source, i.exchange, i.symbol
ORDER BY t.source, i.exchange, i.symbol;

\echo '===== Latest 10 price_ticks (by market time observed_at, then tick_id) ====='
SELECT t.tick_id, i.exchange, i.symbol, t.price, t.volume, t.source, t.source_event_id,
       t.observed_at, t.ingested_at
FROM price_ticks t
JOIN instruments i ON i.instrument_id = t.instrument_id
ORDER BY t.observed_at DESC, t.tick_id DESC
LIMIT 10;

\echo '===== Latest 10 alert_events (joined; alert_events itself stores only 4 columns) ====='
SELECT e.event_id, e.fired_at, u.username, i.symbol, r.direction, r.threshold,
       t.price AS tick_price, t.observed_at, t.source, e.rule_id, e.tick_id
FROM alert_events e
JOIN alert_rules r ON r.rule_id = e.rule_id
JOIN users u       ON u.user_id = r.user_id
JOIN price_ticks t ON t.tick_id = e.tick_id
JOIN instruments i ON i.instrument_id = t.instrument_id
ORDER BY e.fired_at DESC, e.event_id DESC
LIMIT 10;

ROLLBACK;
