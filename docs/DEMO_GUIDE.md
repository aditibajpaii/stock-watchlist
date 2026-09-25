# Demo Guide (personal checklist, not report text)

Every command and number below was checked on 2026-09-25 against a clean
copy of the database. Commands start in the project folder:
`cd "/Users/aditi/dbms project"`.

> **Golden rule:** reset → start the app → (optional live) → replay →
> manual tick. Keep that order. The replay stamps its ticks up to
> 7 min 40 s into the future, so anything run *after* it on the same
> instruments looks "late" (§G, §H).

---

## A. Before class (at home, the evening before)

1. Start PostgreSQL: `brew services start postgresql@18`
2. Check it answers: `/opt/homebrew/opt/postgresql@18/bin/pg_isready`,
   which should say `accepting connections`.
3. Terminal setup:
   ```sh
   cd "/Users/aditi/dbms project"
   source .venv/bin/activate
   export PATH="/opt/homebrew/opt/postgresql@18/bin:$PATH"
   ```
4. Run all tests once:
   `bash scripts/run_all_tests.sh` (about 30 s). It must end with `ALL SUITES PASSED`.
5. Reset the database (§B).
6. Bookmark http://127.0.0.1:8000/ in the browser. Zoom to 110–125% so
   the examiner can read the screen.
7. Charge the laptop. Close other apps that might use port 8000.

## B. Reset the database (always right before a demo)

```sh
bash scripts/reset_demo_db.sh
```
The last line must read:
`OK: stock_watchlist is clean (users|instruments|watchlists|items|rules|ticks|events = 3|7|5|11|6|0|0)`

The same reset without the script:
```sh
psql -q -d stock_watchlist -v ON_ERROR_STOP=1 -f sql/00_schema.sql -f sql/01_seed.sql -f sql/03_functions_triggers.sql -f sql/06_indexes.sql
```

## C. Start the backend and website (Terminal 1; leave it running)

```sh
cd "/Users/aditi/dbms project"
source .venv/bin/activate
uvicorn app.main:app --reload
```
Wait for `Application startup complete.`

- **"address already in use":** another uvicorn is still running. Run
  `lsof -i :8000`, then `kill <PID>`, and start again.

## D. Open the browser

- http://127.0.0.1:8000/ is the website.
- The top-right badge should be green: **API + database connected**.
- The demo user selector shows **arjun** by default.
- Optional: http://127.0.0.1:8000/docs (Swagger). Its page design loads
  from the internet; the API itself does not need internet.

## E/F. What to click and what should appear (clean DB, user arjun)

| Click | Expected on screen |
|---|---|
| **Dashboard** | Watchlists **2**, Active alert rules **3**, Recent alerts **0**, Instruments **7**; "No alerts yet"; watchlists Crypto (BTCUSDT, ETHUSDT) and Long Term (HDFCBANK, RELIANCE, TCS), each "no price data yet" |
| **Watchlists** | same two lists; each item shows "No price data yet" |
| **Alert Rules** | #1 RELIANCE ▲ABOVE 3,000.00 INR (300 s), #2 RELIANCE ▼BELOW 2,800.00 (300 s), #3 BTCUSDT ▲ABOVE 100,000.00 USDT (60 s), all ACTIVE |
| **Instruments** | 7 rows (2 BINANCE, 5 NSE); "Latest price & history" → "No price data yet" |
| Demo user → **priya** | watchlists Auto (M&M), Tech (INFY, TCS); rules #4 TCS BELOW 3500 (0 s), #5 INFY ABOVE 1600 **DISABLED** |
| Demo user → **kavya** | watchlist Main (BTCUSDT, INFY, RELIANCE); rule #6 ETHUSDT BELOW 3000 (120 s) |

Switch back to **arjun** before continuing.

## G. Guaranteed offline alert demo (no internet)

### G1. Replay: 30 ticks, 8 alerts

1. In the website, click **Live refresh: OFF** so it turns to **ON**
   (green). The page then re-reads the data every 5 s.
2. In **Terminal 2**:
   ```sh
   cd "/Users/aditi/dbms project"
   source .venv/bin/activate
   python -m app.replay data/replay_prices.csv --delay-ms 300 --run-id demo1
   ```
3. It prints 30 lines, some followed by `ALERT event=…`, and ends with
   `Inserted: 30`, `Duplicates: 0`, `Errors: 0`, `Alerts: 8`.
4. Press **Refresh** in the website (or wait 5 s with Live refresh ON).

Where to look afterwards (user arjun):

| View | What you see |
|---|---|
| Dashboard | Recent alerts **5** (arjun's share of the 8), 5 newest alerts listed |
| Watchlists | latest prices: RELIANCE **2,788.00 INR**, TCS **3,490.00 INR**, BTCUSDT **100,400.00 USDT**, ETHUSDT **2,994.60 USDT**; HDFCBANK still "No price data yet" (not in the replay) |
| Instruments → RELIANCE → "Latest price & history" | latest 2,788.00 INR, source **REPLAY**, chart and 12-row history |
| Alert Rules | the same rules; alerts never change a rule |
| Alert History | 5 rows: RELIANCE ▲3000 at 3,002.40 and at 3,021.50, BTCUSDT ▲100000 at 100,120.00 and at 100,400.00, RELIANCE ▼2800 at 2,795.00 |
| priya / kavya | priya 2 alerts (TCS ▼3500), kavya 1 (ETHUSDT ▼3000). INFY (rule 5) fires none, because that rule is DISABLED |

The 8 alerts in detail are in docs/FACT_SHEET.md ("Demo feed facts") and
data/README.md.

### G2. Idempotency: run the SAME command again

```sh
python -m app.replay data/replay_prices.csv --run-id demo1
```
It prints `Retrying run demo1: …` and ends with **`Inserted: 0`,
`Duplicates: 30`, `Alerts: 0`**. The same run ID gives the same
`source_event_id`s, so the UNIQUE key (source, instrument_id,
source_event_id) makes PostgreSQL refuse to store anything twice.

If you instead run a **new** replay straight away (another or no
`--run-id`), it refuses:
`ERROR: these instruments already have ticks up to …`. That is its
safety check, not a bug; reset first (§B).

## G3. Manual alert demo through the website (deterministic)

Pick the variant that matches where you are:

**(a) After the replay (the 10-minute demo): use HDFCBANK, which the
replay never touches.**
1. **Alert Rules** → Instrument `NSE · HDFCBANK`, Direction `ABOVE`,
   Threshold `1700`, Cooldown `300` → **Create rule**. A new rule
   appears as ACTIVE.
2. **Demo** → Pick instrument `NSE · HDFCBANK` → Price `1690` → **Send
   tick**. The result is **INSERTED** and "No alert fired for arjun on
   this tick" (the first tick has no previous price).
3. Price `1710` → **Send tick**. The result is **INSERTED**, and "Alerts
   recorded for arjun by this tick" shows HDFCBANK ▲ABOVE 1,700.00 at
   1,710.00 INR.
4. **Resend last tick** → **DUPLICATE**, "– (nothing stored)".
5. **Alert History** shows the new row on top. Dashboard: Active rules
   **4**, Recent alerts **6**.

**(b) On a freshly reset DB with no replay: use seeded rule #1 (arjun,
RELIANCE ABOVE 3000, cooldown 300 s).** Demo view, RELIANCE:

| Send | Result | Why |
|---|---|---|
| 2990 | no alert | first tick: nothing to compare with |
| 3010 | **1 alert** (rule 1) | 2990 < 3000 and 3010 ≥ 3000: a crossing |
| 3020 | no new alert | still above: edge-triggered |
| 2990 | no alert | back below 3000, but the BELOW rule is 2800 |
| 3010 | no new alert | crossed again within the 300 s cooldown |

⚠ Don't run (b) and then the replay: rule 1's cooldown would swallow
the replay's first RELIANCE alert, giving 7 instead of 8.

The path to say out loud: **browser → POST /ticks/ingest → FastAPI →
ingest_tick() (locks RELIANCE, inserts the tick) → AFTER INSERT trigger
compares the previous and new price → INSERT into alert_events →
GET /users/1/alerts → Alert History.**

## H. Optional live Binance demo (needs internet)

Do this **before** the replay (right after §D), or after a reset. The
live feed refuses to start after a replay: "Stored replay data is ahead
of real time. Reset the demo database before starting live mode."

```sh
python -m app.live_feed --symbols ETHUSDT --max-events 20
```
- **Output:** `Connecting to wss://data-stream.binance.vision/…`, then
  20 lines like `… ETHUSDT 2715.44 vol=0.2212 aggTrade:2089679993 ->
  INSERTED tick=N`, then a summary.
- **Website:** Instruments → ETHUSDT → latest price source **BINANCE**.
  With Live refresh ON, the chart moves.
- **What it proves:** real external market data goes through the same
  ingest_tick() path, keyed by Binance's own trade ID (`aggTrade:<id>`)
  and Binance's trade time.
- **It usually creates no alert:** today ETH ≈ 2,700 is already below
  kavya's 3000, and BTC is far from arjun's 100000. That is correct.
  The replay is the alert demo.
- **Stop early:** Ctrl+C. It stops in about 1 s and prints a summary.
- **Checked on 2026-09-25:** after 20 live ETH ticks, the replay still
  gave 30 ticks and 8 alerts. If the replay says "already have ticks
  up to …", wait 2 seconds and run it again.

## I. Prove it's really in PostgreSQL

```sh
psql -d stock_watchlist -f sql/08_inspect_live.sql
```
It runs read-only and shows:
- row counts
- ticks per **source** (REPLAY / MANUAL / BINANCE) with first and last
  time
- the latest 10 ticks with price, volume, source, source_event_id,
  observed_at and ingested_at
- the latest 10 alert_events joined to user, rule, price and time

Extra one-liners for the examiner:
```sh
psql -d stock_watchlist -c "SELECT * FROM alert_events ORDER BY event_id;"      # only 4 columns: normalized
psql -d stock_watchlist -c "\d price_ticks"                                      # constraints + index
psql -d stock_watchlist -c "SELECT * FROM ingest_tick('NSE','TCS', now(), 3480, NULL, 'MANUAL', 'viva-1');"
```
The last command returns INSERTED; running it again returns DUPLICATE.
Afterwards, reset (§K) so the database is clean again.

## J. If something fails

| Problem | Do this |
|---|---|
| No internet / Binance blocked | Skip §H. Everything else is offline. Say: "the live feed is optional; the replay uses the same ingest_tick → trigger → alert_events path" |
| /docs page is blank | Swagger's page design needs internet. Show http://127.0.0.1:8000/openapi.json, or the website itself |
| Badge says "Database unavailable" | `brew services start postgresql@18`, then press Refresh |
| Badge says "Server unreachable" | Terminal 1 stopped: start uvicorn again (§C) |
| Replay: "already have ticks up to …" | a replay/live run already happened: `bash scripts/reset_demo_db.sh`, then replay |
| Live feed: "Stored replay data is ahead of real time" | expected after a replay: reset first, or skip live |
| Live feed: "Reconnecting in …" / "gave up" | network problem: Ctrl+C and use the replay |
| Manual tick fires no alert after a replay | it was late (the replay's ticks are in the future): use HDFCBANK (§G3a) or reset |
| Website shows old data | press Refresh (or switch Live refresh ON) |

## K. Clean up after the demo

1. Ctrl+C in Terminal 1 (uvicorn) and in any running feed.
2. `bash scripts/reset_demo_db.sh` and check the last line says `3|7|5|11|6|0|0`.

---

## 5-minute safest demo (no internet needed)

| Min | Do | Say |
|---|---|---|
| 0:00 | (before) §B reset, §C start, browser open on Dashboard | "7 tables in PostgreSQL; this site only calls the FastAPI API" |
| 0:30 | Watchlists, then Alert Rules | "watchlist_items is the M:N junction; rules are ABOVE/BELOW with a cooldown" |
| 1:30 | Live refresh ON; Terminal 2: replay `--delay-ms 300 --run-id demo1` | "every CSV row goes through ingest_tick; the trigger decides alerts" |
| 2:30 | Dashboard / Alert History (5 alerts for arjun) | "edge-triggered: only a crossing fires; staying above doesn't" |
| 3:30 | the same replay command again → 0 inserted, 30 duplicate | "idempotent: UNIQUE (source, instrument, source_event_id)" |
| 4:15 | `psql -d stock_watchlist -f sql/08_inspect_live.sql` | "real rows; alert_events stores only ids, the rest comes from joins" |

## 10-minute full demo

1. §B reset, §C start, §D browser (before the examiner arrives).
2. Tour (1 min): Dashboard, Watchlists, Alert Rules, Instruments; switch
   the user to priya (DISABLED rule) and back to arjun.
3. *(optional, internet)* §H live: `python -m app.live_feed --symbols
   ETHUSDT --max-events 20`; Instruments → ETHUSDT shows source BINANCE.
4. §G1 replay with Live refresh ON → 8 alerts; show Alert History and
   the RELIANCE chart.
5. §G2 same run_id again → 0 inserted, 30 duplicate.
6. §G3a manual alert: create HDFCBANK ABOVE 1700 → ticks 1690 → 1710 →
   alert → Resend → DUPLICATE.
7. §I inspector in psql.
8. Mention the tests: `bash scripts/run_all_tests.sh` (run earlier;
   show the screenshot).
9. After the examiner leaves: §K reset.
