# API (Phase 7) — developer / study notes

FastAPI backend: `app/main.py`. All data rules live in PostgreSQL; the API
runs parameterized SQL and translates database errors into HTTP responses.

```
browser / curl / Swagger ──HTTP/JSON──▶ FastAPI (app/main.py) ──psycopg 3, plain SQL──▶ PostgreSQL 18
                                                                   constraints · ingest_tick() · alert trigger · index
```

## 1. Run it

```sh
cd "/Users/aditi/dbms project"
source .venv/bin/activate              # Python 3.13 venv
pip install -r requirements.txt        # first time only
uvicorn app.main:app --reload          # http://127.0.0.1:8000
```

- **Swagger UI:** http://127.0.0.1:8000/docs. It loads its JavaScript and
  CSS from `cdn.jsdelivr.net`, so the browser needs internet access.
- **Offline alternatives:** `/openapi.json` (the machine-readable spec)
  and plain curl. The API itself never needs internet.
- **Stop the server:** Ctrl+C.

### Database settings (environment variables, read on every request)

| Variable | Default | Notes |
|---|---|---|
| DB_NAME | `stock_watchlist` | e.g. `DB_NAME=stock_watchlist_benchmark uvicorn app.main:app` |
| DB_HOST | unset (local Unix socket) | |
| DB_PORT | unset (5432) | |
| DB_USER | unset (OS user) | |

- There is no password in code or config. The local server uses trust
  authentication; libpq's PGPASSWORD / ~/.pgpass would apply if needed.
- See `.env.example`.

## 2. Conventions

| Topic | Rule |
|---|---|
| Money / NUMERIC | JSON **strings** in plain fixed-point, e.g. `"3060.50000000"`, `"0.00000001"`. Never float, never `1E-8`. Requests may send a number or a string. |
| Timestamps | ISO 8601 **with offset**. Responses use the server time zone (Asia/Kolkata, `+05:30`). Requests must include an offset or `Z`; naive times → 422. |
| Timestamps in a URL | encode `+` as `%2B` (e.g. `from_time=2026-01-05T09:15:00%2B05:30`) or use `Z` |
| IDs | positive integers; 0, negative or non-numeric → 422 |
| Unknown JSON fields | rejected (422) on every request body |
| Errors | `{"detail": "...", "sqlstate": "23505", "constraint": "uq_…"}` for database errors; FastAPI's `{"detail": [...]}` list for 422 validation errors |
| Auth | none. users are seeded demo users (project scope) |

## 3. Endpoints (18 endpoints on 15 paths)

| Method | Path | Success | Errors | Notes |
|---|---|---|---|---|
| GET | /health | 200 `{"status":"ok","database":"connected"}` | 503 `{"status":"error","database":"unavailable"}` | runs `SELECT 1` |
| GET | /users | 200 list | – | user_id, username, email, created_at |
| GET | /users/{user_id} | 200 | 404 | |
| GET | /instruments | 200 list | 422 | query: `exchange`, `active_only=true` |
| GET | /instruments/{instrument_id} | 200 | 404 | |
| GET | /instruments/{instrument_id}/latest | 200 tick | 404 instrument / 404 "no price ticks yet" | `ORDER BY observed_at DESC, tick_id DESC LIMIT 1` (Phase 6 index) |
| GET | /instruments/{instrument_id}/history | 200 list | 404, 422 | `limit` 1–1000 (default 100), `from_time`, `to_time` (half-open [from, to)); returns the **most recent** `limit` ticks, listed **oldest → newest** |
| GET | /users/{user_id}/watchlists | 200 list | 404 | each list with items + each item's latest price; ONE query (LEFT JOIN + LATERAL) |
| POST | /users/{user_id}/watchlists | 201 | 404 user, 409 `uq_watchlists_user_name`, 422 | body `{"name": "My Stocks"}` (1–50 chars, trimmed) |
| DELETE | /watchlists/{watchlist_id} | 204 | 404 | its items CASCADE; instruments and ticks kept |
| POST | /watchlists/{watchlist_id}/items | 201 item | 404 watchlist/instrument (FK), 409 `pk_watchlist_items` | body `{"instrument_id": 1}` |
| DELETE | /watchlists/{watchlist_id}/items/{instrument_id} | 204 | 404 | removes only the pair |
| GET | /users/{user_id}/alert-rules | 200 list | 404 | includes exchange, symbol |
| POST | /users/{user_id}/alert-rules | 201 | 404 user/instrument, 409 `uq_alert_rules_definition`, 422 | body `{"instrument_id":1,"direction":"ABOVE","threshold":3000,"cooldown_seconds":300}` (cooldown default 300) |
| PATCH | /alert-rules/{rule_id} | 200 | 404, 422 | **only** `is_active` and/or `cooldown_seconds`; any other field → 422 |
| DELETE | /alert-rules/{rule_id} | 204 | 404 | **also deletes that rule's alert_events** (ON DELETE CASCADE); ticks kept. To keep history, PATCH `is_active=false` instead |
| GET | /users/{user_id}/alerts | 200 list | 404, 422 | newest first (fired_at DESC, event_id DESC); `limit` 1–500 (default 50), `instrument_id` filter |
| POST | /ticks/ingest | 201 `{"status":"INSERTED","tick_id":N}` / 200 `{"status":"DUPLICATE","tick_id":null}` | 404 SW001, 409 SW002, 422 | **dev/demo only**; calls `ingest_tick(..., 'MANUAL', ...)` |

## 4. Example shapes

`POST /users/2/alert-rules` `{"instrument_id":1,"direction":"ABOVE","threshold":3050,"cooldown_seconds":60}` → 201
```json
{"rule_id":7,"user_id":2,"instrument_id":1,"exchange":"NSE","symbol":"RELIANCE","direction":"ABOVE",
 "threshold":"3050.00000000","cooldown_seconds":60,"is_active":true,"created_at":"2026-09-25T16:57:44.304073+05:30"}
```

`POST /ticks/ingest`
```json
{"exchange":"NSE","symbol":"RELIANCE","observed_at":"2026-09-25T10:00:05+05:30",
 "price":"3060.50","volume":null,"source_event_id":"manual-api-002"}
```
→ 201 `{"status":"INSERTED","tick_id":2}`. The same body again returns
200 `{"status":"DUPLICATE","tick_id":null}`.

`GET /users/2/alerts` → 200
```json
[{"event_id":1,"rule_id":7,"instrument_id":1,"exchange":"NSE","symbol":"RELIANCE","direction":"ABOVE",
  "threshold":"3050.00000000","tick_id":2,"price":"3060.50000000",
  "observed_at":"2026-09-25T10:00:05+05:30","fired_at":"2026-09-25T16:57:44.445400+05:30"}]
```

`GET /users/1/watchlists` → 200
```json
[{"watchlist_id":2,"user_id":1,"name":"Long Term","created_at":"…",
  "items":[{"instrument_id":1,"exchange":"NSE","symbol":"RELIANCE","name":"Reliance Industries Ltd",
            "added_at":"…","latest_price":"3060.50000000","latest_observed_at":"…"}]}]
```
`latest_price` / `latest_observed_at` are `null` when the instrument has no ticks.

Database error examples:
```json
409 {"detail":"This user already has an identical alert rule (same instrument, direction and threshold).",
     "sqlstate":"23505","constraint":"uq_alert_rules_definition"}
404 {"detail":"Unknown instrument (no such exchange + symbol).","sqlstate":"SW001"}
422 {"detail":"Numeric value out of range for the database column.","sqlstate":"22003"}
```

## 5. HTTP status meanings (this API)

| Code | Meaning here |
|---|---|
| 200 | OK (also: DUPLICATE ingest, nothing stored) |
| 201 | created (watchlist, item, rule, INSERTED tick) |
| 204 | deleted |
| 404 | the id in the URL doesn't exist, a referenced row doesn't exist (FK 23503), unknown instrument (SW001), or no ticks yet |
| 409 | conflicts with existing data: UNIQUE/PK 23505, inactive instrument SW002, RESTRICT 23001 |
| 422 | invalid input: request validation (Pydantic) or a database CHECK (23514) / out-of-range (22003) |
| 500 | unexpected database error. Generic message only; details go to the server log |
| 503 | database unreachable |

## 6. How the API uses the database

| Concern | Where it lives |
|---|---|
| Uniqueness, FKs, CHECKs | PostgreSQL constraints. The API does **not** pre-check duplicates; it maps the database's 23505/23503 errors |
| Tick ingestion, locking, duplicates, alert evaluation, cooldown, NOTIFY | `ingest_tick()` + `trg_price_ticks_evaluate_alerts` |
| Event/instrument consistency | `trg_alert_events_check_instrument` |
| Latest price | query on price_ticks via `ix_price_ticks_instrument_time`; no latest_price table |
| Alert history | joins alert_events → alert_rules → price_ticks → instruments; nothing copied |

Other facts:
- **Connections:** one per request (`app/db.py`), in autocommit mode.
  Writes and multi-query reads use an explicit `with conn.transaction():`
  (COMMIT on success, ROLLBACK on any exception). No shared connection.
- **SQL:** every value is a psycopg parameter (`%s` / `%(name)s`).
  Optional filters are built with `psycopg.sql.SQL` composition from fixed
  fragments only. Test 29 shows `NSE' OR '1'='1` returns `[]` and
  `x'); DROP TABLE users; --` is stored as a plain watchlist name.
- **Error mapping:** in `app/errors.py`, keyed by (SQLSTATE, constraint
  name). Tracebacks, SQL text and connection details are never returned.

## 7. Tests

`python -m unittest tests.test_api -v`: 32 tests.
- They use FastAPI's TestClient against a real PostgreSQL throwaway DB,
  cloned for each test from a template built with 00 + 01 + 03 + 06.
- No mocks. The dev DB is never touched.
