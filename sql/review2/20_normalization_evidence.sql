-- =====================================================================
-- 20_normalization_evidence.sql  -  real output used by
-- docs/review2/NORMALIZATION_PROOF.md. Read-only.
--
--   N1  fired_at versus the ingested_at of the tick that fired the alert
--   N2  the data as ONE unnormalized "sheet" per user (repeating groups)
--   N3  the 1NF watch-entry relation: the redundancy that 2NF removes
--   N4  how often each instrument name would be stored in N3
-- =====================================================================
\ir _guard.sql

\echo '=== N1 | fired_at equals the ingested_at of the firing tick for every event?'
-- Both columns default to now(); the alert trigger runs inside the tick's
-- own transaction, so both get the same transaction start time.
SELECT count(*)                                                   AS alert_events,
       count(*) FILTER (WHERE e.fired_at = t.ingested_at)         AS fired_at_equals_tick_ingested_at,
       count(*) FILTER (WHERE e.fired_at IS DISTINCT FROM t.ingested_at) AS different
FROM alert_events e
JOIN price_ticks t ON t.tick_id = e.tick_id;

\echo '=== N2 | Unnormalized: one row per user with two repeating groups (watchlist entries, rules)'
SELECT u.username, u.email,
       (SELECT string_agg(w.name || ': ' || i.symbol, '; ' ORDER BY w.name, i.symbol)
          FROM watchlists w
          JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
          JOIN instruments i      ON i.instrument_id = wi.instrument_id
         WHERE w.user_id = u.user_id)                         AS watchlist_entries,
       (SELECT string_agg(i.symbol || ' ' || r.direction || ' ' || round(r.threshold)
                          || ' cd ' || r.cooldown_seconds, '; ' ORDER BY r.rule_id)
          FROM alert_rules r
          JOIN instruments i ON i.instrument_id = r.instrument_id
         WHERE r.user_id = u.user_id)                         AS alert_rules
FROM users u
ORDER BY u.username;

\echo '=== N3 | 1NF relation WATCH_ENTRY(username, watchlist_name, exchange, symbol, instrument_name, quote_currency)'
SELECT u.username, w.name AS watchlist_name, i.exchange, i.symbol,
       i.name AS instrument_name, i.quote_currency
FROM watchlists w
JOIN users u            ON u.user_id = w.user_id
JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
JOIN instruments i      ON i.instrument_id = wi.instrument_id
ORDER BY i.symbol, u.username, w.name;

\echo '=== N4 | Copies of each instrument name that WATCH_ENTRY would store (instruments stores each once)'
SELECT i.symbol, i.name AS instrument_name, count(*) AS copies_in_watch_entry
FROM watchlist_items wi
JOIN instruments i ON i.instrument_id = wi.instrument_id
GROUP BY i.symbol, i.name
ORDER BY copies_in_watch_entry DESC, i.symbol;
