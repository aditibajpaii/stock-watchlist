# Evidence Checklist

Screenshots for the official report. Take them in a terminal with a
readable font and a window wide enough that psql output does not wrap.

## One-time setup (every new terminal)

```sh
export PATH="/opt/homebrew/opt/postgresql@18/bin:$PATH"
cd "/Users/aditi/dbms project"
```

Optional: nicer psql output for screenshots

```sh
psql -d stock_watchlist
\pset border 2
\pset null '(null)'
```

Suggested filename pattern: `NN_short-name.png` in `docs/screenshots/`.

---

## Section 5 – ER Diagram (3 marks)

Source: `docs/ER_DIAGRAM.md` (verified against the live catalog).

- [ ] **01_er-diagram.png** — exported image of the Mermaid diagram.
      Paste the ```mermaid block into https://mermaid.live, then use
      Actions → PNG. Also export an SVG, which stays sharp when printed.
      It must show all 7 entities, PK/FK/UK markers, and 8 relationship
      lines with crow's-foot cardinality.
- [ ] **01b_er-relationships.png** — relationships proven from the
      catalog, not drawn by hand:
      `psql -d stock_watchlist -f sql/verify_spec.sql`
      Capture section "4. Relationships derived from foreign keys"
      (8 rows: parent, child, FK, 1 : 0..N, participation, ON DELETE).
- [ ] **01c_fk-list.png** — the "Foreign keys and ON DELETE" section of
      `sql/inspect_schema.sql`, as a second source for the same 8 edges.

For the report team:
- The Mermaid diagram is the verified reference. If you redraw it in
  another tool (draw.io, Chen notation), check every line against
  01b. Do not add relationships without an FK; for example, there is NO
  direct users–instruments link.
- The two M:N relationships (watchlists–instruments and
  alert_rules–price_ticks) are shown through the junction tables
  watchlist_items and alert_events.

## Section 6 – Tables and Constraints (5 marks)

### 6.1 Database and server

- [ ] **02_pg-version.png** —
      `psql -d stock_watchlist -c "SELECT version();"`
- [ ] **03_schema-run.png** — successful creation of all 7 tables:
      `psql -d stock_watchlist -v ON_ERROR_STOP=1 -f sql/00_schema.sql`
      (shows `CREATE TABLE` ×7 and `COMMIT`)
- [ ] **04_table-list.png** — `psql -d stock_watchlist -c '\dt'`

### 6.2 For EACH of the 7 tables (template requires all four items)

Take one screenshot of the CREATE TABLE statement (open
`sql/00_schema.sql` in the editor and capture that table's block) and one
of `\d <table>`, which shows columns, types, NOT NULL, defaults, PK,
UNIQUE, CHECK and FK constraints together.

| Table | CREATE TABLE screenshot | Structure screenshot | Command |
|---|---|---|---|
| users | [ ] 05a_create_users.png | [ ] 05b_d_users.png | `\d users` |
| instruments | [ ] 06a_create_instruments.png | [ ] 06b_d_instruments.png | `\d instruments` |
| watchlists | [ ] 07a_create_watchlists.png | [ ] 07b_d_watchlists.png | `\d watchlists` |
| watchlist_items | [ ] 08a_create_watchlist_items.png | [ ] 08b_d_watchlist_items.png | `\d watchlist_items` |
| price_ticks | [ ] 09a_create_price_ticks.png | [ ] 09b_d_price_ticks.png | `\d price_ticks` |
| alert_rules | [ ] 10a_create_alert_rules.png | [ ] 10b_d_alert_rules.png | `\d alert_rules` |
| alert_events | [ ] 11a_create_alert_events.png | [ ] 11b_d_alert_events.png | `\d alert_events` |

### 6.3 Constraint summary (all tables)

- [ ] **12_constraints.png** and **13_fk-on-delete.png** — run:
      `psql -d stock_watchlist -f sql/inspect_schema.sql`
      and capture the "Constraints" and "Foreign keys and ON DELETE"
      sections (36 named constraints; 8 FKs with CASCADE/RESTRICT).

### 6.4 Sample rows

- [ ] **14_seed-run.png** —
      `psql -d stock_watchlist -v ON_ERROR_STOP=1 -f sql/01_seed.sql`
- [ ] **15_sample-rows.png** — in psql:
      ```sql
      SELECT * FROM users;
      SELECT * FROM instruments;
      SELECT * FROM watchlists;
      SELECT * FROM alert_rules;
      ```
- [ ] **16_watchlist-join.png** — proves the M:N relationship:
      ```sql
      SELECT u.username, w.name AS watchlist, i.exchange, i.symbol
      FROM watchlist_items wi
      JOIN watchlists  w USING (watchlist_id)
      JOIN users       u USING (user_id)
      JOIN instruments i USING (instrument_id)
      ORDER BY u.username, w.name, i.symbol;
      ```

### 6.5 Constraints actually working

- [ ] **17_schema-tests.png** — the results table (51 rows, all PASS) and
      the summary line:
      `psql -d stock_watchlist -v ON_ERROR_STOP=1 -f sql/02_schema_tests.sql`

Raw PostgreSQL error messages are more convincing to an examiner. Take
each of these inside a transaction you roll back, so the seed stays
unchanged:

```sql
BEGIN;
-- 18_err-unique.png  (UNIQUE)
INSERT INTO users (username, email) VALUES ('arjun', 'x@example.com');
ROLLBACK;

BEGIN;
-- 19_err-check.png  (CHECK)
INSERT INTO price_ticks (instrument_id, observed_at, price, source, source_event_id)
VALUES (1, now(), -5, 'MANUAL', 'manual:neg');
ROLLBACK;

BEGIN;
-- 20_err-fk.png  (FOREIGN KEY)
INSERT INTO watchlists (user_id, name) VALUES (999, 'Ghost');
ROLLBACK;

BEGIN;
-- 21_err-restrict.png  (ON DELETE RESTRICT)
DELETE FROM instruments WHERE exchange = 'NSE' AND symbol = 'RELIANCE';
ROLLBACK;

BEGIN;
-- 22_cascade.png  (ON DELETE CASCADE)
SELECT count(*) FROM watchlists WHERE user_id = 1;   -- before: 2
DELETE FROM users WHERE username = 'arjun';
SELECT count(*) FROM watchlists WHERE user_id = 1;   -- after: 0
ROLLBACK;
```

## Normal forms (2 marks)

Source notes: `docs/NORMALIZATION_NOTES.md`. The team writes the report
text from these.

- [ ] **23_schema-matches-spec.png** — live schema identical to the
      approved design:
      `psql -d stock_watchlist -v ON_ERROR_STOP=1 -f sql/verify_spec.sql`
      Capture sections 1–3 (empty mismatch tables) and the final NOTICE
      `LIVE SCHEMA MATCHES docs/PHASE1_SPEC.md`.
- [ ] **24_composite-keys.png** — the composite keys that 2NF is checked
      against. In psql:
      `\d watchlist_items`  (composite PK)
      `\d alert_rules`      (4-column UNIQUE)
      `\d price_ticks`      (3-column UNIQUE)
- [ ] **25_fd-counterexamples.png** — proof that rejected FDs really are
      false. Run in psql; it rolls back and changes nothing:
      ```sql
      BEGIN;
      INSERT INTO instruments (exchange, symbol, name, quote_currency) VALUES
        ('BSE','RELIANCE','Reliance Industries Ltd','INR'),
        ('BINANCE','ETHBTC','Ether / Bitcoin','BTC');
      SELECT exchange, symbol, quote_currency FROM instruments
      WHERE symbol IN ('RELIANCE','BTCUSDT','ETHUSDT','ETHBTC')
      ORDER BY exchange, symbol;
      SELECT exchange, count(DISTINCT quote_currency) AS currencies
      FROM instruments GROUP BY exchange;
      ROLLBACK;
      ```
      This shows the symbol repeating across exchanges (symbol is not a
      key) and BINANCE having 2 currencies (exchange ↛ quote_currency).
- [ ] **26_timestamp-not-identity.png** — rows A9 and A10 of the
      schema-test output (screenshot 17), showing identity is the source
      event, not the timestamp.
- [ ] **27_fd-table** — not a screenshot. The team builds the per-table
      FD / candidate key / NF table from NORMALIZATION_NOTES.md §8.
- [ ] **28_no-duplication-join.png** — any DEMO 1 or DEMO 3 event
      table from `sql/05_demo_queries.sql` (screenshots 34/36). The
      event row shows symbol, price and observed_at, all obtained by
      joining through tick_id; alert_events itself stores only
      (event_id, rule_id, tick_id, fired_at).

## Marks → evidence map

| Marks | Minimum evidence | Strong extra evidence |
|---|---|---|
| ER Diagram (3) | 01 | 01b, 01c |
| Tables + description + screenshots (5) | 03, 04, 05a–11a (CREATE TABLE ×7), 05b–11b (`\d` ×7) | 02, 12, 13, 14–16, 17, 18–22 |
| Normal forms (2) | 27 (FD/NF table from notes), 24 | 23, 25, 26, 28 |

## Phase 4 – Ingestion and alert engine (strong extra evidence)

The template has no dedicated marks for triggers. This evidence supports
"Tables and Constraints" (the database doing the work) and the Review
Evaluation / viva.

### Definitions

- [ ] **30_functions-list.png** — in psql: `\df`
      (3 rows: ingest_tick, evaluate_price_alerts, check_alert_event_instrument)
- [ ] **31_ingest_tick-def.png** — in psql: `\sf ingest_tick`
      (or open sql/03_functions_triggers.sql, section 3)
- [ ] **32_alert-trigger-def.png** — in psql: `\sf evaluate_price_alerts`
- [ ] **33_integrity-trigger-def.png** — in psql:
      `\sf check_alert_event_instrument`
- [ ] **33b_trigger-list.png** — in psql:
      ```sql
      SELECT tgname, tgrelid::regclass AS on_table, pg_get_triggerdef(oid)
      FROM pg_trigger WHERE NOT tgisinternal ORDER BY 1;
      ```
      or `\d price_ticks` and `\d alert_events` (see the "Triggers:" section)

### Behaviour (one script, fully rolled back, safe to repeat)

`psql -d stock_watchlist -f sql/05_demo_queries.sql`

It picks its market time T0 = 10 min after the latest stored
RELIANCE/BTCUSDT tick (or now). It works on a clean database and after
replays, and shows only its own events.

| Screenshot | Section of the output |
|---|---|
| [ ] **34_above-alert-fires.png** | DEMO 1 — 2990 then 3005 → one ABOVE event |
| [ ] **35_no-repeat-while-above.png** | DEMO 2 — 3010, 3020 → still one event |
| [ ] **36_cooldown.png** | DEMO 3 — re-cross after 19 s suppressed; re-cross after 329 s fires (2 events) |
| [ ] **37_duplicate-input.png** | DEMO 4 — status DUPLICATE, 1 tick with that id, demo events still 2 |
| [ ] **38_late-tick.png** | DEMO 5 — the T0−60 s tick is stored (first row by time), no BELOW event |
| [ ] **39_integrity-error.png** | DEMO 6 — ERROR "rule 1 is for instrument 1, but tick … is for instrument 6" |
| [ ] **40_rollback.png** | DEMO 7 — 10 ticks / 2 events added inside, 0 / 0 after ROLLBACK |

### Automated test results

- [ ] **41_alert-tests.png** —
      `psql -d stock_watchlist -v ON_ERROR_STOP=1 -f sql/04_alert_tests.sql`
      (results table + "50 | 0 | 50")
- [ ] **42_concurrency-script.png** — `bash tests/concurrency_test.sh`
      (4 scenarios, "ALL CONCURRENCY CHECKS PASSED"). It uses its own
      throwaway DB and does not touch stock_watchlist.
- [ ] **43_verify-spec-phase4.png** —
      `psql -d stock_watchlist -f sql/verify_spec.sql`, section 3b and the
      final NOTICE

### Two-terminal lock demonstration (manual, for screenshots 44–46)

Uses a separate demo database, so the dev seed data is never changed.

**SETUP (any terminal, once):**
```sh
export PATH="/opt/homebrew/opt/postgresql@18/bin:$PATH"
cd "/Users/aditi/dbms project"
dropdb --if-exists stock_watchlist_demo
createdb stock_watchlist_demo
psql -q -d stock_watchlist_demo -v ON_ERROR_STOP=1 \
     -f sql/00_schema.sql -f sql/01_seed.sql -f sql/03_functions_triggers.sql
psql -d stock_watchlist_demo -c "SELECT * FROM ingest_tick('NSE','RELIANCE','2026-01-05 09:15:00+05:30',2990,100,'MANUAL','demo:base');"
```

**TERMINAL A**
```sh
psql -d stock_watchlist_demo
```
```sql
\set PROMPT1 'TERMINAL-A %# '
BEGIN;
SELECT * FROM ingest_tick('NSE','RELIANCE','2026-01-05 09:15:01+05:30',3005,100,'MANUAL','demo:A');
-- returns INSERTED. Do NOT commit yet; the RELIANCE row lock is held.
```

**TERMINAL B**
```sh
psql -d stock_watchlist_demo
```
```sql
\set PROMPT1 'TERMINAL-B %# '
BEGIN;
SELECT * FROM ingest_tick('NSE','RELIANCE','2026-01-05 09:15:02+05:30',3010,100,'MANUAL','demo:B');
-- HANGS here: B is waiting for A's lock.
```
- [ ] **44_terminal-B-waiting.png** — both terminals side by side, B hanging

**TERMINAL C (optional observer, while B hangs)**
```sh
psql -d stock_watchlist_demo
```
```sql
SELECT pid, state, wait_event_type, wait_event, pg_blocking_pids(pid) AS blocked_by,
       left(query, 60) AS query
FROM pg_stat_activity
WHERE datname = 'stock_watchlist_demo' AND pid <> pg_backend_pid();
LISTEN alert_events;
```
- [ ] **45_blocking-pids.png** — B shows wait_event_type = Lock,
      wait_event = transactionid, blocked_by = {A's pid}

**TERMINAL A**
```sql
COMMIT;
```
**TERMINAL B** — the SELECT now returns INSERTED immediately. Then:
```sql
COMMIT;
SELECT e.event_id, t.source_event_id, t.price, t.observed_at
FROM alert_events e JOIN price_ticks t USING (tick_id) ORDER BY e.event_id;
-- exactly ONE event, on demo:A. B saw A's 3005 as its previous price.
```
**TERMINAL C** — type `SELECT 1;` and psql prints
`Asynchronous notification "alert_events" with payload "1" received …`
(only A's committed event).
- [ ] **46_after-commit.png** — B's result, the single event and C's
      notification

**CLEANUP**, after quitting all three with `\q`:
```sh
dropdb stock_watchlist_demo
```

## Phase 5 – Offline replay (Python → ingest_tick → alerts)

### Setup (each new terminal)
```sh
export PATH="/opt/homebrew/opt/postgresql@18/bin:$PATH"
cd "/Users/aditi/dbms project"
source .venv/bin/activate
```
First time only (already done on this machine):
```sh
python3.13 -m venv .venv
pip install -r requirements.txt
```

### Clean demo database (recommended before a classroom demo)

This resets stock_watchlist to seed data, destroying replay and demo
ticks, so a replay produces exactly 8 alerts:
```sh
psql -q -d stock_watchlist -v ON_ERROR_STOP=1 \
     -f sql/00_schema.sql -f sql/01_seed.sql -f sql/03_functions_triggers.sql
```

### Screenshots

- [ ] **50_replay-dry-run.png** —
      `python -m app.replay data/replay_prices.csv --dry-run --run-id demo1`
      (30 "would send" lines with observed_at and source_event_id; no DB
      changes)
- [ ] **51_replay-run.png** — the live-looking run, prices arriving one by
      one:
      `python -m app.replay data/replay_prices.csv --delay-ms 300 --run-id demo1`
      Capture the ALERT lines (8) and the summary (Inserted 30, Alerts 8).
- [ ] **52_replay-duplicate.png** — the same run id again:
      `python -m app.replay data/replay_prices.csv --run-id demo1`
      ("Retrying run demo1", 30 × DUPLICATE, Inserted 0)
- [ ] **53_replay-late-guard.png** — a new run immediately afterwards:
      `python -m app.replay data/replay_prices.csv --run-id demo2`
      (refused, with the LATE explanation, exit 2). Optional follow-up:
      add `--start-after-latest` (30 inserted, 7 alerts).
- [ ] **54_replay-db-view.png** — in psql, after the run:
      ```sql
      -- latest 10 ticks
      SELECT t.tick_id, i.exchange, i.symbol, t.price, t.volume,
             t.observed_at, t.source, t.source_event_id
      FROM price_ticks t JOIN instruments i USING (instrument_id)
      ORDER BY t.observed_at DESC, t.tick_id DESC LIMIT 10;

      -- alert events created by the replay, with the rule that caused them
      SELECT e.event_id, u.username, i.symbol, r.direction, r.threshold,
             r.cooldown_seconds, t.price, t.observed_at, t.source_event_id
      FROM alert_events e
      JOIN alert_rules r USING (rule_id)
      JOIN users u       USING (user_id)
      JOIN price_ticks t USING (tick_id)
      JOIN instruments i ON i.instrument_id = t.instrument_id
      WHERE t.source = 'REPLAY'
      ORDER BY t.observed_at, e.event_id;

      -- latest price per instrument
      SELECT DISTINCT ON (i.symbol) i.exchange, i.symbol, t.price, t.observed_at
      FROM price_ticks t JOIN instruments i USING (instrument_id)
      ORDER BY i.symbol, t.observed_at DESC, t.tick_id DESC;
      ```
- [ ] **55_replay-error.png** — a clear failure for an unknown instrument:
      ```sh
      printf 'offset_seconds,exchange,symbol,price,volume\n0,NSE,NOSUCH,100,1\n' > /tmp/bad.csv
      python -m app.replay /tmp/bad.csv; echo "exit=$?"
      ```
      Shows `ERROR [SW001] ingest_tick: unknown instrument NSE:NOSUCH` and
      `exit=2`.
- [ ] **56_replay-tests.png** — `python -m unittest tests.test_replay -v`
      (18 tests, OK). They use throwaway databases; stock_watchlist is not
      touched.

## Later phases (not yet available)

- [ ] _(Phase 6)_ EXPLAIN ANALYZE before/after index
- [ ] _(Phase 7)_ watchlist UI; fired-alert UI; DB Inspector; live alert via SSE
- [ ] _(Phase 9)_ SERIALIZABLE demonstration (optional)
