# Live Binance feed (Phase 9): developer / study notes

This feed is optional. The project works fully without it. The guaranteed
demo path stays the offline replay:
`python -m app.replay data/replay_prices.csv --delay-ms 300`.

```
Binance public WebSocket (aggTrade, market data only, no API key)
        │  JSON messages
        ▼
app/live_feed.py      separate process: parse → Decimal/UTC → one transaction per event
        │  SELECT … FROM ingest_tick('BINANCE', symbol, T, p, q, 'BINANCE', 'aggTrade:<a>')
        ▼
PostgreSQL            instrument lock · UNIQUE duplicate check · late-tick rule ·
                      trg_price_ticks_evaluate_alerts → alert_events · NOTIFY
        ▼
FastAPI + web UI      unchanged; read the same tables (Refresh or "Live refresh: ON")
```

## 1. What is live and what is not

| Exchange in DB | Live? | How prices get in |
|---|---|---|
| BINANCE (BTCUSDT, ETHUSDT) | yes, optional | `app.live_feed`, or replay, or manual tick |
| NSE (RELIANCE, TCS, INFY, HDFCBANK, M&M) | **no** | offline replay, manual tick (Demo view) |

- NSE/BSE prices are never presented as live. No website is scraped, and
  no unofficial stock-data package is used.
- A symbol can be live only if it is stored as `(exchange = 'BINANCE',
  symbol)` and `is_active = true`. The worker never creates instruments.

## 2. Official source used (checked 2026-09-25)

- Binance Spot API docs: https://developers.binance.com/docs/binance-spot-api-docs/web-socket-streams
- The same text in Binance's official docs repository:
  https://github.com/binance/binance-spot-api-docs/blob/master/web-socket-streams.md
  (CHANGELOG "Last Updated: 2026-09-18")

Facts taken from it:

| Topic | Official statement (summary) |
|---|---|
| Endpoints | `wss://stream.binance.com:9443` or `:443`. `wss://data-stream.binance.vision` serves **only market data** (no user data). |
| Stream name | `<symbol>@aggTrade`; symbols in stream names are lowercase |
| Combined stream | `/stream?streams=a/b`; each message is `{"stream": "<name>", "data": <payload>}` |
| Authentication | none for market-data streams (no API key) |
| aggTrade payload | `e` "aggTrade", `E` event time, `s` symbol, `a` aggregate trade id, `p` price (string), `q` quantity (string), `f`/`l` first/last trade id, `T` trade time, `m` buyer is maker, `M` ignore |
| Time unit | milliseconds by default (microseconds only with `timeUnit=MICROSECOND`, not used) |
| Keep-alive | the server sends a ping every 20 s. The client must answer with a pong within 1 minute, or it is disconnected. |
| Lifetime | a connection is valid for 24 h, then disconnected |
| `serverShutdown` | event sent before a server shutdown; reconnect as soon as possible |
| Limits | 5 incoming messages/s per connection (pings, pongs, JSON control messages); max 1024 streams per connection; 300 connection attempts per 5 min per IP |

Choice made: **`wss://data-stream.binance.vision`** (market-data-only
endpoint), combined stream of `<symbol>@aggTrade`.
- aggTrade gives one message per taker order at each price level, which
  is fewer than raw `@trade`, and still every price that traded.
- The URL is built from the symbols, e.g.
  `wss://data-stream.binance.vision/stream?streams=btcusdt@aggTrade/ethusdt@aggTrade`.
- The client sends no subscribe messages; the streams are named in the
  URL.

## 3. Run it

```sh
cd "/Users/aditi/dbms project"
source .venv/bin/activate
python -m app.live_feed --symbols ETHUSDT --max-events 20             # short demo
python -m app.live_feed --symbols BTCUSDT ETHUSDT --duration-seconds 60
python -m app.live_feed --symbols ETHUSDT                             # until Ctrl+C
```

| Option | Meaning |
|---|---|
| `--symbols S …` | one or more BINANCE instruments (case-insensitive, duplicates ignored) |
| `--max-events N` | stop after N events were stored or reported DUPLICATE |
| `--duration-seconds N` | stop after N seconds |
| `--quiet` | print only alerts and the summary |
| `--verbose` | also print each raw message (debugging) |
| `--base-url URL` | another WebSocket base URL (used by the local-server test); default is the official endpoint above |

- **Other database:** prefix the command with `DB_NAME=…`, as for the
  API and the replay.
- **Stop:** Ctrl+C at any time. With a real SIGINT the worker stopped
  in 1.04–1.05 s (3 runs), printed a summary and exited with code 0.
  Most of that second is the wait for the WebSocket close handshake,
  capped at 1 s. Every event already committed stays stored. An event
  interrupted mid-transaction is rolled back.
- **Exit codes:** 0 finished/stopped · 1 bad arguments, unknown or
  inactive symbol · 2 database error, or stored data ahead of real time ·
  3 network gave up.
- **FastAPI is independent:** start it separately with
  `uvicorn app.main:app --reload`. The feed is not part of app startup.

Output line (times in IST):
```
18:36:55.585 ETHUSDT       2720.93 vol=0.4508       aggTrade:2089678071 -> INSERTED tick=2
        ALERT event=1: kavya ETHUSDT BELOW 3000        (only when PostgreSQL created one)
```

## 4. Event → ingest_tick mapping

| ingest_tick parameter | Value | Notes |
|---|---|---|
| p_exchange | `'BINANCE'` | fixed |
| p_symbol | `data.s` | must be one of the requested symbols, else the message is skipped |
| p_observed_at | `data.T` (trade time, ms) → `1970-01-01T00:00:00Z + T ms` | integer arithmetic, no float; timezone-aware UTC; **not** the local receive time, **not** `E` |
| p_price | `Decimal(data.p)` | must be a string, finite, > 0 |
| p_volume | `Decimal(data.q)` | must be a string, finite, ≥ 0 (traded quantity of that aggregate trade) |
| p_source | `'BINANCE'` | fixed |
| p_source_event_id | `'aggTrade:' + data.a` | deterministic, from Binance's aggregate trade id |

- **Rejected and never stored:** non-JSON input, other event types
  (`trade`, subscription replies), missing fields, a float or `"NaN"`
  price, a negative quantity, an ID that is not an integer. These are
  counted as "Skipped".
- **Duplicates:** `UNIQUE (source, instrument_id, source_event_id)`. If
  the same aggTrade arrives twice (e.g. after a reconnect), ingest_tick
  returns DUPLICATE and nothing is stored twice. aggTrade IDs are per
  symbol, and the unique key includes instrument_id.
- **Same millisecond:** many aggTrades share the same `T`; in the smoke
  test, 14 of 15 did. Order is then decided by tick_id, i.e. arrival
  order, which matches Binance's `a` order on one connection.
- One transaction per event: ingest_tick, then
  `SELECT … FROM alert_events WHERE tick_id = …` only to *print* the
  alerts PostgreSQL created.

## 5. Safety checks before connecting

1. **Instruments:** every symbol must be an active BINANCE instrument.
   Unknown → "not a BINANCE instrument in the database … use the offline
   replay"; inactive → "instrument is inactive". Exit 1, no network
   access.
2. **Timeline:** if `max(observed_at)` of the chosen instruments is more
   than 5 s after now, the worker refuses: "Stored replay data is ahead
   of real time. Reset the demo database before starting live mode."
   - **Why:** a replay stamps ticks up to 7 min 40 s into the future.
     Live trade times would be older, so PostgreSQL would classify every
     live tick as LATE: stored, but never evaluated for alerts.
   - **The 5 s:** a small allowance for the Binance clock versus the
     laptop clock. Nothing is deleted automatically, and the database's
     late-tick rule is not bypassed.
   - **Reverse order:** a replay started right after live ticks (which
     are ≈ now) is refused by the replay's own guard until a second has
     passed, or run it with `--start-after-latest`.

## 6. Reconnects

| Situation | Behaviour |
|---|---|
| connection refused / DNS / TLS / handshake error / connection closed / `serverShutdown` | message "Connection lost (…). Reconnecting in N s (attempt k/5)…" |
| back-off | 1, 2, 4, 8, 16 s (max 30), counted over consecutive failures |
| a connection that delivered events | resets the counter, so the 24 h disconnect costs one short retry |
| 5 failed reconnects in a row | exit 3, "gave up after 5 reconnect attempts", with the replay command |
| pings | answered automatically by the `websockets` library. It also sends its own keep-alive ping every 20 s (1 message / 20 s, far below the limit of 5/s) |
| quiet stream | `recv` waits at most 1 s, so `--duration-seconds` and Ctrl+C are checked every second |

## 7. Volume (measured 2026-09-25, 30 s sample)

| Symbol | aggTrade events | per second | out-of-order `T` |
|---|---|---|---|
| BTCUSDT | 757 | 25.2 | 0 |
| ETHUSDT | 606 | 20.2 | 0 |

- Unbounded, that is roughly 70,000–90,000 ticks per hour per symbol.
  For demos, use one symbol and `--max-events` or `--duration-seconds`.
- No event is dropped or sampled: throttling could hide a threshold
  crossing.
- ingest_tick keeps up comfortably. In the smoke test, rows were stored
  78–116 ms after the Binance trade time, and that includes the network
  delay.

## 8. Reset to the clean classroom database

One command (project root, psql on PATH):
```sh
psql -q -d stock_watchlist -v ON_ERROR_STOP=1 -f sql/00_schema.sql -f sql/01_seed.sql -f sql/03_functions_triggers.sql -f sql/06_indexes.sql
```
Result (verified on a replayed throwaway copy, 2026-09-25): 3 users,
7 instruments, 5 watchlists, 11 watchlist items, 6 alert rules, 0
price_ticks, 0 alert_events. Check it with
`psql -d stock_watchlist -f sql/08_inspect_live.sql`.

## 9. DB inspector

`sql/08_inspect_live.sql` is read-only (runs in `BEGIN TRANSACTION READ
ONLY … ROLLBACK`). It shows:
- row counts
- ticks per source and instrument
- the latest 10 price_ticks, with source and source_event_id
- the latest 10 alert_events, joined to user, rule, instrument and tick

There is no browser SQL endpoint and no admin panel.

## 10. Live alerts in a demo

- The seed thresholds are far from today's market: arjun BTCUSDT ABOVE
  100000 while BTC ≈ 84,000; kavya ETHUSDT BELOW 3000 while ETH ≈ 2,715,
  already below, so only an upward move past 3000 followed by a fall
  would fire. A short live run will usually create **no** alert, and
  that is correct.
- For a real live crossing, create a rule close to the current price in
  the web UI (e.g. ETHUSDT ABOVE current + 0.50), then run the feed.
  An alert appears only if the market actually crosses it.
- For guaranteed alert evidence use the replay (8 alerts on a fresh DB)
  or two manual ticks.

## 11. Tests (`python -m unittest tests.test_live_feed -v`, 24 tests, no internet)

- **Fixtures:** in the documented combined-stream aggTrade format.
- **Network:** replaced by fake connections, plus one real WebSocket
  server on 127.0.0.1.
- **Database:** a throwaway DB `stock_watchlist_p9_test`, cloned per
  test; the dev DB is never touched.
- The coverage list is in docs/FACT_SHEET.md.

## 12. Limitations

- Crypto only. There is no live NSE/BSE data (no free official public
  feed was used or scraped).
- The browser is not pushed updates. It polls every 5 s when "Live
  refresh" is ON; otherwise use Refresh.
- One worker per instrument at a time (project rule). Running live feed
  and replay together on one instrument mixes timelines, and one of them
  will see LATE ticks.
- It depends on internet access to Binance and on Binance's service in
  your region. It worked from this network on 2026-09-25.
- The 5-message-per-second limit counts only control frames; the client
  sends none except keep-alive pings.
