# Real-Time Stock Market Watchlist & Alert System

BCSE302P Database Systems Lab project. Users keep watchlists of
instruments, define ABOVE/BELOW price-alert rules, and PostgreSQL fires
edge-triggered alerts (with cooldown) as price ticks arrive. It is not a
trading or portfolio system.

## Architecture

```
Browser (plain HTML/CSS/JS)  →  FastAPI (app/main.py)  →  PostgreSQL 18
                                                            ├─ 7 tables, 36 named constraints
CSV replay     app/replay.py     ─┐                         ├─ ingest_tick() (lock, dedupe)
Binance live   app/live_feed.py  ─┴→ ingest_tick() ────────→├─ alert trigger → alert_events
                (optional)                                  └─ ix_price_ticks_instrument_time
```

All data rules live in PostgreSQL: constraints, `ingest_tick()`, the
triggers and the index. Python and JavaScript only send requests and
display results.

## Stack

PostgreSQL 18.6 (Homebrew) · Python 3.13 · psycopg 3 with plain,
parameterized SQL (no ORM) · FastAPI + Uvicorn · plain HTML/CSS/JS (no
framework, npm or CDN) · websockets (Binance public market data, no API
key).

## Features

- Users (seeded demo users, no login), instruments (NSE stocks, and
  BTCUSDT/ETHUSDT on Binance)
- Multiple named watchlists per user; add and remove instruments; latest
  price for each
- Price history (price_ticks) with latest-price and history views
- ABOVE/BELOW alert rules: edge-triggered, with cooldown measured in
  market time; enable/disable
- Durable alert history (alert_events)
- Offline, deterministic replay feed (always works); optional live
  Binance feed
- Web UI: Dashboard, Watchlists, Alert Rules, Alert History,
  Instruments, Demo (manual tick); optional 5 s "Live refresh"
- Index benchmark on 500,000 ticks with EXPLAIN ANALYZE (B-tree kept,
  BRIN compared)

## Setup (once)

```sh
cd "/Users/aditi/dbms project"
brew services start postgresql@18
export PATH="/opt/homebrew/opt/postgresql@18/bin:$PATH"
createdb stock_watchlist                      # only if it doesn't exist yet
python3.13 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Everyday commands

| Task | Command |
|---|---|
| Reset DB to clean seed (3 users, 7 instruments, 5 watchlists, 11 items, 6 rules, 0 ticks, 0 alerts) | `bash scripts/reset_demo_db.sh` |
| Same reset as a plain psql command | `psql -q -d stock_watchlist -v ON_ERROR_STOP=1 -f sql/00_schema.sql -f sql/01_seed.sql -f sql/03_functions_triggers.sql -f sql/06_indexes.sql` |
| Start API + website | `uvicorn app.main:app --reload`, then open http://127.0.0.1:8000/ (API docs: /docs) |
| Offline replay (30 ticks, 8 alerts on a clean DB) | `python -m app.replay data/replay_prices.csv --delay-ms 300 --run-id demo1` |
| Optional live feed (internet) | `python -m app.live_feed --symbols ETHUSDT --max-events 20` |
| Show what is stored (read-only) | `psql -d stock_watchlist -f sql/08_inspect_live.sql` |
| All tests | `bash scripts/run_all_tests.sh` (with the venv active) |

Database settings come from environment variables (`DB_NAME`, `DB_HOST`,
`DB_PORT`, `DB_USER`; see `.env.example`). There are no passwords in the
project.

## Tests

`scripts/run_all_tests.sh` runs, in order:

| Suite | Checks |
|---|---|
| sql/02_schema_tests.sql | 51 constraint tests |
| sql/verify_spec.sql | live schema = spec |
| sql/04_alert_tests.sql | 50 alert-engine tests |
| tests/concurrency_test.sh | 17 multi-session locking/NOTIFY checks |
| tests.test_replay | 18 |
| tests.test_indexes | 15 |
| tests.test_api | 32 |
| tests.test_frontend | 14 |
| tests.test_live_feed | 24 (no internet needed) |

The dev database is left unchanged. The 500k-row benchmark
(`python tests/benchmark_indexes.py`) is separate; its results are in
docs/benchmark_results/.

## Documentation

| File | Contents |
|---|---|
| docs/DEMO_GUIDE.md | step-by-step classroom demo and what to do if something fails |
| docs/FACT_SHEET.md | every verified fact and number (for the report team) |
| docs/EVIDENCE_CHECKLIST.md | screenshots to capture, starting with the must-have list |
| docs/VIVA_NOTES.md | short viva answers, top-15 list first |
| docs/PHASE1_SPEC.md, docs/ER_DIAGRAM.md, docs/NORMALIZATION_NOTES.md | schema design, ER diagram, FDs/BCNF |
| docs/INDEX_BENCHMARK.md | index benchmark method and results |
| docs/API.md, docs/FRONTEND.md, docs/LIVE_FEED.md | backend, web UI, live feed |
| data/README.md | row-by-row expected behaviour of the replay CSV |
