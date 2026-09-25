# Viva Notes

Study material for the oral exam, not report text. Each entry has:
WHY (the plain reason), VIVA (a likely question) and ANSWER (a short
answer to understand, not memorise).

Order: the top-15 list, then schema/constraints (S1–S10), then the
alert engine (0–15), replay (16–25), indexing (26–38), API (39–50),
frontend (51–60) and live feed (61–70). Longer normalization worked
examples: docs/NORMALIZATION_NOTES.md §9. Every number here comes from
our own tests or benchmark.

---

## Top 15 to know cold

| # | Question | Where |
|---|---|---|
| 1 | Why 7 tables, and what does each hold? | S1 |
| 2 | What normal form is the schema in, and how do you know? | S3 |
| 3 | Why doesn't alert_events store price or symbol? | S4 |
| 4 | PK vs UNIQUE; why the composite PK on watchlist_items? | S5, S6 |
| 5 | CASCADE vs RESTRICT: which FKs use which, and why? | S8 |
| 6 | What does "edge-triggered" mean? ABOVE/BELOW rules exactly? | 6 |
| 7 | Why no alert on the first tick? | 7 |
| 8 | Cooldown: why observed_at, not fired_at? | 9 |
| 9 | What stops duplicate ticks and duplicate alerts? | 10, 64 |
| 10 | What is a late tick and what happens to it? | 8 |
| 11 | What race does the instrument lock prevent? Why not a plain INSERT? | 1, 2 |
| 12 | READ COMMITTED: what does it mean here? | 5 |
| 13 | Why this index and column order? What did EXPLAIN ANALYZE show? | 29, 32, 35 |
| 14 | Why does the browser call FastAPI, not PostgreSQL? Why parameterized SQL? | 53, 41 |
| 15 | What if Binance/internet fails in the viva? | 66 |

---

## S. Schema, normalization and constraints (short spoken answers)

### S1. Why 7 tables?

VIVA: "Why these tables and not more or fewer?"
ANSWER: One table per real thing or relationship:
- **users**: who. **instruments**: what can be watched, identified by
  (exchange, symbol).
- **watchlists**: named lists owned by a user.
- **watchlist_items**: the M:N link between watchlists and instruments.
- **price_ticks**: market events, one row per price.
- **alert_rules**: a user's condition ("RELIANCE ABOVE 3000").
- **alert_events**: each time a rule actually fired on a tick.

Left out on purpose:
- **latest_price**: derivable from price_ticks with the index (note 56).
- **alert_state**: not needed. The previous tick is found with the
  index, and every hard case (concurrency, ties, late ticks, cooldown,
  duplicates) passed the Phase 4 tests without it.
- **asset_class column**: would break 3NF (S3).

### S2. Candidate keys

VIVA: "What are the candidate keys of price_ticks / alert_rules?"
ANSWER (the PK is listed first; the others are UNIQUE constraints):
- users: {user_id}, {username}, {email}
- instruments: {instrument_id}, {exchange, symbol}
- watchlists: {watchlist_id}, {user_id, name}
- watchlist_items: {watchlist_id, instrument_id}
- price_ticks: {tick_id}, {source, instrument_id, source_event_id}
- alert_rules: {rule_id}, {user_id, instrument_id, direction, threshold}
- alert_events: {event_id}, {rule_id, tick_id}

### S3. What normal form?

VIVA: "Prove the schema is normalized."
ANSWER:
- **BCNF, all 7 tables.** In every table, every determinant of a
  non-trivial FD is a candidate key (FD table in FACT_SHEET, per-table
  proof in NORMALIZATION_NOTES).
- **1NF:** atomic values; no lists in a cell (watchlist_items instead of
  "RELIANCE,TCS").
- **2NF:** no attribute depends on part of a composite key; e.g. added_at
  needs both watchlist_id and instrument_id.
- **3NF/BCNF:** no transitive dependencies. That is why there is no
  asset_class (exchange → asset_class), no user_id in watchlist_items
  (watchlist_id → user_id), and no price in alert_events (tick_id → price).
- **Checked with counterexamples**, e.g. BINANCE has both USDT and BTC
  quote currencies, so exchange ↛ quote_currency.

### S4. Why doesn't alert_events store price, symbol or observed_at?

VIVA: "Wouldn't copying the price make alert history simpler?"
ANSWER: tick_id already determines price, observed_at and instrument.
Copying them adds tick_id → price inside alert_events, a transitive
dependency, so the table would no longer be in 3NF. The copies could
disagree with the tick (update anomaly), and they waste space. One join
gets them back (GET /users/{id}/alerts, sql/08_inspect_live.sql).
alert_events stays (event_id, rule_id, tick_id, fired_at).

### S5. PK vs UNIQUE

VIVA: "What's the difference, and why does price_ticks have both?"
ANSWER:
- **PRIMARY KEY:** the one chosen identifier. Implies NOT NULL, one per
  table, and it is what FKs reference.
- **UNIQUE:** enforces the other candidate keys. Both create a B-tree
  index.
- price_ticks: PK tick_id (small, stable, one column for alert_events to
  reference) plus UNIQUE (source, instrument_id, source_event_id), the
  duplicate detector.
- All our UNIQUE columns are NOT NULL, so NULL loopholes don't apply.

### S6. Why a composite PK on watchlist_items?

VIVA: "Why no watchlist_item_id?"
ANSWER: The row *is* the pair (watchlist, instrument). PK
(watchlist_id, instrument_id) states that fact and blocks adding the same
instrument twice (the API turns that error into "RELIANCE is already in
this watchlist."). A surrogate id would still need UNIQUE on the pair,
and nothing references this table.

### S7. FK and CHECK constraints

VIVA: "Give an example of each and show it working."
ANSWER:
- **8 named FKs.** E.g. fk_price_ticks_instrument: a tick for a missing
  instrument fails with 23503.
- **14 named CHECKs.** E.g. price > 0, direction IN ('ABOVE','BELOW'),
  source IN ('REPLAY','BINANCE','MANUAL'), cooldown_seconds >= 0,
  volume NULL or >= 0.
- **Proof:** sql/02_schema_tests.sql, 51 tests. Groups: A unique 12,
  B check 16, C FK 8, D restrict 5, E cascade 10. Each negative test
  checks the exact SQLSTATE *and* constraint name.
- **36 named constraints in total:** 7 PK, 8 FK, 7 UNIQUE, 14 CHECK.

### S8. CASCADE vs RESTRICT

VIVA: "What happens when you delete a user? An instrument?"
ANSWER: Ownership policy.
- **CASCADE for user-owned data:** users → watchlists → watchlist_items,
  users → alert_rules → alert_events. Deleting a user removes everything
  they own.
- **RESTRICT for shared market data:** instruments → price_ticks /
  watchlist_items / alert_rules, and price_ticks → alert_events. You
  can't delete an instrument that has ticks, or a tick that has alerts.
- **So** deleting a user or a watchlist never deletes price history
  (tests E3–E8). The UI disables rules rather than deleting them,
  because deleting a rule cascades to its alert history.

### S9. Why TIMESTAMPTZ and NUMERIC?

VIVA: "Why not FLOAT for prices?"
ANSWER:
- **NUMERIC(18,8) is exact decimal.** FLOAT is binary: 0.1 + 0.2 ≠ 0.3,
  and a threshold compare like 3000.00 >= 3000 must be exact.
- **End to end:** Python uses Decimal, and JSON carries strings
  ("0.00000001").
- **TIMESTAMPTZ stores an absolute instant**, so Binance's UTC trade time
  and IST display never get confused. Naive timestamps are rejected by
  the API (422).

### S10. Why is ingestion a function, and what else is enforced where?

VIVA: "Which rules live in the database and which in Python?"
ANSWER:
- **In the database:** everything that protects data. That means the
  constraints, the duplicate check (UNIQUE), the lock and alert logic
  (ingest_tick plus triggers), and rule/tick instrument consistency
  (integrity trigger).
- **In Python:** only earlier, friendlier messages (Pydantic, CSV
  validation), never the guarantee.
- **Three design rules are not DB-enforced** (note 46): ingestion only
  via ingest_tick, immutable rule definitions, append-only ticks.

---

## 0. Words you must be able to explain

| Term | Plain meaning |
|---|---|
| Trigger | code the database runs automatically when a row is inserted/updated/deleted |
| BEFORE trigger | runs before the row is written; can reject it |
| AFTER trigger | runs after the row is written, in the same transaction |
| FOR EACH ROW | trigger runs once per affected row (NEW = that row) |
| PL/pgSQL | PostgreSQL's procedural language (variables, IF, loops) for functions |
| Row lock | a lock on one table row; others wanting a conflicting lock on that row wait |
| FOR NO KEY UPDATE | row lock mode: "I may change non-key columns"; conflicts with itself, NOT with FK checks |
| READ COMMITTED | each SQL statement sees data committed before that statement started |
| Snapshot | the set of committed data a statement is allowed to see |
| Edge-triggered | react to a *change of state* (below → above), not to being in a state |
| Level-triggered | react every time the condition is true (would repeat alerts) |
| LISTEN / NOTIFY | PostgreSQL's built-in publish/subscribe message between sessions |
| SQLSTATE | 5-character error code (e.g. 23505 unique_violation) |
| Idempotent | doing it twice has the same effect as doing it once |

---

## 1. Why a function (ingest_tick) instead of a plain INSERT?

WHY: all feeds must follow the same steps (find the instrument, lock it,
insert, handle duplicates), and code kept inside the database cannot be
skipped by any client.
VIVA: "Why not let Python insert into price_ticks directly?"
ANSWER: ingest_tick takes the instrument lock before inserting, rejects
unknown or inactive instruments, and reports duplicates. With plain
INSERTs every client would have to remember those steps, and the
concurrency test shows what happens when they don't: a direct INSERT
race produced two alerts for one crossing.

## 2. Why lock the instrument row, and why BEFORE inserting?

WHY: alert detection compares a new tick with the previous tick. Two
transactions for the same instrument must not both see the same "previous"
price.
VIVA: "Two RELIANCE prices arrive at the same moment. What happens?"
ANSWER: The first call locks the RELIANCE row in instruments, and the
second one waits on that lock before inserting anything. After the first
commits, the second continues, sees the first tick as its previous
price, and evaluates correctly. Concurrency scenario 1 shows this: B
waited about 2 s and only one alert was created. The control run
without the lock produced two alerts.

Follow-up: "Why lock before, not after, inserting?"
- If B inserted first and locked afterwards, B's tick would already be
  in the table with a tick_id taken before A committed.
- Locking first means B's tick_id is assigned after A has finished, so
  tick_id order matches the real processing order for that instrument.

## 3. Why FOR NO KEY UPDATE and not FOR UPDATE?

WHY: take the weakest lock that still serializes ingestion.
VIVA: "Doesn't locking the instruments row block everything that uses
that instrument?"
ANSWER: No.
- FOR NO KEY UPDATE conflicts with another FOR NO KEY UPDATE, so two
  ingesters queue up.
- It does not conflict with FOR KEY SHARE, the lock that FK checks take.
  Adding RELIANCE to a watchlist, or inserting its tick, isn't blocked.
- FOR UPDATE would also block those FK checks for no benefit.

## 4. Why only instruments are locked, not rules?

WHY: every rule belongs to exactly one instrument.
VIVA: "Two rules on RELIANCE: could they be evaluated inconsistently?"
ANSWER: No. All ticks for RELIANCE are serialized by one lock, and every
RELIANCE rule is evaluated inside that serialized section, so one lock
covers them all. Different instruments still ingest in parallel.

## 5. Why does READ COMMITTED matter here?

WHY: after waiting for the lock, B must see A's newly committed tick.
VIVA: "After B gets the lock, how does it know about A's tick?"
ANSWER: Under READ COMMITTED each statement gets a fresh snapshot. The
INSERT and the trigger's queries run after the lock was granted, so
they see A's committed tick. That is the database's normal default. We
don't add code that checks the isolation level; SERIALIZABLE is a
separate later experiment.

## 6. Edge-triggered alerts

WHY: users want one alert when the price crosses, not one for every tick
while it stays above.
VIVA: "Price goes 2990 → 3005 → 3010 → 3020 with an ABOVE 3000 rule. How
many alerts?"
ANSWER: One. The alert fires on the tick where previous < 3000 and
new ≥ 3000. For 3010 and 3020 the previous tick is already ≥ 3000, so
there is no crossing (tests 02–03, demo 2).

Exact rules:
- ABOVE fires when prev < T and new ≥ T.
- BELOW fires when prev > T and new ≤ T.

Follow-up: "What if the price lands exactly on 3000?"
- 2990 → 3000 fires, because 3000 counts as "above side" (test 07a).
- A later 3000 → 3010 does not fire again (test 07b).

## 7. Why no alert on the first tick?

WHY: a crossing needs two prices.
VIVA: "The first RELIANCE tick is 3050 and there's an ABOVE 3000 rule.
Why no alert?"
ANSWER: With no previous price we can't know the price moved from below
to above. It may always have been above. So there is no alert (test 01c,
demo 1).

## 8. Late ticks

WHY: delayed data must not create alerts about the past, and must not
distort future comparisons.
VIVA: "A tick with an older timestamp arrives after newer ones. What
happens?"
ANSWER:
- It is stored, because it is real history, but no alerts are evaluated
  for it.
- It never becomes the "previous" tick of later ticks, because ordering
  is by observed_at and a newer tick already exists.
- Test 13d: after a late 3050, the next tick 3010 was compared with the
  real previous 2995 and fired correctly.

Follow-up: "What if two ticks have the same observed_at?" Not late; the
order is broken by tick_id (test 12).

## 9. Cooldown uses observed_at, not fired_at

WHY: market time is what the rule is about, and it makes replays give
the same results every time.
VIVA: "Why not measure cooldown with fired_at?"
ANSWER: fired_at is the wall-clock time the database processed the tick.
In a fast replay, 10 minutes of market data can arrive in 2 seconds, and
fired_at-based cooldown would suppress nearly everything. Using the
tick's observed_at gives the same result at any replay speed. Test 10d
proves it: 3 events share one fired_at yet fired at market times 10,
400 and 700 s.

Follow-up: "What happens to a crossing inside the cooldown?"
- It is dropped, not queued.
- If the price then stays above, there is no new edge, so no later alert
  either (test 09b).

## 10. Duplicate protection: two layers

WHY: feeds retry and reconnect, and the same trade may be sent twice.
VIVA: "The replay crashes and is restarted with the same run id. Do users
get double alerts?"
ANSWER: No.
- Layer 1: UNIQUE (source, instrument_id, source_event_id) plus
  ON CONFLICT DO NOTHING. The repeated tick is not inserted, the trigger
  never fires, and ingest_tick returns DUPLICATE.
- Layer 2: UNIQUE (rule_id, tick_id) on alert_events, a final guard that
  one rule never fires twice for one tick (tests 11, 19).

## 11. Why is the integrity check a trigger, not a constraint?

WHY: the rule "event's rule and tick belong to the same instrument"
spans three tables, and alert_events deliberately has no instrument_id
column.
VIVA: "A CHECK constraint would be simpler. Why a trigger?"
ANSWER: A CHECK can only see columns of its own row. Doing this with FKs
would need instrument_id copied into alert_events, and that is the
tick_id → instrument_id transitive dependency we removed for 3NF. A
BEFORE INSERT/UPDATE trigger reads both parents and rejects a mismatch
(tests 14a, 14b, demo 6).

Honest limitation: the trigger checks when an event is written. It
doesn't re-check if someone later changes alert_rules.instrument_id. We
treat rule definitions as immutable by design, and there is no app
endpoint that edits them.

## 12. NOTIFY is a wake-up signal, not the data

WHY: messages can be missed (listener offline), but table rows are
durable.
VIVA: "Why send only the event_id in NOTIFY?"
ANSWER: alert_events is the source of truth. The backend, on waking up,
reads the row by id. If the backend was down, it can still find missed
events with a query. The payload stays tiny.

Follow-up: "What if the transaction rolls back after pg_notify?"
- NOTIFY is transactional: it is delivered only on COMMIT.
- Concurrency scenario 4 shows the rolled-back crossing produced no
  notification, and the listener got exactly the one committed event_id.

## 13. Why is the trigger AFTER INSERT, not BEFORE?

WHY: the event must reference the tick's tick_id, and the tick must be in
the table so the foreign key accepts the event.
VIVA: "Could the alert logic run in a BEFORE trigger?"
ANSWER: In a BEFORE trigger the tick is not stored yet. With
ON CONFLICT DO NOTHING a BEFORE trigger even runs for duplicates that
will not be inserted. AFTER INSERT runs only for rows actually inserted,
so duplicates never trigger alerts.

## 14. Rollback: nothing survives

WHY: a transaction is all-or-nothing, and the trigger runs inside the
same transaction as the insert.
VIVA: "The server crashes after the alert is inserted but before commit.
Is there a half-alert?"
ANSWER: No. The tick, the alert event and the notification belong to one
transaction; uncommitted work is discarded (tests 18a–18d, demo 7).

Side fact: sequence/identity numbers used by a rolled-back transaction
are not reused, so tick_id/event_id values can have gaps. Gaps are normal
and harmless; ids are identifiers, not counters.

## 15. Known limits (say these before the examiner finds them)

| Limit | Why acceptable |
|---|---|
| A direct INSERT into price_ticks skips the lock | not an app path; all feeds use ingest_tick (CLAUDE.md rule) |
| A multi-row INSERT into price_ticks: rows in one statement see each other in the AFTER trigger | benchmark bulk loads disable alerts / use a separate setup (Phase 6) |
| ingested_at = now() = transaction start time | one tick per transaction in real ingestion, so the values differ in practice |
| One active feed per instrument | don't run replay and live feed on the same instrument at once (their timelines would make each other's ticks late) |
| The integrity trigger doesn't watch later edits to alert_rules.instrument_id | rule definition is immutable by design; no edit endpoint |

---

## Phase 5 – Offline replay

### 16. Why replay through ingest_tick instead of INSERT?

WHY: the replay must exercise the same path as the future live feed, and
ingest_tick holds the rules (lock, duplicate handling, instrument checks).
VIVA: "Your Python program could just INSERT into price_ticks. Why call a
function?"
ANSWER: A plain INSERT would skip the instrument lock (Phase 4 showed that
causes duplicate alerts under concurrency) and give no clean DUPLICATE
result. Calling ingest_tick means the database decides, and replay,
Binance and manual input all behave the same.

### 17. Why does each replay run have a run_id?

WHY: a tick's identity is (source, instrument, source_event_id), so replay
event ids need something that tells one run apart from another.
VIVA: "What is the run_id for?"
ANSWER: source_event_id = run_id + ':' + row number. Within one run, row 7
always has the same id, so a retry can't insert it twice. A different run
has different ids, so its rows are new events.

### 18. Why can the same CSV be replayed more than once?

WHY: a replay represents a new stream of market events each time you
deliberately start it.
VIVA: "If I replay the same file twice, are those duplicates?"
ANSWER: Not if it's a new intentional run. The new UUID run_id gives new
source_event_ids, and new timestamps (run start = now), so they are new
events. By design they are stored and can fire alerts again.

### 19. Why does retrying one run produce DUPLICATE?

WHY: after a crash or network problem you must be able to resend safely.
VIVA: "The replay stopped at row 10. You restart it. What happens to rows
1–10?"
ANSWER: Restart with the same --run-id. Rows 1–10 have the same
source_event_ids, so the UNIQUE constraint makes ingest_tick return
DUPLICATE. Nothing is stored twice and no alert repeats. Rows 11–30 are
inserted on the original timeline, because the program recovers the
original run start from row 1's stored tick (test 06b).

### 20. Why rebase timestamps (observed_at = run_start + offset)?

WHY: the alert engine treats older market times as "late" and ignores
them.
VIVA: "Why not store fixed historical timestamps in the CSV?"
ANSWER: The second replay of fixed timestamps would be older than ticks
already stored, so every tick would be late and no alert would fire.
Rebasing makes each run behave like a live stream starting now. The
offsets keep the spacing between events, and cooldowns are measured on
it.

Follow-up: "What if you start a new run while the previous run's ticks
are still in the future?"
- Their ticks run up to run_start + 460 s, so a new run inside that
  window would start "in the past" and all its ticks would be late.
- The program detects this and refuses with an explanation.
  --start-after-latest starts 1 s after the last stored tick instead.

Follow-up: "Why doesn't --delay-ms depend on the offsets?"
- The offset is logical market time, and the delay is how long a human
  waits.
- A 460 s logical feed can be shown in 9 s with --delay-ms 300, and
  alerts and cooldowns still behave as if 460 s passed.

### 21. Why is replay useful when a live feed exists?

See note 66 (offline, deterministic: always 30 ticks and 8 alerts, same
ingest_tick path as live).

### 22. Why still need database constraints if Python validates input?

WHY: the database is the last line of defence, and Python is only one of
several clients.
VIVA: "Python already rejects negative prices. Isn't the CHECK constraint
redundant?"
ANSWER:
- Python validation gives early, friendly errors (whole file checked, 0
  rows sent).
- But psql users, the future web app and the Binance feed don't run this
  Python code, and Python doesn't know every limit. Test 14:
  999999999999 passed Python validation but the database rejected it
  (NUMERIC(18,8) overflow, SQLSTATE 22003).
- Constraints guarantee the rule for every client.

### 23. Why one transaction per event?

WHY: short transactions mean prompt visibility and short lock times.
VIVA: "Why not load all 30 rows in one transaction? It would be faster."
ANSWER:
- One transaction per row means each price and its alerts are visible,
  and the NOTIFY delivered, as soon as that row commits, which is what a
  live UI needs.
- ingest_tick's instrument lock is held for milliseconds, not the whole
  file.
- A bad row rolls back only itself.
- Also, one transaction around rows of the same instrument would keep
  that lock until the end of the file.

Follow-up: "What happens on an error?" That event rolls back, the error
and its SQLSTATE are printed, the replay stops and exits with code 2.
Rows already committed stay; they were independent events.
(--continue-on-error keeps going but still exits 2.)

### 24. Why does the second back-to-back run give 7 alerts, not 8?

WHY: market history is continuous across runs.
VIVA: "Same file, same rules. Why a different alert count?"
ANSWER: Cooldown is measured from the last alert's market time, even if
that alert came from the previous run.
- The previous run's last rule-1 alert is its row 27, at +400 s.
- The new run starts 1 s after the previous run's last tick (+460 s), so
  its row 6 (+20 s) is at previous +481 s.
- The gap is 481 − 400 = 81 s, inside rule 1's 300 s cooldown, so row 6
  is suppressed.
- On a freshly seeded DB there is no earlier alert, so all 8 fire.

### 25. Why no password in the code?

WHY: secrets must never be committed.
VIVA: "How does the program connect to the database?"
ANSWER: From environment variables (DB_NAME, DB_HOST, DB_PORT, DB_USER),
with local defaults. The local server trusts local connections, so no
password exists. If one were needed, libpq reads PGPASSWORD or
~/.pgpass, which are never stored in the repository.

---

## Phase 6 – Indexing (numbers from docs/INDEX_BENCHMARK.md, 500,000 ticks)

### 26. What is an index?

WHY: finding rows without reading the whole table.
VIVA: "What is an index?"
ANSWER: A separate, sorted data structure that maps column values to the
rows (their physical locations) holding them, like a book's index. The
DBMS maintains it automatically on every INSERT, UPDATE and DELETE.

### 27. Why does price_ticks need one?

WHY: it is the only table that grows without limit, and our hottest
queries ask for "one instrument, in time order".
VIVA: "Why index price_ticks and not the other tables?"
ANSWER:
- The other tables are tiny: 3 users, 7 instruments, 6 rules. The ticks
  table grows with every price.
- Without our index, "latest 50 RELIANCE ticks" read all 6,371 table
  pages and sorted 25,000 rows: 9.461 ms. With it, 16 pages and no sort:
  0.020 ms.
- It matters most for the alert trigger. ingest_tick went from 30.081 ms
  to 0.199 ms per tick, because the trigger's late-tick check had been a
  sequential scan over 500,001 rows on every insert.

### 28. What is a B-tree?

WHY: it is PostgreSQL's default index and supports equality, ranges and
ordering.
VIVA: "Explain a B-tree."
ANSWER: A balanced tree of pages. The internal pages hold separator keys,
the leaf pages hold (key → row pointer) entries in sorted order and are
linked to their neighbours. Every leaf is at the same depth, so a lookup
costs a few page reads (3–4 here), and after finding a start point you
can walk the leaves in order (or backwards) for ranges and ORDER BY.

### 29. Why this column order: (instrument_id, observed_at DESC, tick_id DESC)?

WHY: a composite B-tree is sorted by the first column, then the second
within it, and so on, like a phone book (surname, then first name).
VIVA: "Why does instrument_id come first?"
ANSWER: Every query has `instrument_id = ?`. Putting it first groups each
instrument's ticks into one contiguous part of the index. With
observed_at first, one instrument's ticks would be scattered among all
the others'.

VIVA: "Why observed_at second?"
ANSWER: Within one instrument we filter and sort by time: time ranges,
latest-first, the previous tick. Because it comes right after the
equality column, the index is already in the order ORDER BY wants.

VIVA: "Why is tick_id in the index?"
ANSWER:
- Our ordering is (observed_at, tick_id), because timestamps can repeat.
- Including tick_id makes the index order match ORDER BY exactly, so
  `LIMIT 1` needs no sort even with equal timestamps.
- It also lets the trigger's row comparison `(observed_at, tick_id) < (…)`
  be an index condition (4 buffers).

VIVA: "Why DESC?"
ANSWER:
- The most frequent access is "latest first" (UI, previous tick, late
  check), and DESC makes that a plain forward scan.
- An all-ASC index would work almost identically: a B-tree can be
  scanned backwards (`Index Scan Backward`).
- DESC only really matters when one query mixes directions. So it states
  our intent; it isn't strictly required.

### 30. Why not index every column?

WHY: every index costs space and slows every write.
VIVA: "Why not add an index on every foreign key, or every column?"
ANSWER:
- Each index must be updated on every INSERT and uses disk. Ours adds
  19 MB to a 48 MB table (100 → 120 MB total).
- We add an index only where a measured query needs it. The alert
  cooldown lookup filters alert_events by rule_id, and
  uq_alert_events_rule_tick (rule_id, tick_id) already starts with
  rule_id, so no new index was needed there.
- Tiny tables like alert_rules (6 rows) are fastest to read with a Seq
  Scan anyway.

### 31. What is the write cost of an index?

WHY: an index trades faster reads for extra work on writes.
VIVA: "Doesn't the index slow down inserting prices?"
ANSWER:
- Each new tick adds one entry to this B-tree: a few page reads and one
  write.
- Here it's a net win even for writes: ingest_tick got 150× faster, because
  the trigger *reads* this same index on every insert.
- UPDATE/DELETE costs don't apply in practice, because ticks are
  append-only.
- Heavy bulk loads would be slower. That is why the benchmark load ran
  before creating the index, which is also the usual technique.

### 32. What does EXPLAIN ANALYZE do?

WHY: to see what the database actually did, not guess.
VIVA: "What's the difference between EXPLAIN and EXPLAIN ANALYZE?"
ANSWER:
- EXPLAIN shows the plan and the planner's *estimated* costs and rows.
- EXPLAIN ANALYZE also *runs* the query and adds actual times and row
  counts per plan node.
- BUFFERS adds how many 8 kB pages were read: hit = from memory, read =
  from disk.
- For writing queries, wrap it in BEGIN … ROLLBACK, because ANALYZE
  really executes them.

### 33. Sequential Scan vs Index Scan

WHY: they are the two basic ways to read a table.
VIVA: "Difference between a Seq Scan and an Index Scan?"
ANSWER:
- A Seq Scan reads every page of the table in physical order and tests
  each row. That's cheap per page, but reads everything: 500,001 rows
  removed in the trigger's baseline late check.
- An Index Scan walks the B-tree to the matching entries, then fetches
  only those rows.
- An Index *Only* Scan never touches the table, when every needed column
  is in the index and the visibility map says the pages are all-visible.
  Our late check: `Heap Fetches: 0`, 3 buffers.
- A Bitmap scan is in between: it collects matching row locations from
  the index, then reads those pages in physical order.

### 34. Why can PostgreSQL choose not to use an index?

WHY: the planner is cost-based and picks the cheapest *estimated* plan.
VIVA: "You created an index. Why doesn't PostgreSQL always use it?"
ANSWER:
- It compares estimated costs. If a query needs a large fraction of the
  table, or the table is tiny, a Seq Scan (sequential pages) beats many
  random index lookups.
- Our own example: query B (900 rows over ~220 pages) still chose Bitmap
  Heap Scan + Sort rather than an ordered Index Scan, and it was right
  (0.328 ms).
- On the 7-row seed database, a Seq Scan is cheapest.
- Stale statistics can also mislead it, which is why we ran ANALYZE after
  loading.

### 35. B-tree vs BRIN

WHY: BRIN is PostgreSQL's tiny index for huge, naturally ordered tables.
VIVA: "Why not use BRIN for time-series data?"
ANSWER:
- BRIN stores just min/max of a column per block range (128 pages). Ours
  was **24 kB** vs 19 MB for the B-tree.
- It helps only when the query limits that column's range AND rows are
  physically in that order. It helped our 30-min range (3.166 ms vs
  4.539 ms baseline), but the B-tree was still 10× faster (0.328 ms).
- BRIN can't give rows in order and knows nothing about instrument_id, so
  it didn't help "latest N for one instrument" or the previous-tick
  lookup at all.
- Those are our main queries, so we kept only the B-tree.

### 36. Why not TimescaleDB?

WHY: fewer moving parts, and the course is about core DBMS features.
VIVA: "Isn't TimescaleDB built for this?"
ANSWER:
- TimescaleDB is a PostgreSQL extension for very large time-series
  (automatic partitioning into "chunks", compression).
- Our scale, well under millions of rows, is served in microseconds by one
  standard B-tree, as measured.
- Adding an extension would hide the database concepts we're meant to
  demonstrate, and adds an installation dependency.

### 37. Why is partitioning unnecessary here?

WHY: partitioning solves problems we don't have yet.
VIVA: "Shouldn't a price history table be partitioned by date?"
ANSWER:
- Partitioning splits a table into child tables, e.g. one per month. It
  helps when tables reach tens or hundreds of millions of rows (dropping
  old months instantly, vacuum per partition, pruning scans).
- At 500,000 rows our indexed lookups read 3–16 pages.
- It would complicate the schema (the PK must include the partition key)
  and our UNIQUE constraint, for no measured benefit.
- It stays a documented future option.

### 38. PostgreSQL 18 skip scan (a detail an examiner might spot)

WHY: the "before" plan wasn't a plain Seq Scan.
VIVA: "Your baseline used uq_price_ticks_source_event for instrument_id.
How, if instrument_id is its second column?"
ANSWER:
- PostgreSQL 18 added B-tree skip scan. When the leading column (source)
  has few distinct values, it does one index search per value
  (`Index Searches: 2`).
- It found the right rows but not in time order, and they were spread
  over every heap page. So it still read 6,371 pages and sorted.
- Our index serves both the filter and the order.

---

## Phase 7 – FastAPI backend

### 39. Why FastAPI?

WHY: small, typed, and gives interactive API documentation for free.
VIVA: "Why FastAPI and not Flask or Django?"
ANSWER:
- Request bodies are declared as Python classes (Pydantic), so bad input
  is rejected with a clear 422 before any SQL runs.
- It generates /docs (Swagger) automatically, which lets us demonstrate
  the API without a frontend.
- Django brings its own ORM and admin, which we deliberately don't use.
  Flask would need extra libraries for validation and docs.

### 40. Why no ORM?

WHY: the DBMS work must stay visible and in PostgreSQL.
VIVA: "Why not SQLAlchemy?"
ANSWER:
- An ORM generates SQL for you and tends to move rules into Python
  classes.
- Our core logic is database objects: CHECK/UNIQUE/FK constraints,
  ingest_tick(), triggers, a LATERAL join, a tuned index. Plain SQL shows
  exactly what runs, e.g. the watchlist query, and matches what we
  benchmarked with EXPLAIN.
- Every statement is readable in app/main.py.

### 41. Why parameterized SQL?

WHY: it prevents SQL injection, where user input gets executed as SQL.
VIVA: "How do you prevent SQL injection?"
ANSWER:
- Values are never pasted into the SQL text. They are sent separately as
  parameters (`%s`), and PostgreSQL treats them purely as data.
- Optional filters are assembled only from fixed SQL fragments with
  psycopg's `sql.SQL`.
- Test 29: `NSE' OR '1'='1` as an exchange filter returns an empty list,
  and `x'); DROP TABLE users; --` becomes an ordinary watchlist name. The
  users table is untouched.

### 42. Why keep alert logic inside PostgreSQL?

See note 54.

### 43. Why no separate latest_price table?

See note 56.

### 44. Why does alert history need joins?

See notes S4 and 55.

### 45. Why does the manual ingest endpoint call ingest_tick?

WHY: one ingestion path with one set of guarantees.
VIVA: "Your API has a POST /ticks/ingest. Does it INSERT into price_ticks?"
ANSWER:
- No. It runs `SELECT status, tick_id FROM ingest_tick(..., 'MANUAL',
  ...)`, the same function the replay uses. The instrument lock,
  duplicate detection (DUPLICATE response), unknown/inactive checks
  (SW001/SW002) and the alert trigger all apply.
- A direct INSERT would skip the lock (Phase 4 showed that causes
  duplicate alerts).

### 46. What happens if someone bypasses FastAPI?

WHY: the API is just one client; psql or any other program can connect.
VIVA: "What happens if someone bypasses FastAPI?"
ANSWER: The core rules still hold, because they are in PostgreSQL:
- constraints reject bad values, duplicates and dangling references;
- the alert trigger fires on every inserted tick;
- the integrity trigger stops mismatched alert events.
What Python adds is only friendlier error messages and early rejection.

Three approved *design rules* are not enforced by the database, so a psql
user could break them:
- **Ticks go through ingest_tick.** A direct INSERT is still valid data and
  still fires the alert trigger, but it skips the concurrency lock.
- **Rule definitions are immutable.** A direct UPDATE of the threshold
  would succeed. The API simply offers no such operation.
- **Ticks are append-only.** A direct UPDATE/DELETE of an unreferenced tick
  would succeed. Ticks referenced by alerts are protected by RESTRICT.

These were deliberate Phase 1/4 decisions: no extra triggers until
justified.

### 47. Python validation vs database constraints

VIVA: "You validate price > 0 in Pydantic AND in a CHECK. Why both?"
ANSWER:
- Pydantic gives the user a clear 422 before touching the database.
- The CHECK protects the data from every other client.
- Pydantic doesn't know every database limit: threshold 999999999999
  passes Pydantic but overflows NUMERIC(18,8). The API returns a readable
  422 with sqlstate 22003, not a traceback (test 27).

### 48. Transactions in the API

VIVA: "When does the API commit?"
ANSWER:
- Each request opens its own connection.
- Every write, and every read that runs several queries (e.g. "does the
  user exist?" + fetch), runs inside `with conn.transaction():`. That
  COMMITs if the block finishes and ROLLs BACK if any error escapes, e.g.
  a duplicate or an HTTP 404 raised mid-way.
- No connection is shared between requests.

### 49. Why are prices strings in the JSON?

VIVA: "Why is price "3060.50000000" and not 3060.5?"
ANSWER: JSON numbers are usually read as binary floats, which can't
represent many decimals exactly. We keep NUMERIC → Python Decimal → JSON
string, so every stored digit survives. We also forced plain fixed-point
formatting after a test caught `0.00000001` being sent as `"1E-8"`.

### 50. Why can't the rule threshold be edited?

VIVA: "How do you stop someone changing a rule's threshold via the API?"
ANSWER:
- PATCH accepts only is_active and cooldown_seconds. The request model
  forbids unknown fields, so `{"threshold": 1}` returns 422, and the
  UPDATE statement never mentions the definition columns.
- Reason: past alert events refer to the rule, and editing its threshold
  would silently change what those events meant.
- To change a threshold: disable the old rule and create a new one.

## Phase 8 – Web frontend

### 51. Why plain HTML, CSS and JavaScript?

WHY: the marks are for the database; the UI only has to show it clearly.
VIVA: "Why no framework for the frontend?"
ANSWER:
- The UI is six views over 18 existing endpoints. Four files (index.html,
  styles.css, api.js, app.js) are enough, and every line can be
  explained.
- No build step: no npm, no bundler. FastAPI serves the files as they
  are, so the demo works offline on any laptop that has Python and
  PostgreSQL.
- There is nothing to download at demo time. No CDN script can fail over
  college Wi-Fi.

### 52. Why no React?

VIVA: "Wouldn't React be more modern?"
ANSWER:
- React pays off with large, deeply interactive UIs and teams. Ours is a
  few tables and forms that reload after each action.
- It would add Node, npm, JSX and a build step, all outside the approved
  stack, to show the same data.
- The DBMS parts (constraints, ingest_tick, triggers, the index) would
  not change at all. React adds nothing for this rubric.

### 53. Why does the browser call FastAPI and not PostgreSQL?

WHY: a browser cannot safely hold database access.
VIVA: "Why not connect the web page directly to the database?"
ANSWER:
- Browsers cannot speak PostgreSQL's wire protocol. Even if they could,
  database connection details in JavaScript would be readable by every
  visitor, who could then run any SQL.
- FastAPI is the only client of PostgreSQL. It exposes a fixed set of
  operations, uses parameterized SQL, and turns database errors into
  safe messages.
- Test 12 in test_frontend.py checks that the frontend files contain no
  password, connection string, port 5432 or database name.
- In DevTools → Network, every request goes to 127.0.0.1:8000 (FastAPI).

### 54. Why are alerts computed in PostgreSQL, not JavaScript?

VIVA: "The page already has the prices; why not check thresholds in JS?"
ANSWER:
- Alerts must fire even when no browser is open: the replay (and later
  Binance) feeds insert ticks with no page running.
- The rules need the previous tick in (observed_at, tick_id) order, the
  cooldown, late-tick detection and a lock against concurrent ingestion.
  Only the database sees every tick, and the trigger runs inside the
  inserting transaction. We proved this in the Phase 4 concurrency tests.
- The trigger runs in the same transaction as the tick insert, so a tick
  and its alert commit or roll back together.
- Replay, live feed, API and psql all behave identically, because none of
  them contains alert code.
- Each open tab computing its own alerts could disagree, fire twice, or
  miss a crossing between refreshes.
- So the page only *displays* alert_events. The Demo view finds the
  alerts for a new tick by matching tick_id in the returned list; it
  never compares a price with a threshold.

### 55. Why does alert history come from alert_events?

VIVA: "Where does the Alert History screen get its rows?"
ANSWER:
- From GET /users/{id}/alerts, which joins alert_events → alert_rules →
  price_ticks → instruments.
- alert_events is the durable record: one row per real firing, written by
  the trigger in the same transaction as the tick. If the transaction
  rolls back, neither the tick nor the event exists.
- NOTIFY (and later SSE) is only a wake-up signal. Refresh re-reads the
  table, so nothing is lost if the page was closed.
- The table stores only (event_id, rule_id, tick_id, fired_at). Symbol,
  threshold, price and observed time come from the joins, so there is no
  copied data to drift out of sync. API test 20 checks that the stored row
  has only those 4 columns.

### 56. Why is there no latest_price table?

VIVA: "Isn't it slow to find the latest price from all ticks?"
ANSWER:
- The latest price is derived data: the newest row of price_ticks for an
  instrument. Storing it again would need an extra UPDATE on every tick
  and could disagree with the ticks table (a redundancy, update anomaly).
- ix_price_ticks_instrument_time (instrument_id, observed_at DESC,
  tick_id DESC) makes the lookup an index read of the first entry. On
  500,000 ticks, latest-50 took 0.020 ms (Phase 6).
- The Watchlists view gets every item's latest price in one query
  (LEFT JOIN LATERAL … LIMIT 1), not one request per instrument.

### 57. Why relative API URLs?

VIVA: "Why does app.js call '/users' and not 'http://127.0.0.1:8000/users'?"
ANSWER:
- A relative URL goes to whichever server delivered the page. The same
  files work on another port, another machine, or behind a proxy, with
  no edits.
- Page and API share one origin, so the browser needs no CORS settings.
- Test 11 checks that there is no host, localhost or port in the JS, and
  that every api("…") path exists in the OpenAPI spec.

### 58. How does the UI avoid XSS?

VIVA: "A watchlist name could contain `<script>`. Is that dangerous?"
ANSWER:
- No. All dynamic text goes in through textContent / text nodes, via the
  `h()` helper, so the browser shows `<script>` as characters and never
  runs it.
- The code never uses innerHTML (test 13 checks this). The only HTML is
  the fixed index.html.
- SQL injection is a separate problem, handled by the API's parameterized
  SQL (note 41). XSS is handled in the browser.

### 59. Why keep decimals as strings in the browser?

VIVA: "Why not parseFloat the price?"
ANSWER:
- JavaScript numbers are binary floats: 0.1 + 0.2 ≠ 0.3.
- The API sends "3060.50000000". The UI formats that text (separators,
  trimmed zeros) without converting it. A threshold is sent as the text
  the user typed, and PostgreSQL stores it as NUMERIC(18,8).
- Number() is used in one place only: pixel positions in the SVG chart,
  where a rounding error of a millionth of a pixel does not matter.

### 60. Why does "no price data" not show as an error?

VIVA: "GET /instruments/1/latest returns 404. Is the UI broken?"
ANSWER:
- No. The API answers 404 "Instrument has no price ticks yet." for an
  instrument with no ticks. The UI recognises that case and shows "No
  price data yet".
- A real failure (server down, database down) shows a red message, and
  the header badge changes to "Server unreachable" or "Database
  unavailable".
- Every loader replaces its "Loading…" text in both the success and the
  error path, so nothing stays stuck.

### Phase 8 limits (say these before the examiner finds them)

- No live push yet. The page updates on Refresh or after your own
  action. SSE comes later.
- No login. The demo user selector just picks whose data to show.
- The client-side checks are only for quicker messages. PostgreSQL still
  enforces every rule.
- The alert list shows the latest 50 and the history table the latest 50
  or 100 ticks; there is no paging.
- The chart is deliberately simple: one line, min/max labels, first and
  last time.
- No DB Inspector view yet (it is in the project scope in CLAUDE.md, but
  was not part of the Phase 8 brief).

## Phase 9 – Optional Binance live feed

### 61. Why a WebSocket instead of calling an HTTP price endpoint repeatedly?

WHY: we need every trade, in order, as soon as it happens.
VIVA: "Why not just call a price API every few seconds?"
ANSWER:
- Polling only gives snapshots. Anything that happens between two calls
  is lost, including a price that crosses a threshold and comes back.
  Our alerts are edge-triggered, so a missed crossing is a missed alert.
- The WebSocket pushes each aggregate trade: about 20–25 per second for
  BTC/ETH (measured). Every one is stored with Binance's own trade id and
  trade time.
- One long-lived connection uses less than hundreds of requests per
  minute, and needs no API key.

### 62. Why is the live feed a separate process, not part of FastAPI?

VIVA: "Why not start the Binance connection when the API starts?"
ANSWER:
- The API must start and work without internet. An endless network loop
  inside it could slow or crash request handling, and every uvicorn
  reload or worker would open another feed.
- Running separately means one clear owner per feed ("one active feed
  per instrument"), started, limited and stopped from the command line
  like the replay.
- Both processes meet only in PostgreSQL. The API sees live ticks
  exactly as it sees replay ticks.

### 63. Why still call ingest_tick() for live events?

VIVA: "A direct INSERT would be faster. Why the function?"
ANSWER:
- It is the single official ingestion path, for REPLAY, MANUAL and
  BINANCE alike.
- It locks the instrument row before inserting. That prevents the race
  in which two concurrent ticks both see the same "previous price" and
  fire an alert twice; the Phase 4 concurrency test showed two alerts
  for one crossing without the lock.
- ON CONFLICT DO NOTHING turns re-received events into DUPLICATE, and
  the AFTER INSERT trigger evaluates the alert rules.
- The worker contains no INSERT at all (test 13a). Test 10 reads
  PostgreSQL's own statistics: ingest_tick was called once per event.
- Speed is no issue: ingest_tick takes about 0.2 ms with the index,
  while ticks arrive every 40–50 ms.

### 64. Why derive source_event_id from Binance's aggregate trade id?

VIVA: "Why 'aggTrade:2089678070' and not a random UUID?"
ANSWER:
- It must mean "this exact market event". After a reconnect, or with
  two worker runs, the same trade can arrive twice. Because the ID is
  the same, UNIQUE (source, instrument_id, source_event_id) makes the
  second one DUPLICATE, and nothing is stored twice (tests 11 and 16a;
  smoke test).
- A random UUID would make every copy look new: duplicate rows, and
  possibly a second alert.
- The ID is unique per symbol at Binance; our key includes
  instrument_id, which matches.

### 65. Why use Binance's trade time as observed_at?

VIVA: "Why not the time your program received the message?"
ANSWER:
- observed_at is *market* time. Cooldowns, "previous tick" and late-tick
  detection are all defined on it.
- Receive time includes network and processing delay (78–116 ms in the
  smoke test), and it would change if the same event were received
  again.
- We use `T` (trade time), not `E` (event time), and convert
  milliseconds with integer arithmetic to an aware UTC timestamp.
  ingested_at still records when the row arrived, so both times are
  kept.
- Many aggTrades share one millisecond (14 of 15 in the smoke test).
  The tie is broken by tick_id, as for every source.

### 66. Why keep the offline replay now that we have live prices?

VIVA: "What happens if Binance is unavailable during your demo?"
ANSWER:
- Nothing essential breaks. The live feed is optional, and on network
  failure it retries 5 times, then exits with the replay command in its
  message.
- `python -m app.replay data/replay_prices.csv --delay-ms 300` goes
  through the same ingest_tick → trigger → alert_events path.
- The replay is deterministic: always 30 ticks and exactly 8 alerts on a
  fresh database, while the live market may cross no threshold during
  the viva.
- The replay also covers NSE stocks, the project's main domain, for
  which we have no live source.

### 67. Why not scrape NSE/BSE prices?

VIVA: "Why are Indian stock prices not live?"
ANSWER:
- Scraping websites is fragile (the HTML changes), often against the
  site's terms of use, and it has no stable event id or exact trade
  time. That would break duplicate detection and market-time ordering.
- Official live NSE data needs a broker/vendor account (e.g. Upstox)
  with credentials. That is outside our scope and was never allowed to
  be a demo dependency.
- So NSE is honestly labelled replay/manual. Crypto is live only because
  Binance publishes an official, free, keyless market-data stream.

### 68. Why don't we throttle away market events?

VIVA: "20 trades a second is a lot. Why not keep one per second?"
ANSWER:
- Throttling changes the data the alert engine sees. If the price dips
  below 3000 and recovers within one second, a sampled stream might never
  show the dip, and a BELOW alert would silently not fire. Every tick we
  do store would also look like the "previous" tick of a gap.
- Growth is controlled honestly instead: one symbol, `--max-events`,
  `--duration-seconds`, Ctrl+C, and a one-command reset.
- The database handles the rate easily (≈ 0.2 ms per ingest_tick).

### 69. Why refuse to start when stored ticks are "in the future"?

VIVA: "Why does the live feed refuse after you ran the replay?"
ANSWER:
- The replay stamps ticks up to 7 min 40 s ahead of real time. A live
  trade happening now would be older than that stored tick, so
  PostgreSQL's rule classifies it as LATE: stored, but never evaluated
  for alerts.
- Instead of silently producing a feed that can't alert, the worker
  stops with "Stored replay data is ahead of real time. Reset the demo
  database…".
- It deletes nothing and does not bypass the late-tick rule. 5 s of
  clock difference is tolerated.

### 70. How does "Live refresh" differ from real-time push?

VIVA: "Is the web page real-time now?"
ANSWER:
- Nearly, but by polling. With Live refresh ON, the page re-reads the
  normal API endpoints every 5 s.
- It is off by default, never runs two refreshes at once, pauses in
  background tabs and while you type in a form, and turns itself off if
  the server or database goes away.
- True push (SSE from PostgreSQL NOTIFY) was judged unnecessary
  complexity. The durable data is in alert_events either way.

### Phase 9 limits (say these first)

- Crypto only; NSE is replay/manual.
- The feed needs internet access to Binance.
- Seed thresholds are far from today's prices, so a short live run
  usually fires no alert. That is correct behaviour, not a bug.
- The browser polls; nothing is pushed to it.
- Don't run the replay and the live feed on the same instrument at the
  same time.

---

## Quick-fire drill

1. Which table row does ingest_tick lock? *The instruments row of that
   exchange+symbol.*
2. Which lock mode, and why? *FOR NO KEY UPDATE, the weakest mode that
   still serializes ingesters without blocking FK checks.*
3. Return value on duplicate? *('DUPLICATE', NULL).*
4. Unknown instrument error code? *SW001; inactive is SW002.*
5. NOTIFY channel and payload? *`alert_events`; the event_id as text.*
6. Which timestamp drives cooldown? *observed_at of the tick behind the
   rule's last event.*
7. Name both triggers. *trg_price_ticks_evaluate_alerts (AFTER INSERT on
   price_ticks); trg_alert_events_check_instrument (BEFORE INSERT/UPDATE
   on alert_events).*
8. What did the control concurrency test show? *Without the lock, one
   crossing produced two alerts.*
9. source_event_id format for replay? *`<run_id>:<6-digit row>`.*
10. How is observed_at computed in replay? *run_start + offset_seconds.*
11. Same run_id rerun → ? *All rows DUPLICATE.*
12. Exit codes of the replay? *0 ok, 1 bad CSV/arguments, 2 DB error.*
13. How many alerts does one demo replay create on a fresh DB? *8.*
14. Name and define the performance index. *ix_price_ticks_instrument_time
    on price_ticks (instrument_id, observed_at DESC, tick_id DESC).*
15. Latest-50 query before → after? *9.461 ms, 6,371 buffers → 0.020 ms,
    16 buffers.*
16. ingest_tick before → after? *30.081 → 0.199 ms per call (500k rows).*
17. Index size vs table? *19 MB index, 48 MB table; BRIN was 24 kB.*
18. Start the API? *`uvicorn app.main:app --reload`, docs at /docs.*
19. Duplicate rule via API → ? *409 with constraint uq_alert_rules_definition.*
20. Manual ingest endpoint uses? *ingest_tick(..., 'MANUAL', ...); 201 INSERTED / 200 DUPLICATE.*
21. Deleting a rule via API also deletes? *Its alert_events (ON DELETE CASCADE); ticks stay.*
22. Frontend URL? *http://127.0.0.1:8000/, served by the same uvicorn as the API.*
23. How many fetch() calls in the frontend? *One, inside api() in api.js.*
24. Does the browser ever talk to PostgreSQL? *No, only to FastAPI (relative URLs).*
25. Where do the alerts on the page come from? *alert_events, via GET /users/{id}/alerts.*
26. Why "Resend last tick"? *Same source_event_id → DUPLICATE; shows the UNIQUE key working.*
27. Live stream used? *Binance Spot public `<symbol>@aggTrade` on wss://data-stream.binance.vision, no API key.*
28. Live source_event_id? *`aggTrade:<a>` (Binance aggregate trade id), so re-received events are DUPLICATE.*
29. Live observed_at? *Binance trade time `T` (ms) as UTC timestamptz; not receive time.*
30. Live insert path? *ingest_tick(..., 'BINANCE', ...); the worker has no INSERT.*
31. Binance down in the viva? *Use the replay: same ingest_tick → trigger → alert_events path, 8 alerts.*
32. Reset command? *psql -d stock_watchlist -f 00_schema -f 01_seed -f 03_functions_triggers -f 06_indexes → 3/7/5/11/6 rules, 0 ticks, 0 events.*
