# Screenshot guide — tables and constraints

Covers the Review 1 criterion "Table creation with description and screenshot" (which Review 1 lacked)
and Review 2 checklist item 1 "CREATE TABLE scripts + all constraints". Every screenshot must show real
SQL or real database output from your own terminal. **All items are PENDING MANUAL CAPTURE.**

## Setup (once per session)

```sh
cd "/Users/aditi/dbms project"
source .venv/bin/activate
export PATH="/opt/homebrew/opt/postgresql@18/bin:$PATH"
bash scripts/review2_sandbox.sh          # (re)builds stock_watchlist_review2_sandbox; ~1 minute
```

All commands below use the sandbox. The schema there is built from the same `sql/00_schema.sql` as the
classroom database, and `sql/verify_spec.sql` reports `LIVE SCHEMA MATCHES` for both. Use a terminal
about 160 columns wide with a readable font, so psql output does not wrap.

## A. The CREATE TABLE statements as written (source of truth)

Open `sql/00_schema.sql` in VS Code (line numbers visible) and take one screenshot per table, or print
each statement in the terminal:

| Table | Lines in sql/00_schema.sql | Terminal command |
|---|---|---|
| users | 14–27 | `sed -n '14,27p' sql/00_schema.sql` |
| instruments | 32–50 | `sed -n '32,50p' sql/00_schema.sql` |
| watchlists | 55–67 | `sed -n '55,67p' sql/00_schema.sql` |
| watchlist_items | 72–82 | `sed -n '72,82p' sql/00_schema.sql` |
| price_ticks | 87–110 | `sed -n '87,110p' sql/00_schema.sql` |
| alert_rules | 115–138 | `sed -n '115,138p' sql/00_schema.sql` |
| alert_events | 143–155 | `sed -n '143,155p' sql/00_schema.sql` |

(The line numbers were read from the file on 2026-10-13. If the file changes, find the lines with
`grep -n "^CREATE TABLE\|^);" sql/00_schema.sql`.)

## B. The same tables as PostgreSQL stores them (proof the DDL really ran)

1. `\d` for each table: columns, types, nullability, defaults, indexes, check and foreign-key constraints,
   and which tables reference it:

   ```sh
   psql -d stock_watchlist_review2_sandbox -c '\d users'
   psql -d stock_watchlist_review2_sandbox -c '\d instruments'
   psql -d stock_watchlist_review2_sandbox -c '\d watchlists'
   psql -d stock_watchlist_review2_sandbox -c '\d watchlist_items'
   psql -d stock_watchlist_review2_sandbox -c '\d price_ticks'
   psql -d stock_watchlist_review2_sandbox -c '\d alert_rules'
   psql -d stock_watchlist_review2_sandbox -c '\d alert_events'
   ```

2. Optional: the CREATE TABLE that PostgreSQL rebuilds from its catalog (example for watchlists; replace
   the table name for the others):

   ```sh
   pg_dump --schema-only --no-owner --no-privileges --table=public.watchlists stock_watchlist_review2_sandbox \
     | grep -v -e '^--' -e '^SET' -e '^SELECT pg_catalog' -e '^\\' -e '^$'
   ```

## C. All keys and constraints in one place

```sh
psql -d stock_watchlist_review2_sandbox -f sql/inspect_schema.sql
```

Screenshot these sections:

| Section printed | Shows | Supports |
|---|---|---|
| `Constraints (PK / FK / UNIQUE / CHECK)` | all 36 named constraints with definitions: 7 PK, 7 UNIQUE, 8 FK, 14 CHECK | primary keys, alternate keys, CHECKs |
| `Foreign keys and ON DELETE actions` | the 8 FKs: 4 CASCADE, 4 RESTRICT | referential actions |
| `Columns (all 7 tables)` | every column's type, nullability, default | NOT NULL, defaults |

## D. The four composite alternate keys, and proof that constraints reject bad data

```sh
psql -d stock_watchlist_review2_sandbox -f sql/review2/03_constraints.sql
```

The first table printed lists `uq_instruments_exchange_symbol UNIQUE (exchange, symbol)`,
`uq_watchlists_user_name UNIQUE (user_id, name)`,
`uq_price_ticks_source_event UNIQUE (source, instrument_id, source_event_id)`,
`uq_alert_events_rule_tick UNIQUE (rule_id, tick_id)` and `pk_watchlist_items`. After it, each
`>>> EXPECTED ERROR` block shows a real rejection. Screenshot at least:
- duplicate NSE RELIANCE → 23505, followed by BSE RELIANCE accepted (the key is the pair);
- arjun's second "Crypto" → 23505, followed by priya's "Crypto" accepted;
- replayed event `r2demo:000006` → 23505, and `ingest_tick` returning `DUPLICATE` for the same event;
- rule 1 on tick 6 again → 23505;
- watchlist for user 999 → 23503 (foreign key);
- price −5 → 23514, direction 'SIDEWAYS' → 23514 (CHECK);
- NULL email → 23502 (NOT NULL);
- explicit user_id → 428C9 (identity column);
- deleting RELIANCE → 23001 (ON DELETE RESTRICT).

Everything runs in one transaction that is rolled back; the counts printed at the end show nothing changed.

## E. ON DELETE CASCADE in action

```sh
psql -d stock_watchlist_review2_sandbox -f sql/review2/02_dml.sql
```

Screenshot step "3b": user `dml_demo` owns 1 watchlist, 1 item and 1 rule. `DELETE FROM users` removes
all of them (`dml_demo_rows_left = 0`). The final row counts equal the starting counts.

## F. DDL matches the design document and the catalog

```sh
psql -d stock_watchlist_review2_sandbox -v ON_ERROR_STOP=1 -f sql/verify_spec.sql
```

The last NOTICE line must read
`LIVE SCHEMA MATCHES docs/SCHEMA_DESIGN.md (tables, constraints, functions/triggers, index)`.
The same check against the classroom database runs inside `bash scripts/run_all_tests.sh` and is
read-only.

## What to write under each screenshot

Use `TABLE_CONSTRAINT_INVENTORY.md`: per table it gives the purpose, columns, keys, foreign keys,
CHECKs, ON DELETE and normal form, all read from the catalog. The report text itself is yours to write.
