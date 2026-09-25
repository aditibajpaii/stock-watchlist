# Viva Notes

Study material for the oral exam, not report text. Each entry has:
WHY (the plain reason), VIVA (a likely question) and ANSWER (a short
answer to understand, not memorise).

Schema and normalization Q&A: docs/NORMALIZATION_NOTES.md §9 and the Phase
3 quiz. This file covers Phase 4, the ingestion path and the alert engine.

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
| One active feed per instrument | replay = stocks, Binance = crypto |
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

WHY: a demo must not depend on the internet, market hours or luck.
VIVA: "Why build a replay at all?"
ANSWER:
- It works offline, when markets are closed, and gives the same prices
  every time, so we know in advance which 8 alerts fire and can test that
  automatically.
- A live feed can't guarantee a crossing during a 10-minute viva.
- Both use the same ingest_tick path, so a working replay also shows the
  live path works.

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
