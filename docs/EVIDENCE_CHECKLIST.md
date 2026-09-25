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
- [ ] _(Phase 4)_ **28_no-duplication-join.png** — alert_events joined
      to price_ticks and instruments, showing price, time and symbol are
      obtained via tick_id, not stored twice. This needs real alert
      events, so it comes in Phase 4.

## Marks → evidence map

| Marks | Minimum evidence | Strong extra evidence |
|---|---|---|
| ER Diagram (3) | 01 | 01b, 01c |
| Tables + description + screenshots (5) | 03, 04, 05a–11a (CREATE TABLE ×7), 05b–11b (`\d` ×7) | 02, 12, 13, 14–16, 17, 18–22 |
| Normal forms (2) | 27 (FD/NF table from notes), 24 | 23, 25, 26, 28 |

## Later phases (not yet available)

- [ ] _(Phase 4)_ alert trigger/function source; alert firing; rollback test
- [ ] _(Phase 6)_ EXPLAIN ANALYZE before/after index
- [ ] _(Phase 7)_ watchlist UI; fired-alert UI; DB Inspector
- [ ] _(Phase 9)_ concurrency demo (optional)
