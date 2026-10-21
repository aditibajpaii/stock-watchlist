# AGENTS.md — Real-Time Stock Market Watchlist & Alert System

One-file guide for any AI coding agent (or human) working in this repo.
The authoritative instructions are in `CLAUDE.md`; detailed docs are in
`docs/`. If anything here disagrees with `CLAUDE.md`, `CLAUDE.md` wins.

---

## 1. What this project is

- **Course:** BCSE302P – Database Systems Lab (Faculty: Dr. Anand Bihari)
- **Project:** Real-Time Stock Market Watchlist & Alert System
- **Status:** feature-complete and **frozen** after Phase 10. No new
  tables or features. Only fixes, docs and run/config help.
- One student builds the whole technical project and must defend every
  design decision in a viva. Teammates write the report from factual
  notes (`docs/FACT_SHEET.md`).
- **Scope:** watchlists + ABOVE/BELOW price-crossing alerts. It is NOT a
  brokerage, portfolio tracker, trading engine, predictor or TradingView
  clone.
- **Marks:** ER diagram 3 · table creation + descriptions + screenshots 5
  · normal forms 2. Schema quality and evidence matter more than UI.

## 2. Architecture

```
Browser (plain HTML/CSS/JS)  →  FastAPI (app/main.py)  →  PostgreSQL 18
                                                            ├─ 7 tables, 36 named constraints
CSV replay     app/replay.py     ─┐                         ├─ ingest_tick() (lock, dedupe)
Binance live   app/live_feed.py  ─┴→ ingest_tick() ────────→├─ alert trigger → alert_events
                (optional)                                  └─ ix_price_ticks_instrument_time
```

All data rules live in PostgreSQL (constraints, `ingest_tick()`,
triggers, index). Python/JS only send requests and display results.

## 3. Technology stack (locked — do not change)

| Layer | Choice |
|---|---|
| Database | PostgreSQL 18 |
| Backend | Python + FastAPI + Uvicorn |
| Driver | psycopg 3, direct parameterized SQL (**no ORM**) |
| Frontend | plain HTML + CSS + vanilla JS (no framework, npm or CDN) |
| Realtime | 5 s "Live refresh" polling in UI; pg_notify carries event_id |
| Live data | Binance public aggTrade WebSocket (optional, no API key) |

Pinned Python packages (`requirements.txt`): psycopg[binary] 3.3.6,
fastapi 0.141.1, uvicorn[standard] 0.54.0, websockets 17.1, httpx 0.28.1.

**Never introduce:** React, Next.js, Node backend, SQLAlchemy, MongoDB,
Redis, Docker, microservices, Kubernetes, ML, trading/order execution,
Kafka/Flink, TimescaleDB.

## 4. Repository layout

```
app/            config.py (DB env vars) · db.py (per-request connection)
                errors.py (SQLSTATE+constraint → HTTP) · schemas.py (Pydantic)
                main.py (FastAPI, 18 endpoints + GET / for UI)
                replay.py (CSV replay feed) · live_feed.py (Binance feed)
app/static/     index.html · styles.css · api.js · app.js
data/           replay_prices.csv (30 rows) + README.md (expected behaviour)
sql/            00_schema.sql        7 tables + constraints (drops & recreates)
                01_seed.sql          demo data
                02_schema_tests.sql  51 constraint tests (rolled back)
                03_functions_triggers.sql  ingest_tick + 2 triggers
                04_alert_tests.sql   50 alert-engine tests (rolled back)
                05_demo_queries.sql  demo SELECTs
                06_indexes.sql       ix_price_ticks_instrument_time
                07_benchmark_queries.sql  EXPLAIN ANALYZE queries
                08_inspect_live.sql  read-only DB inspector
                inspect_schema.sql · verify_spec.sql
scripts/        reset_demo_db.sh · run_all_tests.sh
tests/          concurrency_test.sh · test_replay/indexes/api/frontend/live_feed.py
                benchmark_indexes.py (500k-row benchmark, separate)
docs/           PHASE1_SPEC, ER_DIAGRAM, NORMALIZATION_NOTES, INDEX_BENCHMARK,
                API, FRONTEND, LIVE_FEED, DEMO_GUIDE, FACT_SHEET,
                EVIDENCE_CHECKLIST, VIVA_NOTES, RUBRIC, RESEARCH_BRIEF,
                benchmark_results/
```

## 5. Database design (approved — do not change silently)

### Tables (7, all BCNF)

| Table | Purpose / key points |
|---|---|
| `users` | demo users (no login); UNIQUE username, UNIQUE email |
| `instruments` | UNIQUE (exchange, symbol); **no asset_class column** (exchange → asset_class would break 3NF) |
| `watchlists` | named lists per user; UNIQUE (user_id, name) |
| `watchlist_items` | PK (watchlist_id, instrument_id) |
| `price_ticks` | surrogate PK tick_id; `observed_at` TIMESTAMPTZ (market time); `ingested_at` DEFAULT now(); `source` IN ('REPLAY','BINANCE','MANUAL'); `source_event_id` NOT NULL; UNIQUE (source, instrument_id, source_event_id); `volume` NUMERIC(24,8) NULLABLE, ≥ 0, no default |
| `alert_rules` | direction ABOVE/BELOW, threshold > 0, cooldown_seconds ≥ 0, is_active; UNIQUE (user_id, instrument_id, direction, threshold). Definition immutable by design rule: disable + recreate instead of editing |
| `alert_events` | **only** (event_id, rule_id, tick_id, fired_at); UNIQUE (rule_id, tick_id). Never copy instrument/price/time into it |

- Prices are NUMERIC (never FLOAT); timestamps TIMESTAMPTZ.
- 36 named constraints = 7 PK + 8 FK + 7 UNIQUE + 14 CHECK.
- Deliberately absent: `alert_state` table (provisional decision),
  `latest_price` table (latest price comes from price_ticks), and
  UNIQUE (instrument_id, observed_at) (timestamps are not identity).

### ON DELETE policy

- **CASCADE** (user-owned data): users → watchlists, watchlists →
  watchlist_items, users → alert_rules, alert_rules → alert_events.
- **RESTRICT** (shared market data): instruments → price_ticks,
  instruments → watchlist_items, instruments → alert_rules,
  price_ticks → alert_events.
- Deleting a watchlist never deletes price history. price_ticks is
  append-only by design rule. UI disables rules rather than deleting.

### Ingestion + alert engine (`sql/03_functions_triggers.sql`)

- **`ingest_tick(...)`** is the only operational insert path (REPLAY,
  BINANCE, MANUAL). It locks the instrument row first, inserts one tick
  with ON CONFLICT DO NOTHING on the source identity, returns tick_id or
  a duplicate result. Custom errors: `SW001` unknown instrument, `SW002`
  inactive instrument.
- **`trg_price_ticks_evaluate_alerts`** (AFTER INSERT, per row) →
  `evaluate_price_alerts()`. Only rules on the same instrument.
  - Tick order = (observed_at, tick_id). Late ticks stored, not evaluated.
  - Edge-triggered: ABOVE fires when prev < T AND new ≥ T; BELOW when
    prev > T AND new ≤ T. First tick never fires (no previous price).
  - Cooldown measured in tick time (observed_at).
  - After an event is inserted, `pg_notify` sends only the event_id.
- **`trg_alert_events_check_instrument`** (BEFORE INSERT/UPDATE) rejects
  an event whose rule and tick belong to different instruments.
- Normal ingestion runs under READ COMMITTED.

### Indexes

- 14 from PK/UNIQUE + one performance index
  `ix_price_ticks_instrument_time (instrument_id, observed_at DESC, tick_id DESC)`
  in `sql/06_indexes.sql` (never in 00_schema.sql). B-tree kept; BRIN only
  compared in the benchmark (500k rows, `docs/INDEX_BENCHMARK.md`).

### Feeds

- **Replay:** `source_event_id = '<run_id>:<row_no>'`; timestamps rebased
  to replay start; re-running the same run_id is idempotent (0 inserted,
  30 duplicates). A new run on the same data is refused until reset.
- **Binance:** `source_event_id = 'aggTrade:<a>'`, observed_at = trade
  time T, no throttling, public market data only. Refuses to start after
  a replay (replay ticks are stamped up to ~7m40s in the future).
- One active feed per instrument at a time.

## 6. Seed data (clean state)

3 users (arjun, priya, kavya) · 7 instruments (5 NSE: RELIANCE, TCS,
INFY, HDFCBANK, M&M; 2 BINANCE: BTCUSDT, ETHUSDT) · 5 watchlists · 11
items · 6 rules (5 active) · 0 ticks · 0 events. Reset check line:
`3|7|5|11|6|0|0`.

Rules: #1 arjun RELIANCE ABOVE 3000 (300 s) · #2 arjun RELIANCE BELOW
2800 (300 s) · #3 arjun BTCUSDT ABOVE 100000 (60 s) · #4 priya TCS BELOW
3500 (0 s) · #5 priya INFY ABOVE 1600 (DISABLED) · #6 kavya ETHUSDT BELOW
3000 (120 s).

Replay on a clean DB (`--run-id demo1`): 30 inserted, 8 alerts.

## 7. API (FastAPI, `docs/API.md`)

`GET /health` · `GET /users`, `/users/{id}` · `GET /instruments`,
`/instruments/{id}`, `/instruments/{id}/latest`, `/instruments/{id}/history`
· `GET|POST /users/{id}/watchlists` · `DELETE /watchlists/{id}` ·
`POST /watchlists/{id}/items` · `DELETE /watchlists/{id}/items/{instrument_id}`
· `GET|POST /users/{id}/alert-rules` · `PATCH|DELETE /alert-rules/{id}`
(PATCH only is_active / cooldown_seconds) · `GET /users/{id}/alerts` ·
`POST /ticks/ingest` (dev/demo, calls ingest_tick with 'MANUAL').
Errors are mapped by (SQLSTATE, constraint name) in `app/errors.py`.
Web UI at `/`, Swagger at `/docs`.

## 8. Configuration

The app reads only environment variables (`app/config.py`); it does not
load `.env` files. No password is ever stored in the repo.

| Variable | Used by | Meaning |
|---|---|---|
| `DB_NAME` | app | database (default `stock_watchlist`) |
| `DB_HOST`, `DB_PORT`, `DB_USER` | app | unset → libpq defaults |
| `PGHOST`, `PGPORT`, `PGUSER` | psql + libpq (app too) | standard libpq defaults |
| `PGPASSWORD` / pgpass file | libpq | password if the server needs one |
| `PG_BIN` | scripts + tests | folder containing psql/createdb/dropdb |

### macOS (original dev machine, Homebrew)

```sh
brew services start postgresql@18
export PATH="/opt/homebrew/opt/postgresql@18/bin:$PATH"
python3.13 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```
Trust auth over the Unix socket; no env vars needed.

### Windows (this machine)

- PostgreSQL 18 service `postgresql-x64-18` on **port 5432**
  (a separate PostgreSQL 13 runs on 5433 — not used).
- Auth is `scram-sha-256`, so a password is needed. It is stored in the
  user's libpq password file **outside the repo**:
  `%APPDATA%\postgresql\pgpass.conf`, line format
  `localhost:5432:*:postgres:<password>`.
- Python venv `.venv` (Python 3.14; `.venv\Scripts\python`).
- Environment for Git Bash (run once per terminal):
  ```sh
  export PG_BIN="/c/Program Files/PostgreSQL/18/bin"
  export PATH="$PG_BIN:$PATH"
  export PGHOST=localhost PGPORT=5432 PGUSER=postgres
  source .venv/Scripts/activate
  ```
- PowerShell equivalent:
  ```powershell
  $env:PGHOST="localhost"; $env:PGPORT="5432"; $env:PGUSER="postgres"
  $env:PATH="C:\Program Files\PostgreSQL\18\bin;$env:PATH"
  .\.venv\Scripts\Activate.ps1
  ```
- `bash scripts/...` commands run in Git Bash with `PG_BIN` set as above.
- Known Windows-only test issues (checked 2026-10-21; the app itself is fine):
  - `sql/02_schema_tests.sql` and `sql/04_alert_tests.sql` use
    `\o /dev/null`, which Windows psql cannot open, so
    `run_all_tests.sh` stops at the first suite and `test_replay` test 15
    fails. With `\o NUL` in a temporary copy they pass 51/51 and 50/50.
  - `test_frontend` tests 01–02 compare served files byte-for-byte; Git
    checks the files out with CRLF line endings, so they fail on Windows.
  - All other suites pass on Windows: verify_spec, concurrency (17),
    test_indexes (15), test_api (32), test_live_feed (24), the other 17
    replay tests and the other 12 frontend tests.

## 9. Running it

| Task | Command |
|---|---|
| Create DB (once) | `createdb stock_watchlist` |
| Reset to clean seed | `bash scripts/reset_demo_db.sh` → must end `OK: ... = 3\|7\|5\|11\|6\|0\|0` |
| Start API + website | `uvicorn app.main:app --reload` → http://127.0.0.1:8000/ |
| Offline replay (30 ticks, 8 alerts) | `python -m app.replay data/replay_prices.csv --delay-ms 300 --run-id demo1` |
| Optional live feed | `python -m app.live_feed --symbols ETHUSDT --max-events 20` |
| Inspect DB (read-only) | `psql -d stock_watchlist -f sql/08_inspect_live.sql` |
| All tests | `bash scripts/run_all_tests.sh` → `ALL SUITES PASSED` |
| Benchmark (separate) | `python tests/benchmark_indexes.py` |

| Review 2 screenshots (Windows; rebuilds dev DB) | `powershell -ExecutionPolicy Bypass -File scripts/take_screenshots.ps1` → `docs/screenshots/*.png`; map in `sql/screenshots/README.md` |

Review 2 add-on: `sql/09_review2_objects.sql` creates schema `reporting`
(3 views, 2 procedures, 3 functions incl. a cursor function, 1 refcursor
procedure, roles sw_admin / sw_analyst / sw_enduser / arjun / priya). The
core `public` schema is unchanged; reset_demo_db.sh loads 09 too.

Demo order (golden rule): **reset → start app → (optional live) → replay
→ manual tick.** Full walkthrough: `docs/DEMO_GUIDE.md`.

Test suites in order: 02 schema tests (51) · verify_spec · 04 alert tests
(50) · concurrency (17) · test_replay (18) · test_indexes (15) · test_api
(32) · test_frontend (14) · test_live_feed (24, no internet). Python and
concurrency tests use throwaway databases; 02/04 roll back.

## 10. Rules for agents

- **Never run git or gh commands** (add, commit, push, pull, checkout,
  config, …). The student commits manually.
- Do not change the schema, stack or architecture without explicit
  approval; if a requested design is wrong, say why first.
- Parameterized SQL only. Secrets only in env vars / pgpass, never in
  the repo (`.env` is gitignored; commit only `.env.example`).
- Never claim PostgreSQL or tests ran unless they actually ran.
- Do not write finished report prose (abstract, intro, table
  descriptions, normalization paragraphs). Factual notes, SQL, FDs, test
  plans and viva explanations are fine.
- For each important DB decision give **WHY / VIVA / ANSWER**, and explain
  terms before assuming the student knows them.
- Keep `docs/FACT_SHEET.md`, `docs/EVIDENCE_CHECKLIST.md` and
  `docs/VIVA_NOTES.md` factual and generated from the real implementation.
