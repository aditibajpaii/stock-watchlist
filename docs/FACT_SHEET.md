# Fact Sheet (for the report team)

Factual notes only. Not report text — write your own sentences.
Every value below was taken from the running database or from the SQL
files. Status: **Phase 6 (indexing + benchmark) complete**. Items
marked _(later phase)_ do not exist yet.

---

## Project

- Title: Real-Time Stock Market Watchlist & Alert System
- Course: BCSE302P – Database Systems Lab
- Faculty: Dr. Anand Bihari
- Domain: stock (NSE) watchlists + price-crossing alerts; crypto (Binance)
  only as a 24/7 demo data source
- Not in scope: trading/orders, portfolio accounting, price prediction

## Software actually used (so far)

| Item | Version / detail |
|---|---|
| DBMS | PostgreSQL 18.6 (Homebrew), aarch64-apple-darwin |
| Client | psql 18.6 |
| OS | macOS (Apple Silicon) |
| Database name | `stock_watchlist` |
| Server time zone | Asia/Kolkata |
| Default isolation level | READ COMMITTED |
| Python | 3.13.15 (project virtual environment `.venv/`) |
| Database driver | psycopg 3.3.6 (`psycopg[binary]`, bundled libpq 18.0.6) |
| Python test framework | unittest (standard library, no extra dependency) |
| Backend / frontend | _(later phase)_ FastAPI; HTML/CSS/JS |

## Tables (7)

users, instruments, watchlists, watchlist_items, price_ticks,
alert_rules, alert_events

### users
| Column | Type | Null | Default |
|---|---|---|---|
| user_id | BIGINT | NOT NULL | identity (ALWAYS) |
| username | TEXT | NOT NULL | – |
| email | TEXT | NOT NULL | – |
| created_at | TIMESTAMPTZ | NOT NULL | now() |

- PK: `pk_users` (user_id)
- UNIQUE: `uq_users_username` (username); `uq_users_email` (email)
- CHECK: `ck_users_username_format` — lowercase letters/digits/underscore, 3–30 chars
- CHECK: `ck_users_email_format` — lowercase, contains `_@_`
- Candidate keys: {user_id}, {username}, {email}

### instruments
| Column | Type | Null | Default |
|---|---|---|---|
| instrument_id | BIGINT | NOT NULL | identity (ALWAYS) |
| exchange | TEXT | NOT NULL | – |
| symbol | TEXT | NOT NULL | – |
| name | TEXT | NOT NULL | – |
| quote_currency | TEXT | NOT NULL | – |
| is_active | BOOLEAN | NOT NULL | true |

- PK: `pk_instruments` (instrument_id)
- UNIQUE: `uq_instruments_exchange_symbol` (exchange, symbol)
- CHECK: `ck_instruments_exchange` — IN ('NSE','BSE','BINANCE')
- CHECK: `ck_instruments_symbol_format` — `^[A-Z0-9&._-]{1,20}$`
- CHECK: `ck_instruments_name_not_blank`
- CHECK: `ck_instruments_quote_currency` — `^[A-Z]{3,5}$`
- Candidate keys: {instrument_id}, {exchange, symbol}
- Deliberately no asset_class column (exchange → asset_class would be a
  transitive dependency)

### watchlists
| Column | Type | Null | Default |
|---|---|---|---|
| watchlist_id | BIGINT | NOT NULL | identity (ALWAYS) |
| user_id | BIGINT | NOT NULL | – |
| name | TEXT | NOT NULL | – |
| created_at | TIMESTAMPTZ | NOT NULL | now() |

- PK: `pk_watchlists` (watchlist_id)
- FK: `fk_watchlists_user` → users(user_id) ON DELETE CASCADE
- UNIQUE: `uq_watchlists_user_name` (user_id, name)
- CHECK: `ck_watchlists_name` — not blank, ≤ 50 chars
- Candidate keys: {watchlist_id}, {user_id, name}

### watchlist_items
| Column | Type | Null | Default |
|---|---|---|---|
| watchlist_id | BIGINT | NOT NULL | – |
| instrument_id | BIGINT | NOT NULL | – |
| added_at | TIMESTAMPTZ | NOT NULL | now() |

- PK: `pk_watchlist_items` (watchlist_id, instrument_id) — composite
- FK: `fk_watchlist_items_watchlist` → watchlists ON DELETE CASCADE
- FK: `fk_watchlist_items_instrument` → instruments ON DELETE RESTRICT
- Candidate key: {watchlist_id, instrument_id}
- Role: associative (junction) table resolving watchlists M:N instruments

### price_ticks
| Column | Type | Null | Default |
|---|---|---|---|
| tick_id | BIGINT | NOT NULL | identity (ALWAYS) |
| instrument_id | BIGINT | NOT NULL | – |
| observed_at | TIMESTAMPTZ | NOT NULL | – |
| price | NUMERIC(18,8) | NOT NULL | – |
| volume | NUMERIC(24,8) | **NULL** | – (no default) |
| source | TEXT | NOT NULL | – |
| source_event_id | TEXT | NOT NULL | – |
| ingested_at | TIMESTAMPTZ | NOT NULL | now() |

- PK: `pk_price_ticks` (tick_id) — surrogate
- FK: `fk_price_ticks_instrument` → instruments ON DELETE RESTRICT
- UNIQUE: `uq_price_ticks_source_event` (source, instrument_id, source_event_id)
- CHECK: `ck_price_ticks_price_pos` — price > 0
- CHECK: `ck_price_ticks_volume_nonneg` — volume IS NULL OR volume >= 0
- CHECK: `ck_price_ticks_source` — IN ('REPLAY','BINANCE','MANUAL')
- CHECK: `ck_price_ticks_source_event_not_blank`
- Candidate keys: {tick_id}, {source, instrument_id, source_event_id}
- NOT unique: (instrument_id, observed_at) — two real ticks may share a timestamp
- observed_at = market time; ingested_at = time the DB received it
- volume NULL = unknown; 0 = known zero

### alert_rules
| Column | Type | Null | Default |
|---|---|---|---|
| rule_id | BIGINT | NOT NULL | identity (ALWAYS) |
| user_id | BIGINT | NOT NULL | – |
| instrument_id | BIGINT | NOT NULL | – |
| direction | TEXT | NOT NULL | – |
| threshold | NUMERIC(18,8) | NOT NULL | – |
| cooldown_seconds | INTEGER | NOT NULL | 300 |
| is_active | BOOLEAN | NOT NULL | true |
| created_at | TIMESTAMPTZ | NOT NULL | now() |

- PK: `pk_alert_rules` (rule_id)
- FK: `fk_alert_rules_user` → users ON DELETE CASCADE
- FK: `fk_alert_rules_instrument` → instruments ON DELETE RESTRICT
- UNIQUE: `uq_alert_rules_definition` (user_id, instrument_id, direction, threshold)
- CHECK: `ck_alert_rules_direction` — IN ('ABOVE','BELOW')
- CHECK: `ck_alert_rules_threshold_pos` — threshold > 0
- CHECK: `ck_alert_rules_cooldown_nonneg` — cooldown_seconds >= 0 (no maximum)
- Candidate keys: {rule_id}, {user_id, instrument_id, direction, threshold}
- Design rule (not DB-enforced): user_id, instrument_id, direction,
  threshold never change after creation; only is_active and
  cooldown_seconds change

### alert_events
| Column | Type | Null | Default |
|---|---|---|---|
| event_id | BIGINT | NOT NULL | identity (ALWAYS) |
| rule_id | BIGINT | NOT NULL | – |
| tick_id | BIGINT | NOT NULL | – |
| fired_at | TIMESTAMPTZ | NOT NULL | now() |

- PK: `pk_alert_events` (event_id)
- FK: `fk_alert_events_rule` → alert_rules ON DELETE CASCADE
- FK: `fk_alert_events_tick` → price_ticks ON DELETE RESTRICT
- UNIQUE: `uq_alert_events_rule_tick` (rule_id, tick_id)
- Candidate keys: {event_id}, {rule_id, tick_id}
- No price / observed_at / instrument_id stored — obtained via tick_id

## Constraint totals (from pg_constraint)

| Type | Count |
|---|---|
| PRIMARY KEY | 7 |
| FOREIGN KEY | 8 |
| UNIQUE | 7 |
| CHECK (named) | 14 |
| **Total named** | **36** |

(NOT NULL constraints are in addition to these.)

## Foreign keys and ON DELETE

| FK | Child → Parent | ON DELETE |
|---|---|---|
| fk_watchlists_user | watchlists → users | CASCADE |
| fk_watchlist_items_watchlist | watchlist_items → watchlists | CASCADE |
| fk_watchlist_items_instrument | watchlist_items → instruments | RESTRICT |
| fk_alert_rules_user | alert_rules → users | CASCADE |
| fk_alert_rules_instrument | alert_rules → instruments | RESTRICT |
| fk_price_ticks_instrument | price_ticks → instruments | RESTRICT |
| fk_alert_events_rule | alert_events → alert_rules | CASCADE |
| fk_alert_events_tick | alert_events → price_ticks | RESTRICT |

- Policy: CASCADE = user-owned data; RESTRICT = shared market/reference data
- Deleting a user removes: their watchlists, watchlist items, alert rules,
  alert events. Removes NO price ticks. (tested: E3–E8)
- Deleting a watchlist removes only its items. (tested: E1–E2)

## Relationships / cardinality

| Relationship | Cardinality |
|---|---|
| users – watchlists | 1 : N (watchlist has exactly 1 owner) |
| watchlists – instruments | M : N via watchlist_items |
| users – alert_rules | 1 : N |
| instruments – alert_rules | 1 : N |
| instruments – price_ticks | 1 : N |
| alert_rules – alert_events | 1 : N |
| price_ticks – alert_events | 1 : N (a rule fires at most once per tick) |

## Relationships per table (from pg_constraint)

| Table | References (parent) | Referenced by (child) |
|---|---|---|
| users | – | watchlists, alert_rules |
| instruments | – | watchlist_items, price_ticks, alert_rules |
| watchlists | users | watchlist_items |
| watchlist_items | watchlists, instruments | – |
| price_ticks | instruments | alert_events |
| alert_rules | users, instruments | alert_events |
| alert_events | alert_rules, price_ticks | – |

- All 8 relationships: 1 : 0..N; every FK column NOT NULL (child has exactly 1 parent)
- No FK column is unique on its own → no 1:1 relationships
- Derived M:N: watchlists ↔ instruments (via watchlist_items);
  alert_rules ↔ price_ticks (via alert_events, max 1 event per pair)
- Junction tables: watchlist_items, alert_events

## Functional dependencies and normal form

| Table | Non-trivial FDs | Highest NF |
|---|---|---|
| users | user_id → all; username → all; email → all | BCNF |
| instruments | instrument_id → all; (exchange, symbol) → all | BCNF |
| watchlists | watchlist_id → all; (user_id, name) → all | BCNF |
| watchlist_items | (watchlist_id, instrument_id) → added_at | BCNF |
| price_ticks | tick_id → all; (source, instrument_id, source_event_id) → all | BCNF |
| alert_rules | rule_id → all; (user_id, instrument_id, direction, threshold) → all | BCNF |
| alert_events | event_id → all; (rule_id, tick_id) → all | BCNF |

- Every determinant is a candidate key in every table
- FDs checked and found FALSE: exchange → quote_currency;
  (source, source_event_id) → instrument_id
- FD found TRUE and removed by design: exchange → asset_class (column dropped)
- Detailed analysis: docs/NORMALIZATION_NOTES.md

Composite-key partial-dependency facts:
- watchlist_items: added_at depends on BOTH watchlist_id and instrument_id
- watchlists: created_at depends on neither user_id alone nor name alone
- alert_rules: cooldown/is_active/created_at not determined by any subset
  of (user_id, instrument_id, direction, threshold)
- alert_events: fired_at not determined by rule_id alone or tick_id alone
- price_ticks: no subset of (source, instrument_id, source_event_id)
  determines observed_at/price/volume/ingested_at

Deliberately NOT stored (would break 2NF/3NF):
- watchlist_items.user_id (watchlist_id → user_id)
- alert_events.instrument_id / observed_at / price (tick_id → these)
- instruments.asset_class (exchange → asset_class)

Counterexamples accepted by the schema (rolled-back test, 2026-09-25):
- NSE RELIANCE and BSE RELIANCE both valid → symbol alone is not a key
- BINANCE BTCUSDT (USDT) and BINANCE ETHBTC (BTC) → exchange ↛ quote_currency
- same instrument + same observed_at + different event id accepted (test A10)
- same source_event_id on different instruments accepted (test A9)

## Live schema verification (Phase 3)

- Script: sql/verify_spec.sql (read-only; diffs catalog vs PHASE1_SPEC)
- Result 2026-09-25 (Phase 3): 37/37 columns match, 36/36 constraints
  match, 0 triggers, 0 functions, 0 non-constraint indexes
- Since Phase 4 the script also checks the 3 functions + 2 triggers by exact
  definition, and that no extra index exists. Result after Phase 4:
  37/37 columns, 36/36 constraints, 5/5 functions+triggers match
- Self-check: with 1 nullability change, 1 dropped CHECK and 1 extra index
  on a scratch DB, all 3 differences reported and psql exited non-zero

## Indexes (current)

15 indexes on the 7 tables: 14 created automatically by PK/UNIQUE
constraints, plus 1 performance index (Phase 6).

| Index | Table | Columns | Source |
|---|---|---|---|
| pk_* (×7) | each table | its PK | PRIMARY KEY |
| uq_users_username, uq_users_email | users | (username), (email) | UNIQUE |
| uq_instruments_exchange_symbol | instruments | (exchange, symbol) | UNIQUE |
| uq_watchlists_user_name | watchlists | (user_id, name) | UNIQUE |
| uq_price_ticks_source_event | price_ticks | (source, instrument_id, source_event_id) | UNIQUE |
| uq_alert_rules_definition | alert_rules | (user_id, instrument_id, direction, threshold) | UNIQUE |
| uq_alert_events_rule_tick | alert_events | (rule_id, tick_id) | UNIQUE |
| **ix_price_ticks_instrument_time** | price_ticks | (instrument_id, observed_at DESC, tick_id DESC) | sql/06_indexes.sql |

- ix_price_ticks_instrument_time: B-tree, not unique, not partial;
  installed on stock_watchlist 2026-09-25
- It lives in sql/06_indexes.sql, not 00_schema.sql (physical performance
  choice)
- Existing index reused for the alert cooldown lookup:
  uq_alert_events_rule_tick (leading column rule_id)
- No FK-column indexes added (no measured need)

## Index benchmark (Phase 6) — key facts

Full details: docs/INDEX_BENCHMARK.md; raw data: docs/benchmark_results/

- Throwaway DB stock_watchlist_benchmark; 500,000 rows, 20 instruments
  × 25,000 ticks
- Bulk load 7.7 s, benchmark only, with the alert trigger disabled on
  that DB only
- Warm cache; median of 7 timed runs after 2 warm-ups;
  `EXPLAIN (ANALYZE, BUFFERS)`

| Query | Before (median) | After (median) | Buffers before → after |
|---|---|---|---|
| A latest 50 ticks | 9.461 ms (Sort + bitmap via uq skip scan) | 0.020 ms (Index Scan, no Sort) | 6,371 → 16 |
| B 30-min range (900 rows) | 4.539 ms | 0.328 ms (Bitmap + Sort still chosen) | 6,371 → 228 |
| C previous tick (trigger) | 6.017 ms | 0.007 ms (Index Scan, ROW compare in Index Cond) | 6,371 → 4 |
| D watchlist latest prices | 22.880 ms | 0.030 ms | 19,122 → 15 |
| E late-tick check (trigger) | 4.274 ms | 0.004 ms (Index Only Scan) | 6,371 → 3 |
| ingest_tick with trigger (50 calls) | 30.081 ms/call | 0.199 ms/call | – |

- Inside the trigger at baseline, the late-tick check was a Seq Scan
  removing 500,001 rows (auto_explain)
- PostgreSQL 18 skip scan: at baseline the uq index was used for
  instrument_id (2nd column) with `Index Searches: 2`
- Sizes: heap 48 MB; new B-tree 19 MB; price_ticks total 100 MB → 120 MB;
  B-tree build 0.40 s
- BRIN (observed_at), tested only: 24 kB, build 0.03 s; used only for B
  (3.166 ms) and E (1.257 ms); not used for A/C/D; **not kept**
- Results identical (SHA-256) in baseline, B-tree and BRIN stages

## Seed data (01_seed.sql)

| Table | Rows |
|---|---|
| users | 3 (arjun, priya, kavya) |
| instruments | 7 (NSE: RELIANCE, TCS, INFY, HDFCBANK, M&M; BINANCE: BTCUSDT, ETHUSDT) |
| watchlists | 5 |
| watchlist_items | 11 |
| price_ticks | 0 |
| alert_rules | 6 (5 active, 1 inactive) |
| alert_events | 0 |

## Ingestion and alert engine (Phase 4, sql/03_functions_triggers.sql)

### PostgreSQL objects

| Object | Kind | Attached to | Timing |
|---|---|---|---|
| ingest_tick(p_exchange text, p_symbol text, p_observed_at timestamptz, p_price numeric, p_volume numeric, p_source text, p_source_event_id text) RETURNS TABLE(status text, tick_id bigint) | function (PL/pgSQL) | – | called by clients |
| evaluate_price_alerts() | trigger function | – | – |
| trg_price_ticks_evaluate_alerts | trigger | price_ticks | AFTER INSERT, FOR EACH ROW |
| check_alert_event_instrument() | trigger function | – | – |
| trg_alert_events_check_instrument | trigger | alert_events | BEFORE INSERT OR UPDATE OF rule_id, tick_id, FOR EACH ROW |

### ingest_tick

- Official operational insertion path (replay / Binance / manual)
- Input identifies instrument by (exchange, symbol)
- Returns 1 row: ('INSERTED', tick_id) or ('DUPLICATE', NULL)
- Unknown instrument → error SQLSTATE SW001
- Inactive instrument → error SQLSTATE SW002 (nothing stored)
- Lock: `SELECT … FROM instruments … FOR NO KEY UPDATE`, taken BEFORE the
  tick insert; held until the caller's transaction ends
- Same instrument → callers serialized; different instruments → parallel
- FOR NO KEY UPDATE does not block FK checks (they take FOR KEY SHARE)
- Duplicate handling: `INSERT … ON CONFLICT ON CONSTRAINT
  uq_price_ticks_source_event DO NOTHING RETURNING tick_id`
- Duplicate → no row inserted → alert trigger does not fire
- Isolation level: READ COMMITTED (server default); no isolation check in code

### Alert evaluation (evaluate_price_alerts, per inserted tick N)

| Step | Rule |
|---|---|
| Late tick | exists tick of same instrument with observed_at > N.observed_at → N stored, NOT evaluated |
| Equal observed_at | not late; order broken by tick_id |
| Previous tick | greatest (observed_at, tick_id) strictly below N's, same instrument |
| First tick | no previous → no alert |
| Rules evaluated | alert_rules WHERE instrument_id = N.instrument_id AND is_active |
| ABOVE fires | previous.price < threshold AND N.price >= threshold |
| BELOW fires | previous.price > threshold AND N.price <= threshold |
| Edge-triggered | staying above/below → no further events |
| Cooldown basis | observed_at of the tick behind the rule's latest event (market time; NOT fired_at) |
| Cooldown suppress | N.observed_at < last_fired_observed_at + cooldown_seconds |
| Cooldown boundary | crossing at exactly last + cooldown fires |
| Suppressed crossing | dropped, not retried |
| Event insert | `INSERT INTO alert_events (rule_id, tick_id) … ON CONFLICT ON CONSTRAINT uq_alert_events_rule_tick DO NOTHING` |
| NOTIFY | only if an event row was inserted; channel `alert_events`; payload = event_id as text |
| Rollback | tick, events and queued NOTIFY all discarded |

### Integrity trigger (check_alert_event_instrument)

- Rejects an alert_events row whose rule's instrument ≠ tick's instrument
- Error: SQLSTATE 23514 (check_violation), constraint name
  `trg_alert_events_check_instrument`
- Covers INSERT and UPDATE of rule_id / tick_id
- Missing rule/tick left to the FKs (23503)
- alert_events still has no instrument_id column

### Custom SQLSTATEs

| Code | Raised by | Meaning |
|---|---|---|
| SW001 | ingest_tick | unknown instrument (exchange, symbol) |
| SW002 | ingest_tick | instrument is inactive |
| 23514 + `trg_alert_events_check_instrument` | integrity trigger | rule/tick instrument mismatch |

## Offline replay (Phase 5, app/replay.py)

### Files

| File | Role |
|---|---|
| app/replay.py | replay CLI |
| app/config.py | DB connection from environment variables |
| data/replay_prices.csv | deterministic demo feed (30 rows) |
| data/README.md | row-by-row expected behaviour of the demo feed |
| requirements.txt | `psycopg[binary]==3.3.6` (only dependency) |
| .env.example | documents DB_NAME / DB_HOST / DB_PORT / DB_USER (no secrets) |
| tests/test_replay.py | 18 automated tests |

### Configuration

- Environment variables: DB_NAME (default `stock_watchlist`), DB_HOST,
  DB_PORT, DB_USER (unset = libpq defaults: local socket, 5432, OS user)
- No password in code or files. The local server uses trust auth; libpq's
  own PGPASSWORD / ~/.pgpass would apply if ever needed.
- The program does not read .env files; variables must be exported.

### CLI

- Entry point: `python -m app.replay <csv> [options]`

| Option | Effect |
|---|---|
| --run-id ID | reuse an earlier run id (retry); default = new UUID4 |
| --delay-ms N | real pause between events (default 0) |
| --dry-run | validate and print what would be sent; **no DB connection at all** |
| --continue-on-error | keep going after a failed event (exit code still 2) |
| --start-after-latest | new run only: start 1 s after the latest stored tick of the CSV's instruments |

- Exit codes: 0 success; 1 invalid CSV or arguments (nothing sent);
  2 database/ingestion error (incl. connection failure, late-start refusal)
- run_id allowed characters: letters, digits, `-`, `_` (max 64)

### CSV format

- Header exactly: `offset_seconds,exchange,symbol,price,volume`
- offset_seconds: integer ≥ 0, non-decreasing down the file
- price: decimal > 0 (parsed as Python Decimal, never float)
- volume: decimal ≥ 0 or blank; blank → SQL NULL
- The whole file is validated before anything is sent. Any error →
  exit 1, 0 rows sent, and every problem is listed.
- Python does not check NUMERIC precision; the database does
  (e.g. 999999999999 → SQLSTATE 22003).

### Identity and time

- source = 'REPLAY'
- source_event_id = `<run_id>:<row_no as 6 digits>` (row 1 = first data row)
- New run: run_start = current time truncated to whole seconds (UTC stored,
  printed in IST)
- observed_at = run_start + offset_seconds
- Real waiting (--delay-ms) is independent of offset_seconds
- Retry (--run-id of an existing run): run_start recovered as
  observed_at(row 1) − offset(row 1), using an exact lookup on the unique
  key (source, instrument, source_event_id). The id is never parsed.
  - Result: already-stored rows → DUPLICATE; missing rows continue on the
    original timeline.
- Late-start guard (new run only): if the CSV's instruments already have a
  tick with observed_at ≥ run_start → refuse (exit 2) with an explanation,
  unless --start-after-latest.
  - Reason: those ticks would be classified late and no alerts would fire.

### Transaction policy

- Autocommit connection. Each event runs in its own explicit transaction
  (`conn.transaction()`) containing:
  1. `SELECT status, tick_id FROM ingest_tick(...)`
  2. a read of the alert_events created for that tick (for printing)
  3. COMMIT
- ingest_tick's instrument lock is held only for that one short transaction
- Each tick and its alerts are visible, and the NOTIFY delivered, right
  after each event commits
- Failed event → that transaction rolls back and the error is printed with
  its SQLSTATE. Default: stop (later rows not sent), exit 2. Earlier
  committed rows remain.
- Never INSERTs into price_ticks directly

### Demo feed facts (data/replay_prices.csv)

- 30 rows; RELIANCE 12, TCS 6, BTCUSDT 8, ETHUSDT 2, INFY 2
- 8 rows have blank volume
- Logical span 460 s
- On a freshly seeded DB one run creates **8 alert events**:

| Row | Tick | Rule |
|---|---|---|
| 6 | RELIANCE 2994.00 → 3002.40 | 1 arjun ABOVE 3000 |
| 9 | TCS 3531.25 → 3498.00 | 4 priya BELOW 3500 |
| 10 | BTCUSDT 99880 → 100120 | 3 arjun ABOVE 100000 |
| 18 | ETHUSDT 3048.10 → 2994.60 | 6 kavya BELOW 3000 |
| 20 | TCS 3512.00 → 3490.00 | 4 priya BELOW 3500 |
| 22 | BTCUSDT 99800 → 100400 | 3 arjun ABOVE 100000 |
| 27 | RELIANCE 2990.00 → 3021.50 | 1 arjun ABOVE 3000 |
| 29 | RELIANCE 3030.00 → 2795.00 | 2 arjun BELOW 2800 |

- No event, by design:
  - staying beyond a threshold: rows 8, 11, 12, 14, 28, 30
  - crossing inside cooldown: row 16 (BTC), row 23 (RELIANCE)
  - inactive rule 5: row 26 (INFY)
- A second new run straight after (with --start-after-latest) creates 7:
  row 6 falls inside rule 1's cooldown carried over from the previous run.

### Observed demonstration (throwaway DB, 2026-09-25)

| Run | Command | Result |
|---|---|---|
| 1 | --run-id run-X | 30 INSERTED, 8 alerts |
| 2 | --run-id run-X again | 30 DUPLICATE, 0 inserted, 0 alerts |
| 3 | --run-id run-Y immediately | refused, exit 2 (late-start guard) |
| 4 | --run-id run-Y --start-after-latest | 30 INSERTED, 7 alerts |

## Build / run order

1. sql/00_schema.sql
2. sql/01_seed.sql
3. sql/03_functions_triggers.sql
3b. sql/06_indexes.sql
4. SQL tests: sql/02_schema_tests.sql, sql/verify_spec.sql,
   sql/04_alert_tests.sql, tests/concurrency_test.sh
5. Python: `python3.13 -m venv .venv`,
   `.venv/bin/pip install -r requirements.txt`,
   `python -m unittest tests.test_replay -v`,
   `python -m unittest tests.test_indexes -v`
5b. benchmark (throwaway DB): `python tests/benchmark_indexes.py`, then
   `psql -d stock_watchlist_benchmark -f sql/07_benchmark_queries.sql`
6. demo: `python -m app.replay data/replay_prices.csv --delay-ms 300`,
   then `sql/05_demo_queries.sql` (rolled back)

## Tests executed

All results 2026-09-25, PostgreSQL 18.6, after a clean rebuild (00 → 01 → 03).

| Suite | File | Result |
|---|---|---|
| Schema constraints (Phase 2) | sql/02_schema_tests.sql | **51 / 51 PASS** |
| Live schema vs spec (Phase 3) | sql/verify_spec.sql | **MATCH** (37 columns, 36 constraints, 5 functions/triggers) |
| Alert engine (Phase 4) | sql/04_alert_tests.sql | **50 / 50 PASS** |
| Multi-session concurrency + NOTIFY (Phase 4) | tests/concurrency_test.sh | **17 / 17 PASS** (3 consecutive runs) |
| Python replay (Phase 5) | tests/test_replay.py | **18 / 18 PASS** (unittest) |
| Index definition + planner (Phase 6) | tests/test_indexes.py | **15 / 15 PASS** |

Re-run after Phase 6 with the index installed (2026-09-25): 02 → 51/51,
verify_spec → MATCH (37 columns, 36 constraints, 6 functions/triggers/
indexes), 04 → 50/50, concurrency → 17/17, replay → 18/18, index → 15/15;
05 demo OK; replay smoke on a production build (00+01+03+06) → 30
inserted, 8 alerts.

Re-run after Phase 5 (2026-09-25): 02 → 51/51, verify_spec → MATCH,
04 → 50/50, concurrency → 17/17, replay → 18/18.
Dev database afterwards: still pure seed data (3/7/5/11/0/6/0).

Phase 2 schema tests:
- Groups: A unique (12), B check (16), C foreign key (8), D restrict (5),
  E cascade (10)
- Each negative test checks the exact SQLSTATE AND constraint name
- Runs in one transaction, rolled back → seed unchanged
- Harness self-check: CHECK + CASCADE deliberately broken on scratch DB →
  7 FAIL, non-zero exit
- Phase 4 change: fixture's manual alert_events insert got
  `ON CONFLICT … DO NOTHING` (trigger now creates that event itself);
  no assertion changed
- Phase 5 change: E6 now checks that arjun's former rules have 0 events
  AND other users' events are all kept. Before, it required
  alert_events to be empty, which fails on a DB holding replay data.
  Test 15 of test_replay.py runs 02 on a replayed DB.

Phase 4 alert tests (50 checks) cover:
- first tick; ABOVE crossing 2990→2999→3001; staying above; re-cross after
  cooldown; BELOW crossing; staying below; ABOVE/BELOW equality; cooldown
  suppression, retry-free suppression, after-cooldown, exact boundary;
  cooldown uses observed_at; duplicate source event; same observed_at;
  late tick; wrong-instrument INSERT and UPDATE; inactive rule; inactive
  and unknown instrument; top-level and savepoint rollback; manual
  duplicate alert_event; one tick firing 3 rules; global consistency
- Test instruments/users/rules created inside a rolled-back transaction
- Mutation self-check on scratch DB:
  - level-triggered bug → 5 FAIL
  - late-tick check removed → 3 FAIL
  - integrity trigger dropped → 2 FAIL

Phase 5 replay tests (18, each on a fresh DB cloned from a template
built from 00 + 01 + 03; dev DB untouched):

| # | Test |
|---|---|
| 01 | demo CSV parses: 30 rows, Decimal prices, row numbers 1–30 |
| 02 | blank volume → None → stored NULL (8 rows) |
| 03 | invalid price abc / -5 / 0 / NaN / blank → exit 1, 0 ticks |
| 04 | missing symbol/exchange/offset, bad offset, negative volume, backwards offset, extra value, wrong header → exit 1, 0 ticks |
| 05 | new run: 30 inserted, ids `<run>:000001…000030` |
| 05b | observed_at = run_start + offset for every row; whole-second start |
| 06 | same run_id again: 30 DUPLICATE, data unchanged, still 8 events |
| 06b | interrupted run (rows 1–10) retried with full file: 10 DUPLICATE + 20 INSERTED on one continuous timeline; same 8 events |
| 07 | new run_id immediately: refused (exit 2, nothing sent); with --start-after-latest: 30 inserted, starts 1 s after previous run, 7 events |
| 08 | exact (rule, row) set of the 8 expected events |
| 09 | no events on "stay beyond" / cooldown rows; rule 1 has 2; inactive rule 5 has 0 |
| 10 | per-instrument tick counts; tick order per instrument = CSV order; every event rule/tick same instrument |
| 11 | --dry-run: 30 "would send" lines, 0 ticks; works with a non-existent DB name |
| 12 | unknown instrument at row 2: [SW001], exit 2, row 1 kept, row 3 not sent |
| 12b | same via real subprocess CLI: exit code 2 |
| 13 | inactive instrument: [SW002], exit 2, 0 ticks |
| 14 | DB error (price overflow 22003) at row 2: only row 1 stored; with --continue-on-error row 3 stored and fires alert, exit still 2 |
| 15 | after a replay, 04_alert_tests.sql (50/50) and 02_schema_tests.sql (51/51) pass on the same DB; replay data untouched |

Phase 6 index tests (15):

| # | Test |
|---|---|
| 01–05 | dev DB (read-only): index exists; on price_ticks; btree, not unique, not partial, no expressions; column order (instrument_id, observed_at, tick_id); indoption [0,3,3] = ASC, DESC, DESC; exact definition; it is the only non-constraint index |
| 06 | dev DB: verify_spec.sql passes (tables/constraints unchanged) |
| 07 | throwaway DB (60k rows): latest-N uses ix, no Sort, no Seq Scan |
| 08 | previous-tick: ix with `ROW(observed_at, tick_id) <` in Index Cond, no Sort |
| 09 | late-tick check uses ix, no Seq Scan |
| 10 | time range uses ix (Index or Bitmap Index Scan), no Seq Scan |
| 11 | watchlist latest-price LATERAL uses ix |
| 12 | auto_explain on a real ingest_tick: both trigger queries use ix |
| 13 | control: with ix dropped (rolled back) latest-N has a Sort and no ix; all query results identical |
| 14 | a crossing via ingest_tick still creates exactly 1 alert |
| 15 | verifier: extra index → EXTRA + non-zero exit; dropped ix → MISSING; restored → passes |

Concurrency test (separate psql processes on throwaway DB
stock_watchlist_ctest, dropped afterwards):

| Scenario | Observed |
|---|---|
| 1 A holds RELIANCE lock 3 s, B ingests same instrument | B blocked ≈ 2.0 s; pg_blocking_pids shows B blocked by A; wait_event Lock:transactionid; order base < A < B; B's previous = A; exactly 1 alert (on A) |
| 2 CONTROL: same race via direct INSERT (no lock) | B not blocked (≈ 0.01 s); **2 alerts for 1 crossing** → proves the race is real and the lock prevents it |
| 3 A holds ETHUSDT lock; B has older observed_at | B blocked ≈ 2.0 s, then classified late: stored, no event; exactly 1 alert |
| 4 LISTEN session + committed crossing + rolled-back crossing + duplicate | exactly 1 notification, payload = committed event_id; rolled-back crossing left 0 ticks / 0 events |

## Not yet implemented

- web app + SSE _(Phase 7)_, Binance _(Phase 8)_
