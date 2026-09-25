# Fact Sheet (for the report team)

Factual notes only. Not report text — write your own sentences.
Every value below was taken from the running database or from the SQL
files. Status: **Phase 3 (normalization + ER evidence) complete**. Items
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
| Python (installed, not yet used) | 3.13.15 |
| Backend / frontend | _(later phase)_ FastAPI + psycopg 3; HTML/CSS/JS |

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
- Result 2026-09-25: 37/37 columns match, 36/36 constraints match,
  0 triggers, 0 functions, 0 non-constraint indexes
- Self-check: with 1 nullability change, 1 dropped CHECK and 1 extra index
  on a scratch DB, all 3 differences reported and psql exited non-zero

## Indexes (current)

Only indexes created automatically by PK/UNIQUE constraints (14):
pk_* on all 7 tables; uq_users_username, uq_users_email,
uq_instruments_exchange_symbol, uq_watchlists_user_name,
uq_price_ticks_source_event, uq_alert_rules_definition,
uq_alert_events_rule_tick.

- Planned (not created): price_ticks (instrument_id, observed_at DESC,
  tick_id DESC) _(Phase 6)_

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

## Tests executed

- File: sql/02_schema_tests.sql
- Result (2026-09-25, PostgreSQL 18.6): **51 / 51 PASS**
- Groups: A unique (12), B check (16), C foreign key (8),
  D restrict (5), E cascade (10)
- Each negative test checks the exact SQLSTATE AND constraint name
- Runs inside one transaction, rolled back → seed unchanged afterwards
- Harness self-check: with a CHECK and a CASCADE deliberately broken on a
  scratch DB, 7 tests reported FAIL and psql exited non-zero

## Not yet implemented

- ingest_tick function, alert trigger, alert_events integrity trigger,
  pg_notify _(Phase 4)_
- replay _(Phase 5)_, index benchmark _(Phase 6)_, web app _(Phase 7)_,
  Binance _(Phase 8)_
