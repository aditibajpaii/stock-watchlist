# Project Instructions

## Project

- Course: BCSE302P – Database Systems Lab
- Faculty: Dr. Anand Bihari
- Project: Real-Time Stock Market Watchlist & Alert System
- I am personally building the whole technical project and am still
  learning; I must be able to defend every design decision in a viva.
- Teammates write the report themselves from factual notes/evidence.
- Keep everything achievable for ONE student. Reliability and clarity over
  features.

Read before any major database decision:
- docs/RUBRIC.md
- docs/RESEARCH_BRIEF.md

## Marking priority

- ER Diagram: 3 marks
- Table creation + descriptions + screenshots: 5 marks
- Normal forms: 2 marks

Schema quality, relationships, constraints, normalization and evidence
matter more than frontend polish.

## Technology stack (locked)

- Database: PostgreSQL 18, installed via Homebrew (NOT Docker)
- Backend: Python + FastAPI
- Driver: psycopg 3, direct parameterized SQL (no ORM)
- Frontend: plain HTML + CSS + vanilla JavaScript
- Realtime to browser: Server-Sent Events (unless WebSocket is concretely needed)
- Version control: Git — managed MANUALLY by me. Claude must NEVER run any
  git or gh command (add, commit, push, pull, fetch, merge, rebase, reset,
  checkout/switch, remote, config) or change git identity/settings. I
  commit and push myself after approving each phase.

Do NOT introduce: React, Next.js, Node backend, SQLAlchemy, MongoDB, Redis,
Docker, microservices, Kubernetes, ML, trading/order execution, Kafka/Flink,
TimescaleDB dependency.

## Scope

Watchlist and price-alert system. NOT a brokerage, portfolio tool, trading
engine, prediction system or TradingView clone.

Core features:
- users, multiple named watchlists, instruments
- add/remove instruments from watchlists
- historical price ticks
- ABOVE/BELOW price-crossing alert rules, edge-triggered, with cooldown
- fired-alert history
- replay price feed (required; works offline, markets closed)
- Binance public market-data feed for BTCUSDT/ETHUSDT (optional; no
  trading/account endpoints)
- Upstox live NSE only if later requested; never a demo dependency
- index benchmark (EXPLAIN ANALYZE, B-tree required, BRIN optional)
- small web UI incl. a DB Inspector (latest 10 ticks / latest 10 events)

Stocks are the main domain; crypto is only a convenient 24/7 live source.

## Approved design decisions (Phase 1)

Seven tables (plural names): users, instruments, watchlists,
watchlist_items, price_ticks, alert_rules, alert_events.
Full approved spec: docs/PHASE1_SPEC.md

Schema:
- NO alert_state table — PROVISIONAL. Edge detection must be proven correct
  under concurrent ingestion (same instrument), multiple rules per
  instrument, identical timestamps, late/out-of-order ticks, cooldown and
  duplicate input. If that becomes fragile/complex, STOP and justify
  alert_state before adding it. Never add it silently.
- No latest_price table initially; latest price comes from price_ticks.
- instruments has NO asset_class column (exchange -> asset_class would
  violate 3NF). Identity = UNIQUE (exchange, symbol).
- price_ticks: surrogate PK tick_id; market time column `observed_at`
  (TIMESTAMPTZ); `ingested_at` DEFAULT now(); `source` IN
  ('REPLAY','BINANCE','MANUAL') and `source_event_id` both NOT NULL;
  UNIQUE (source, instrument_id, source_event_id).
  Do NOT use UNIQUE (instrument_id, observed_at) — timestamps are not
  identity.
- price_ticks.volume NUMERIC(24,8) NULLABLE, CHECK (volume IS NULL OR
  volume >= 0). No default: unknown volume != zero volume.
- Prices NUMERIC, never FLOAT. Timestamps TIMESTAMPTZ (UI may show IST).
- alert_rules: cooldown_seconds CHECK (>= 0), no arbitrary maximum;
  UNIQUE (user_id, instrument_id, direction, threshold).
- Rule definition (user_id, instrument_id, direction, threshold) is
  immutable BY DESIGN RULE ONLY — no immutability trigger for now. App
  exposes enable / disable / change cooldown. To change the definition:
  disable old rule, create new one.
- alert_events = (event_id, rule_id, tick_id, fired_at) only. Never copy
  instrument_id / observed_at / price into it.
- alert_events is the durable source of truth; pg_notify carries only the
  event_id after a real event is created.
- Name every PK, FK, UNIQUE and CHECK constraint.

ON DELETE policy (deliberate ownership policy):
- CASCADE for user-owned data: users -> watchlists, watchlists ->
  watchlist_items, users -> alert_rules, alert_rules -> alert_events.
- RESTRICT for shared market/reference data: instruments -> price_ticks,
  instruments -> watchlist_items, instruments -> alert_rules,
  price_ticks -> alert_events.
- UI should disable rules rather than delete them.
- Deleting a watchlist must never delete market price history.
- price_ticks is historical/append-only as a design rule; no app endpoint
  edits or deletes ticks. No rejection trigger for now.

Ingestion and alerts (Phase 4):
- ALL operational ingestion (REPLAY, BINANCE, MANUAL) calls one PostgreSQL
  function, conceptually `ingest_tick(...)`, once per market event.
- ingest_tick locks the instrument row BEFORE inserting the tick, inserts
  exactly one price_ticks row (ON CONFLICT DO NOTHING on the source
  identity), and returns tick_id or a duplicate result.
- An AFTER INSERT row trigger on price_ticks evaluates alerts for that tick.
- ingest_tick is the OFFICIAL operational insertion path for price_ticks
  once it exists. All application, replay, Binance and manual-demo
  ingestion must use it. Direct INSERT into price_ticks is not an
  application path (it bypasses the pre-insert instrument lock).
- Evaluation only considers rules WHERE rule.instrument_id =
  tick.instrument_id; a Phase 4 test must prove a rule on another
  instrument cannot produce an event.
- Phase 4 also adds a BEFORE INSERT trigger on alert_events that rejects
  the insert unless alert_rules.instrument_id = price_ticks.instrument_id
  for the supplied rule_id / tick_id. Do NOT add instrument_id to
  alert_events; the table stays normalized.
- Tick order tuple: (observed_at, tick_id). Late ticks are stored but not
  evaluated.
- Edge-triggered: ABOVE fires on prev < T AND new >= T; BELOW on
  prev > T AND new <= T. Cooldown measured in tick time (observed_at).
- NO global multi-row INSERT ban, NO isolation-level-checking trigger.
- Normal ingestion runs under READ COMMITTED. SERIALIZABLE only as a later
  separate demonstration.
- Benchmark bulk loads go directly into price_ticks with alert processing
  disabled, or into an isolated benchmark setup.

Feeds:
- Replay: timestamps rebased to replay start; one run_id per intentional
  run; retries/reconnects within the same run reuse the run_id
  (idempotent via UNIQUE); a new demo run gets a new run_id.
  source_event_id = '<run_id>:<row_no>'.
- Binance: NO throttling (it could hide a real crossing). Use the
  trade / aggregate-trade id as source_event_id; process the few demo
  symbols normally.
- One active feed per instrument at a time.

Indexes:
- Only committed intended index: price_ticks (instrument_id,
  observed_at DESC, tick_id DESC). Created in the index phase.
- PK/UNIQUE constraints already create indexes; leading columns may already
  cover some queries. Further indexes are designed from real queries and
  EXPLAIN output only.

## How to run (current state)

- psql: `export PATH="/opt/homebrew/opt/postgresql@18/bin:$PATH"`; dev DB
  `stock_watchlist`; rebuild = 00_schema → 01_seed → 03_functions_triggers
- Python: project venv `.venv/` (Python 3.13, psycopg 3.3.6 only);
  replay = `python -m app.replay data/replay_prices.csv`
- Tests: sql/02_schema_tests.sql, sql/verify_spec.sql, sql/04_alert_tests.sql,
  `bash tests/concurrency_test.sh`, `python -m unittest tests.test_replay -v`
  (Python/concurrency tests use throwaway DBs, never the dev DB)

## Working rules

Phases:
0 inspect env/repo · 1 requirements + ER/schema · 2 schema + seed + schema
tests · 3 normalization proof · 4 alert engine + tests · 5 replay ingestion
· 6 index benchmark · 7 minimal web app · 8 Binance feed · 9 optional
concurrency demo / BRIN · 10 evidence audit + fact sheet + viva prep

For each phase: explain goal, inspect files first, show plan, implement
only that phase, run code/tests, fix failures, report what actually passed,
teach the key DB idea, list evidence/screenshots to save, then STOP and wait.

- Do not create SQL tables until the schema is explicitly approved.
- Do not build the frontend before the database design is approved.
- Do not silently add complexity or change architecture.
- If a requested design is wrong, say so and explain why before building.
- Never claim PostgreSQL/tests ran unless they actually ran.
- Parameterized SQL only; secrets in env vars; commit .env.example, never
  real secrets; add .gitignore.

For each important DB decision give:
- WHY: plain-language reason
- VIVA: likely examiner question
- ANSWER: short answer I should understand

Explain terms before assuming I know them.

## Academic writing rule

Do NOT write finished report prose (Abstract, Introduction, Scope, table
descriptions, normalization paragraphs) or rewrite student paragraphs into
finished text.

Allowed: SQL, code, schemas, factual bullet notes, functional dependencies,
normalization analysis, test plans, viva explanations, evidence checklists,
pointing out errors in student-written text.

Maintain (from later phases):
- docs/FACT_SHEET.md — short factual fragments only, generated from the
  real implementation; never invent values.
- docs/EVIDENCE_CHECKLIST.md — screenshots/evidence to capture.
- docs/VIVA_NOTES.md
