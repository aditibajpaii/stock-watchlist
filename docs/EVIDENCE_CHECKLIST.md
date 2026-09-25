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

- [ ] **01_er-diagram.png** — ER diagram (Mermaid from the Phase 1 spec,
      or redrawn by the report team). Must show all 7 entities, PK/FK,
      and cardinalities.

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

## Section 6 – Normal forms (2 marks)

- [ ] _(Phase 3)_ functional-dependency / normalization evidence

## Later phases (not yet available)

- [ ] _(Phase 4)_ alert trigger/function source; alert firing; rollback test
- [ ] _(Phase 6)_ EXPLAIN ANALYZE before/after index
- [ ] _(Phase 7)_ watchlist UI; fired-alert UI; DB Inspector
- [ ] _(Phase 9)_ concurrency demo (optional)
