# Viva recovery — study notes

Study notes, not a script to recite. Every answer points to an artifact you can open during questioning.
Each member should be able to answer every question without these notes, and from first principles
("because the foreign key is NOT NULL"), not from memory ("because the diagram says so").

Abbreviations for evidence files: `out/NN` = `docs/review2/sql_output/NN_*.out`; QE = `docs/review2/QUERY_EVIDENCE.md`.

---

## The 20 highest-risk questions

### 1. Why PostgreSQL?
- **Answer:** Because of features this project actually uses:
  - enforced CHECK constraints, including regular expressions (`ck_users_username_format`);
  - exact `NUMERIC` for prices; `TIMESTAMPTZ` for IST and UTC feeds; identity columns;
  - PL/pgSQL triggers that run inside the inserting transaction;
  - row locks (`SELECT … FOR NO KEY UPDATE` in `ingest_tick`) and `pg_notify`;
  - transactional DDL (the benchmark drops an index inside a transaction and rolls it back).
- **Proof:** `sql/00_schema.sql`, `sql/03_functions_triggers.sql`, `sql/07_benchmark_queries.sql`.
- **Likely follow-up:** "MySQL also has CHECK constraints." MySQL enforces them only from 8.0.16. The
  reason is the combination above, not one feature.
- **Avoid:** "it is powerful", "it is the fastest", "it handles hundreds of instruments per second". That
  last claim is in the Review 1 abstract, and nothing measured it.

### 2. Why a relational design at all?
- **Answer:** The data is structured and the rules are relational:
  - every tick belongs to an instrument;
  - one listing per (exchange, symbol);
  - one alert per (rule, tick);
  - watchlists and instruments are many-to-many.

  A tick and the alert it causes must also commit or roll back together. Keys, foreign keys and
  transactions give all of this in one system.
- **Proof:** 36 named constraints (`TABLE_CONSTRAINT_INVENTORY.md`); `out/16` T4.
- **Follow-up:** "Why not a time-series or NoSQL store for ticks?" At this scale one B-tree index
  serves the queries (`INDEX_BENCHMARK.md`). A second store would lose the foreign key from
  alert_events to the tick.
- **Avoid:** "relational is always better".

### 3. What is a conceptual ER model, and how is it different from the relational schema?
- **Answer:** The ER model describes the domain: entity types, attributes, relationship types,
  cardinality and participation. It has no foreign keys and no data types. The relational schema is
  what you get by **mapping** it: tables, columns, primary keys, foreign keys.
- **Proof:** diagram 1 `ER_CORRECTED.png` versus diagram 2 `RELATIONAL_SCHEMA.png`;
  `ER_TO_RELATIONAL_MAPPING.md`.
- **Follow-up:** "Where is `user_id` in WATCHLIST?" It is not an attribute. It is the relationship OWNS,
  and it becomes the column `watchlists.user_id` only after mapping.
- **Avoid:** calling the table diagram an ER diagram; drawing FK columns as attributes.

### 4. Cardinality versus participation
- **Answer:** Cardinality is the **maximum** (1 or N); participation is the **minimum** (must every
  entity take part?). USER OWNS WATCHLIST is 1:N. WATCHLIST participation is total because `user_id` is
  NOT NULL. USER participation is partial because a user may have no watchlist.
- **Proof:** double lines in diagram 1; `out/92` ("WATCHLIST total = FK NOT NULL (True); USER partial").
- **Follow-up:** "So is the N side always total?" No. It is total here because each FK is NOT NULL. A
  nullable FK would make it partial.
- **Avoid:** "1:N means mandatory".

### 5. How does the M:N relationship become `watchlist_items`?
- **Answer:** CONTAINS (WATCHLIST M : N INSTRUMENT, attribute `added_at`) maps to a new table. Its primary
  key is the pair (watchlist_id, instrument_id), each column is a foreign key, and `added_at` becomes a
  column.
- **Proof:** mapping step 5; `out/03` (adding RELIANCE twice to arjun "Long Term" → `pk_watchlist_items`
  23505).
- **Follow-up:** "Why not a column of symbols in watchlists?" That breaks 1NF, it cannot carry a foreign
  key, and "who watches TCS?" becomes string searching (`NORMALIZATION_PROOF.md` §10.1).
- **Avoid:** "watchlist_items is a weak entity".

### 6. Weak entity versus associative entity
- **Answer:**
  - A **weak entity** has no key of its own. It is identified by its owner's key plus a partial key,
    through an identifying relationship (a double diamond, with total participation).
  - An **associative entity** is a relationship promoted to an entity because it has its own identity
    and use. ALERT_EVENT is one: `event_id` is the notify payload and appears in the API.
  - `watchlist_items` is neither; it is a plain M:N relationship.
- **Proof:** `ER_EXPLANATION.md`; `app/schemas.py` (`AlertEvent.event_id`).
- **Follow-up:** "Then isn't WATCHLIST weak, since its name is unique only per user?" It *could* be
  modelled as weak (partial key `name`). It has its own key `watchlist_id`, so it is strong. The
  per-user rule is `UNIQUE (user_id, name)`.
- **Avoid:** "a composite primary key means a weak entity".

### 7. What are composite candidate keys, and which ones exist?
- **Answer:** A minimal set of columns that together identify a row. Here:
  - (exchange, symbol)
  - (user_id, name)
  - (source, instrument_id, source_event_id)
  - (user_id, instrument_id, direction, threshold)
  - (rule_id, tick_id)

  Each one is a business rule enforced by UNIQUE.
- **Proof:** `TABLE_CONSTRAINT_INVENTORY.md`; `out/03` (NSE RELIANCE twice → 23505, BSE RELIANCE accepted).
- **Follow-up:** "Is symbol alone a key?" No: the same symbol on another exchange is allowed.
- **Avoid:** "exchange is unique and symbol is unique".

### 8. PRIMARY KEY versus UNIQUE
- **Answer:**
  - A **PRIMARY KEY** is the chosen identifier: unique and NOT NULL, one per table, and the target of
    foreign keys.
  - A **UNIQUE** constraint records another candidate key. A table may have several, and they allow NULL
    unless the column is NOT NULL. All UNIQUE columns here are NOT NULL.
  - Both are enforced by a unique index.
- **Proof:** `pk_users` and `uq_users_username` / `uq_users_email` in the inventory.
- **Follow-up:** "Can a foreign key point at a UNIQUE column?" In PostgreSQL, yes. Here every foreign
  key points at a primary key.
- **Avoid:** "they are the same thing".

### 9. NULL versus zero
- **Answer:** NULL means *unknown*: 8 replayed ticks arrived without a volume. 0 would mean *known to
  be zero*. Aggregates skip NULLs: in AG03, `count(*)` differs from `count(volume)`. `NOT IN` against a
  list containing NULL returns nothing (S10 gives 0; the NOT EXISTS fix in S11 gives 22).
- **Proof:** QE B06, AG03, S10/S11, F02 ("unknown").
- **Follow-up:** "Why not DEFAULT 0 for volume?" It would claim no trading happened, and it would
  change averages.
- **Avoid:** "NULL is zero" or "NULL is an empty string".

### 10. Exact NUMERIC versus FLOAT
- **Answer:** `NUMERIC(18,8)` is exact decimal arithmetic, so `price >= threshold` is decided exactly at
  3000.00. Binary floating point cannot represent 0.1 exactly. Actual output from the sandbox:

  ```text
   float_equal | numeric_equal |      float_sum      | numeric_sum
  -------------+---------------+---------------------+-------------
   f           | t             | 0.30000000000000004 |         0.3
  ```
  (`SELECT 0.1::float8 + 0.2::float8 = 0.3::float8, 0.1::numeric + 0.2::numeric = 0.3::numeric, …`)
- **Proof:** column types in the inventory; QE CQ09 (`genuine_crossing = t` for all 8 events).
- **Follow-up:** "Why 8 decimal places?" Crypto quantities and small-priced pairs need them; volume is
  `NUMERIC(24,8)`.
- **Avoid:** "FLOAT is more precise".

### 11. Normalization and BCNF — prove it, don't recite it
- **Answer:** BCNF means every determinant is a candidate key. For instruments: the keys are
  {instrument_id} and {exchange, symbol}. exchange → quote_currency is false (Binance quotes ETHBTC in BTC
  and BTCUSDT in USDT). symbol → name is not a business rule. So the only determinants are keys.
- **Proof:** `NORMALIZATION_PROOF.md` §2 and the summary table.
- **Follow-up:** "Every table has an id column, so isn't BCNF automatic?" No. A surrogate key doesn't
  remove dependencies among the other columns; the natural keys must be checked as well.
- **Avoid:** "BCNF because every table has a primary key".

### 12. Why doesn't alert_events copy the price or the instrument?
- **Answer:** tick_id → price and tick_id → instrument_id hold, and tick_id is part of the candidate key
  (rule_id, tick_id). Storing them would be a partial dependency, which breaks **2NF**. The data is
  reached by joins (J01). The "same instrument" rule is checked by a trigger on alert_events instead.
- **Proof:** `NORMALIZATION_PROOF.md` §8; QE J01.
- **Follow-up:** "Isn't fired_at determined by the tick?" No. `fired_at` is the time the event row was
  recorded (`DEFAULT now()`). Today every event is recorded inside the tick's own transaction, so its
  value equals the tick's `ingested_at`. That comes from the current write path, not from a rule about
  the data: an event recorded later (re-evaluation, manual correction) would legitimately differ, and the
  database accepts that (proof §9; `out/21` C1–C3). So tick_id → fired_at is not an FD and the table is
  in BCNF.
- **Avoid:** "fired_at is the tick's time", and claiming a 2NF violation from the application path.

### 13. How do the constraints protect integrity?
- **Answer:**
  - **domain:** CHECK and NOT NULL;
  - **entity:** primary keys;
  - **uniqueness:** UNIQUE alternate keys;
  - **referential:** foreign keys with CASCADE or RESTRICT;
  - **across tables:** a trigger.

  The database rejects bad data whatever program sends it: API, replay, live feed or psql.
- **Proof:** `out/03`: 13 real rejections with SQLSTATEs (23505, 23503, 23514, 23502, 428C9, 23001).
- **Follow-up:** "Why not just validate in the app?" Each client would need the same checks, and any
  path that skips them would corrupt the data. The database is the one place all paths go through.
- **Avoid:** "the frontend validates it".

### 14. What do your triggers do?
- **Answer:**
  - `trg_price_ticks_evaluate_alerts` (AFTER INSERT on price_ticks) compares the new price with the
    previous tick of the same instrument. It records an alert only on a **crossing** and only after the
    rule's cooldown in market time. It runs in the same transaction as the insert.
  - `trg_alert_events_check_instrument` (BEFORE INSERT/UPDATE on alert_events) rejects an event whose
    rule and tick belong to different instruments.
- **Proof:** `out/14`: 2788 → 3010 records one event; staying above at 3025 records none; a RELIANCE
  rule with a TCS tick → 23514.
- **Follow-up:** "Why AFTER and not BEFORE INSERT for alerts?" The alert row references the new tick's
  `tick_id`, which exists only once the tick row is inserted. AFTER also guarantees the tick passed
  every constraint first.
- **Follow-up:** "Can the same-instrument rule still be broken?" Yes, by changing `instrument_id` on
  alert_rules or price_ticks afterwards: PostgreSQL accepts it (`out/22`). No application path does
  that (the PATCH endpoint only changes `is_active` and `cooldown_seconds`), so it holds for all
  application writes. Do not claim more than that. If asked how to close the gap: make `instrument_id`
  immutable on both parent tables with two BEFORE UPDATE OF instrument_id triggers. That fix is
  written and tested in a throwaway database, but **not applied** (`PROPOSED_INTEGRITY_FIX.md`).
- **Avoid:** "triggers run in a separate transaction".

### 15. Why a stored function for ingestion?
- **Answer:** `ingest_tick` does three things in one server-side call that replay, live feed and API all
  share: lock the instrument row, insert or report DUPLICATE, and let the trigger run. The rules are
  identical for every client, and two ticks of the same instrument are processed one at a time.
- **Proof:** `sql/03_functions_triggers.sql`; `tests/concurrency_test.sh` (17 checks); `out/03` (DUPLICATE).
- **Follow-up:** "Is database logic testable?" It is tested: 50 alert tests and 17 concurrency checks
  run in `scripts/run_all_tests.sh`.
- **Avoid:** "functions are always faster".

### 16. Procedure versus function
- **Answer:**

  | | FUNCTION | PROCEDURE |
  |---|---|---|
  | Returns | a value | results through OUT/INOUT parameters |
  | Called by | SELECT (usable inside queries) | CALL |
  | Transaction control | cannot COMMIT or ROLLBACK | can, when it is not inside an outer transaction block and not SECURITY DEFINER |

  In this project:
  - functions: `ingest_tick`, `review2.fn_latest_price`, `review2.fn_rule_distance_pct`;
  - procedures: `review2.sp_add_watchlist_item`, `review2.sp_set_rule_active`;
  - trigger functions (not callable directly): `evaluate_price_alerts`, `check_alert_event_instrument`.
- **Proof:** `out/13`: CALL returns `p_previous`; `SELECT` on a procedure → 42809; calling a trigger
  function → 0A000.
- **Avoid:** "a procedure is a function that returns void".

### 17. Why this index, and what does it cost?
- **Answer:** `ix_price_ticks_instrument_time (instrument_id, observed_at DESC, tick_id DESC)` matches
  the commonest access: "latest or previous tick of ONE instrument". It has the equality column first,
  then the order columns, so LIMIT 1 reads a few index entries with no Sort. The cost is 19 MB (about
  41% of the 48 MB table at 500,000 rows) plus one extra index write per tick.
- **Proof:** `INDEX_BENCHMARK.md` §5–6 (medians of 7 runs, 2026-09-25); raw `docs/benchmark_results/`;
  fresh EXPLAIN in `out/91`.
- **Follow-up:** "Why not an index on observed_at only, or BRIN?" Neither is per instrument or ordered
  by it; BRIN was measured and rejected (§7).
- **Avoid:** "indexes always make queries faster". Writes pay for them, and tiny tables may still be
  read with a sequential scan.

### 18. What does EXPLAIN ANALYZE prove?
- **Answer:** It **runs** the query and reports the plan actually used, with actual row counts, buffer
  reads and time. Comparing runs with and without the index on the same 500,000 rows shows the access
  path change: Sort removed, buffers down from 6,371 to 16 for "latest 50" (benchmark medians). Times
  depend on cache and machine, so report medians and buffers, not one run.
- **Proof:** `INDEX_BENCHMARK.md` (medians of 7 runs). `out/91` is one fresh run on the same data. Its
  timings differ from the medians, because single runs vary with cache state. Its buffer counts tell the
  same story: "latest 50" read 6,380 shared buffers without the index and 16 with it.
- **Follow-up:** "Plain EXPLAIN?" That only *estimates*; it does not execute.
- **Avoid:** quoting a single timing as "the" speed-up.

### 19. How does a transaction work here (ACID)?
- **Answer:**
  - **Atomicity:** a tick and the alert its trigger creates commit or roll back together (T4: +1/+1,
    then 0/0 after ROLLBACK).
  - **Consistency:** every constraint holds at commit (T3: the duplicate watchlist is rejected).
  - **Isolation:** `ingest_tick` locks the instrument row (`FOR NO KEY UPDATE`), so concurrent ticks of
    one instrument are evaluated in order, under READ COMMITTED.
  - **Durability:** after COMMIT a new connection sees the data (T5). PostgreSQL's write-ahead log keeps
    it across a crash.

  SAVEPOINT / ROLLBACK TO SAVEPOINT undo only part of a transaction (T3).
- **Proof:** `out/16`; `tests/concurrency_test.sh`.
- **Follow-up:** "What happens after an error inside a transaction?" Every statement fails with 25P02
  until ROLLBACK or ROLLBACK TO SAVEPOINT (shown in T3).
- **Avoid:** "ROLLBACK can undo a committed transaction".

### 20. Why GRANT and REVOKE? Isn't a view enough?
- **Answer:** Least privilege means each role gets only what its job needs:
  - analyst: market data and an aggregated view, no emails;
  - support: changes cooldowns only through view V3, and switches rules only through a SECURITY DEFINER
    procedure;
  - feed: inserts ticks only through a definer function.

  A view alone hides nothing. Only missing privileges on the base table do. REVOKE removes a right:
  shown before and after for `SELECT ON price_ticks`, and for the default PUBLIC EXECUTE on routines.
- **Proof:** `out/17` (privilege matrix, `\dp`, 11 denials); `out/93` (password login on a throwaway
  server: wrong password refused, NOLOGIN refused, `system_user = scram-sha-256:r2_analyst`, 5 denials).
- **Follow-up:** "Is SET ROLE a login?" No. SET ROLE only switches the privileges in force; the session
  was authenticated as the superuser. A login is a new session whose `session_user` is the restricted
  role, and authentication is when the server checks the password (`system_user` shows the method).
- **Follow-up:** "What is the risk of SECURITY DEFINER?" The routine runs with its owner's rights. So:
  the owner is the non-superuser `r2_owner`, `search_path` is pinned, and PUBLIC EXECUTE is revoked.
- **Avoid:** "the view stops users reading the table".

---

## One relationship, end to end (practise explaining this aloud)

1. **Conceptual:** WATCHLIST —M— CONTAINS —N— INSTRUMENT, with attribute `added_at`. Both sides are partial:
   a watchlist may be empty, and an instrument may be watched by nobody.
2. **Mapping:** the M:N relationship becomes table `watchlist_items(watchlist_id, instrument_id, added_at)`,
   with PK (watchlist_id, instrument_id). Each column is a foreign key.
3. **DDL** (`sql/00_schema.sql` lines 72–82): `pk_watchlist_items`; `fk_watchlist_items_watchlist … ON
   DELETE CASCADE`; `fk_watchlist_items_instrument … ON DELETE RESTRICT`.
4. **Constraint working:** the same instrument twice on one list → 23505 (`out/03`).
5. **SQL query:** "What does kavya's Main watchlist contain, at what latest price?" (view V1, `out/12`)
6. **Actual output:**

   ```text
    watchlist |  symbol  |     instrument_name     |  latest_price
   -----------+----------+-------------------------+-----------------
    Main      | BTCUSDT  | Bitcoin / Tether        | 100400.00000000
    Main      | INFY     | Infosys Ltd             |   1612.00000000
    Main      | RELIANCE | Reliance Industries Ltd |   2788.00000000
   (3 rows)
   ```

   Three rows, because kavya's Main has three watchlist_items rows (seed); the latest prices come from the
   last replayed tick of each instrument.

## Review 1 mistakes you must be able to explain (and not repeat)

- Arrowheads on ER lines, and no total participation.
- `Watchlist_item` drawn as a weak entity.
- Natural keys missing from the ER diagram.
- The ER diagram and the tables section contradicting each other.
- No screenshots, and no normalization section.

Each is listed with its correction in `DESIGN_CHANGE_LOG.md`.
