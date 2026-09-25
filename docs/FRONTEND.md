# Frontend (Phase 8): developer / study notes

Plain HTML + CSS + JavaScript, served by the same FastAPI app as the API.
Factual notes only, not report text.

```
Browser (index.html + styles.css + api.js + app.js)
   │  fetch("/users"), fetch("/ticks/ingest"), …   relative URLs, JSON
   ▼
FastAPI  app/main.py      GET / → index.html,  /static/* → app/static/
   │  psycopg 3, parameterized SQL
   ▼
PostgreSQL 18             constraints · ingest_tick() · alert trigger · index
```

## 1. Run it

```sh
cd "/Users/aditi/dbms project"
source .venv/bin/activate
uvicorn app.main:app --reload
```
- Web UI: http://127.0.0.1:8000/
- API docs: http://127.0.0.1:8000/docs (these load from a CDN; the web UI
  itself needs no internet)
- Other database: `DB_NAME=... uvicorn app.main:app --reload`
- Tests: `python -m unittest tests.test_frontend -v`

## 2. Files

| File | What it holds |
|---|---|
| app/static/index.html | the page: header (title, demo user selector, Refresh, health badge), side navigation, one `<section>` per view, the fixed forms |
| app/static/styles.css | colours as CSS variables, layout, cards, tables, badges, loading/empty/error styles, two breakpoints (1000 px, 760 px) |
| app/static/api.js | `api()`, the only `fetch()`; `ApiError`; `h()` DOM builder; `formatDecimal`, `checkDecimal`, `formatTime` |
| app/static/app.js | state object, loaders, one render function per view, form handlers, optional live refresh, start-up |

- No npm, no build step, no framework, no CDN, no web fonts (system font
  stack).
- The two scripts are classic `<script defer>` files. api.js loads first
  and defines the helpers app.js uses.

## 3. How FastAPI serves it (app/main.py)

| Route | Handler | In OpenAPI? |
|---|---|---|
| `GET /` | `FileResponse(app/static/index.html)` | no (`include_in_schema=False`) |
| `/static/*` | `StaticFiles(directory=app/static)` mount | no |

- Both send `Cache-Control: no-cache`. The browser re-checks each file
  with its ETag, so after an edit it never runs a stale copy. We saw that
  happen during testing before this header was added.
- `..` paths are refused by StaticFiles (test 03).
- The API routes are unchanged: 18 endpoints on 15 OpenAPI paths.

## 4. Views and the endpoints they use

| View | Shows / does | Endpoints |
|---|---|---|
| Header | demo user selector; Refresh; health badge | `GET /users`, `GET /health` |
| Dashboard | counts: watchlists, active rules, recent alerts (≤ 50), instruments; 5 newest alerts; watchlist overview with latest prices | reuses the data below (no extra endpoint) |
| Watchlists | each list: exchange, symbol, name, latest price, observed time; create, delete (confirm), add item, remove item (confirm) | `GET /users/{id}/watchlists`, `POST /users/{id}/watchlists`, `DELETE /watchlists/{id}`, `POST /watchlists/{id}/items`, `DELETE /watchlists/{id}/items/{instrument_id}` |
| Alert Rules | symbol, exchange, ▲ ABOVE / ▼ BELOW, threshold, cooldown, ACTIVE/DISABLED, created; create form; Enable/Disable; cooldown Save; Delete (confirm warns about history) | `GET /users/{id}/alert-rules`, `POST /users/{id}/alert-rules`, `PATCH /alert-rules/{id}`, `DELETE /alert-rules/{id}` |
| Alert History | fired, symbol, exchange, direction, threshold, triggered price, observed, rule #; newest first; instrument filter | `GET /users/{id}/alerts?limit=50[&instrument_id=]` |
| Instruments | exchange, symbol, name, currency, active; search + exchange filter (ALL / NSE / BSE / BINANCE, done in the browser); "Latest price & history" panel with SVG chart and table (latest 50 or 100) | `GET /instruments`, `GET /instruments/{id}/latest`, `GET /instruments/{id}/history?limit=` |
| Demo | manual tick form (exchange, symbol, price, optional volume); result INSERTED/DUPLICATE + tick_id; new latest price; alerts recorded for this tick; "Resend last tick"; offline replay command (text only) | `POST /ticks/ingest`, then the loaders above |

Every endpoint the UI uses already existed in Phase 7. None was added.

## 5. Rules the code follows

| Topic | How |
|---|---|
| API calls | only through `api(path, {method, body})`. It uses relative paths, parses JSON, and throws `ApiError(status, message, body)` for non-2xx. A network failure becomes status 0, "Cannot reach the server". |
| Error text | FastAPI's `detail` string, or the 422 list joined as "field: message". Known constraints get friendlier text: `pk_watchlist_items` → "RELIANCE is already in this watchlist.", `uq_watchlists_user_name` → "arjun already has a watchlist named …". |
| Safe HTML | `h(tag, props, ...children)` adds text via text nodes; there is no innerHTML anywhere. A watchlist named `<img src=x onerror=…>` is displayed as text and runs nothing (checked in Chrome). |
| Decimals | kept as the API's strings; `formatDecimal` works on the text (separators, trims zeros to ≥ 2 dp). Forms send the typed text. `Number()` is only used for chart pixel positions. |
| Timestamps | `toLocaleString()` in the browser's time zone; the raw ISO string is in the cell tooltip. The manual tick sends `new Date().toISOString()`, which is UTC with `Z`, so timezone-aware. |
| source_event_id | `"ui-" + crypto.randomUUID()` per new tick. Resend reuses it → DUPLICATE. |
| No business logic | nothing in JS decides duplicates, alerts or cooldowns. After an action the UI reloads from the API. The "alerts from this tick" list is simply the alert rows whose tick_id equals the returned tick_id. |
| Client checks | only for quicker messages: decimal format, > 0, ≤ 10 integer digits and ≤ 8 decimals (NUMERIC(18,8)), volume ≤ 16 integer digits, cooldown 0 … 2147483647. PostgreSQL enforces them again. |
| Loading/empty/error | each loader writes "Loading…", then content, an empty state ("No watchlists yet", "No alerts yet", "No price data yet", …) or a red error, never leaving "Loading…" behind. |
| "No ticks" | the 404 "Instrument has no price ticks yet." is shown as "No price data yet", not as an error. |
| Health | header badge: "API + database connected" (200), "Database unavailable" (503), "Server unreachable" (no response). |
| Refresh | the button reloads health, instruments, the user's watchlists, rules and alerts, and the open instrument panel. |
| Live refresh (Phase 9) | header button, **OFF by default**. When ON, every 5 s (`LIVE_INTERVAL_MS`) it re-reads `/health`, watchlists, alerts and the open instrument panel "quietly" (old content stays until new data arrives). A refresh is skipped while the previous one is still running, while the tab is hidden, or while a form field in the page has focus. OFF clears the timer. It switches itself off with a message if the server or database becomes unavailable. This is polling of the normal endpoints, not SSE/WebSocket. |
| Accessibility | a `<label for>` on every control (test 09); real `<button>`s; tables with `<th scope="col">`; `aria-current` on the active nav item; `aria-live` message area; confirm() before every delete; visible focus outline. |
| Layout | sidebar layout on desktop; below 760 px the nav becomes a top bar. Wide tables scroll inside their card, never the whole page. |

## 6. Limitations

- No server push: new ticks and alerts appear on Refresh, after your own
  action, or within 5 s when "Live refresh" is ON (polling).
- The Source column/field shows what the API returns (BINANCE / REPLAY /
  MANUAL). There is no "LIVE" badge; only BINANCE instruments can have
  live data (docs/LIVE_FEED.md).
- No login. The demo user selector only chooses whose rows to show.
- Alert list capped at 50; history at 50 or 100 ticks; no paging.
- The exchange filter lists BSE, but the seed data has no BSE
  instruments, so that filter shows the empty state.
- No DB Inspector view (latest 10 ticks / events). It is in the project
  scope but was not in the Phase 8 brief.
- Only Chrome was used for testing (headless Chrome 153). Only standard
  features are used (fetch, template literals, SVG, CSS grid/flex).
