# Normalization Notes (study material, not report text)

Based on the LIVE schema (PostgreSQL 18.6, `stock_watchlist`), which was
verified to match docs/PHASE1_SPEC.md by `sql/verify_spec.sql`.

---

## 0. Terms in one line each

| Term | Meaning |
|---|---|
| Functional dependency (FD) X → Y | two rows that agree on X must agree on Y |
| Trivial FD | Y ⊆ X, e.g. (a, b) → a. Always true, so ignored |
| Superkey | a set of columns whose values are never repeated across rows |
| Candidate key | a minimal superkey: remove any column and it stops being unique |
| Primary key | the candidate key chosen as the main identifier |
| Alternate key | any other candidate key (declared here with UNIQUE) |
| Prime attribute | a column that belongs to some candidate key |
| Non-prime attribute | a column that belongs to no candidate key |
| Partial dependency | a non-prime column depends on only part of a composite candidate key (breaks 2NF) |
| Transitive dependency | key → X → Y where X is not a key and Y is non-prime (breaks 3NF) |

## 0.1 The tests used for every table

| NF | Test applied |
|---|---|
| 1NF | every column holds one atomic value; no repeating groups or lists; a PK exists, so there are no duplicate rows |
| 2NF | 1NF, and no non-prime column depends on a proper subset of any composite candidate key |
| 3NF | 2NF, and for every non-trivial FD X → A, X is a superkey or A is prime |
| BCNF | for every non-trivial FD X → A, X is a superkey |

Shortcut: if the only non-trivial FDs are "candidate key → other
columns", the table is in BCNF, which implies 3NF, 2NF and 1NF.
Normalization therefore comes down to finding every real FD, and in
particular any hidden one whose left side is not a key.

## 0.2 What is (and isn't) an FD

- An FD is a rule about all legal data, not about the rows that happen to
  be in the table today.
- One counterexample that the schema allows is enough to disprove an FD.
- Counterexamples below were inserted in a rolled-back transaction on
  2026-09-25 to prove the schema accepts them.

---

## 1. users

Columns: user_id, username, email, created_at

| Item | Value |
|---|---|
| PK | user_id |
| Candidate keys | {user_id}, {username}, {email} |
| Prime attributes | user_id, username, email |
| Non-prime | created_at |

FDs (non-trivial):
- user_id → username, email, created_at
- username → user_id, email, created_at
- email → user_id, username, created_at

Checks:
- **1NF:** each column is a single value. One email per user, stored as
  one TEXT, not a list. PK present.
- **2NF:** every candidate key is a single column, so no proper subset
  exists and a partial dependency is impossible.
- **3NF:** the only non-prime column, created_at, determines nothing, so
  there is no X → Y chain through a non-key.
- **BCNF:** every determinant (user_id, username, email) is a candidate
  key. ✔ **BCNF**

---

## 2. instruments

Columns: instrument_id, exchange, symbol, name, quote_currency, is_active

| Item | Value |
|---|---|
| PK | instrument_id |
| Candidate keys | {instrument_id}, {exchange, symbol} |
| Prime | instrument_id, exchange, symbol |
| Non-prime | name, quote_currency, is_active |

FDs (non-trivial):
- instrument_id → exchange, symbol, name, quote_currency, is_active
- (exchange, symbol) → instrument_id, name, quote_currency, is_active

FDs checked and rejected, with the counterexample the schema accepts:

| Candidate FD | Counterexample | Verdict |
|---|---|---|
| symbol → name | NSE RELIANCE and BSE RELIANCE share a symbol; in general different companies can share a ticker on different exchanges | not an FD |
| exchange → quote_currency | BINANCE BTCUSDT = USDT, BINANCE ETHBTC = BTC | not an FD |
| name → anything | NSE and BSE RELIANCE share the same name | not an FD |
| exchange → asset_class | would be TRUE (BINANCE is always crypto) | **removed the column in Phase 1** |

Checks:
- **1NF:** all columns atomic. Exchange and symbol are separate columns,
  not one "NSE:RELIANCE" string.
- **2NF:** composite CK (exchange, symbol). Neither exchange alone nor
  symbol alone determines name, quote_currency or is_active (table
  above), so there is no partial dependency.
- **3NF:** no non-prime column determines another. name does not
  determine quote_currency, and nothing depends on is_active.
- **BCNF:** the determinants are instrument_id and (exchange, symbol),
  both keys. ✔ **BCNF**

Nuance for the viva:
- "Every NSE instrument is priced in INR" is true, but it is not an FD,
  because it fails for BINANCE. An FD must hold for every value of
  exchange.
- If the project ever only listed exchanges with one currency each, the
  FD would appear and quote_currency should move to an exchanges table.

---

## 3. watchlists

Columns: watchlist_id, user_id, name, created_at

| Item | Value |
|---|---|
| PK | watchlist_id |
| Candidate keys | {watchlist_id}, {user_id, name} |
| Prime | watchlist_id, user_id, name |
| Non-prime | created_at |

FDs:
- watchlist_id → user_id, name, created_at
- (user_id, name) → watchlist_id, created_at

Checks:
- **1NF:** atomic, with a PK. The list's contents are NOT stored here;
  they live in watchlist_items.
- **2NF:** composite CK (user_id, name).
  - user_id → created_at is false, because one user has many lists
    created at different times.
  - name → created_at is false, because two users can both have
    "Crypto".
  - So there is no partial dependency.
- **3NF:** created_at is the only non-prime column and determines nothing.
- **BCNF:** both determinants are keys. ✔ **BCNF**

---

## 4. watchlist_items (junction table)

Columns: watchlist_id, instrument_id, added_at

| Item | Value |
|---|---|
| PK | (watchlist_id, instrument_id) |
| Candidate keys | {watchlist_id, instrument_id} only |
| Prime | watchlist_id, instrument_id |
| Non-prime | added_at |

FDs:
- (watchlist_id, instrument_id) → added_at

Partial-dependency check (the key test for this table):

| Proper subset | → added_at? | Why |
|---|---|---|
| watchlist_id | no | one list gets instruments added at different times |
| instrument_id | no | the same instrument is added to different lists at different times |

Checks:
- **1NF:** one instrument per row, never a list of symbols.
- **2NF:** added_at needs the whole key (table above), so there is no
  partial dependency.
- **3NF:** there is one non-prime column, so no chain is possible.
- **BCNF:** the only determinant is the whole PK. ✔ **BCNF**

What was deliberately NOT stored here, because it would break 2NF:
- user_id: watchlist_id → user_id is a partial dependency. The owner is
  found through watchlists.
- symbol or name: instrument_id → symbol is a partial dependency. These
  are found through instruments.

---

## 5. price_ticks

Columns: tick_id, instrument_id, observed_at, price, volume, source,
source_event_id, ingested_at

| Item | Value |
|---|---|
| PK | tick_id (surrogate) |
| Candidate keys | {tick_id}, {source, instrument_id, source_event_id} |
| Prime | tick_id, source, instrument_id, source_event_id |
| Non-prime | observed_at, price, volume, ingested_at |

FDs:
- tick_id → all other columns
- (source, instrument_id, source_event_id) → all other columns

FDs checked and rejected:

| Candidate FD | Why false | Proven by |
|---|---|---|
| (instrument_id, observed_at) → price | two real trades can share a timestamp at different prices | schema test A10 accepts it |
| (source, source_event_id) → instrument_id | Binance trade ids repeat across symbols | schema test A9 accepts it |
| (source, instrument_id) → anything | many ticks per feed per instrument | obvious |
| observed_at → ingested_at | late or delayed ticks arrive at different times | by design |

Checks:
- **1NF:** atomic values, and volume is a single nullable number. See
  the source_event_id note below.
- **2NF:** composite CK (source, instrument_id, source_event_id). No
  subset determines observed_at, price, volume or ingested_at (table
  above), so there is no partial dependency.
- **3NF:** no non-prime column determines another. price does not
  determine volume, and observed_at does not determine price.
- **BCNF:** the determinants are tick_id and the 3-column key, both
  keys. ✔ **BCNF**

1NF note on source_event_id:
- Replay ids look like `demo1:000001`, which a person reads as
  "run demo1, row 1".
- It stays atomic because the database never splits it: no query
  filters on a part of it, and it is only ever compared as a whole
  identifier. Binance ids are opaque numbers used the same way.
- Rule to keep: if a feature ever needs "all ticks of run demo1", add a
  proper column instead of `LIKE 'demo1:%'`.

volume NULL:
- NULL means "unknown", and 0 means "known to be zero".
- A NULL does not break 1NF, because it is still a single value per
  cell.

---

## 6. alert_rules

Columns: rule_id, user_id, instrument_id, direction, threshold,
cooldown_seconds, is_active, created_at

| Item | Value |
|---|---|
| PK | rule_id |
| Candidate keys | {rule_id}, {user_id, instrument_id, direction, threshold} |
| Prime | rule_id, user_id, instrument_id, direction, threshold |
| Non-prime | cooldown_seconds, is_active, created_at |

FDs:
- rule_id → all other columns
- (user_id, instrument_id, direction, threshold) → rule_id,
  cooldown_seconds, is_active, created_at

Minimality check (why all four columns are needed in the alternate key):

| Drop | Legal counterexample |
|---|---|
| threshold | arjun, RELIANCE, ABOVE 3000 and ABOVE 3100 |
| direction | arjun, RELIANCE, ABOVE 3000 and BELOW 3000 |
| instrument_id | arjun, ABOVE 3000 on RELIANCE and on TCS |
| user_id | arjun and kavya, both RELIANCE ABOVE 3000 |

Partial-dependency check:
- (user_id, instrument_id) → cooldown_seconds is false, because the same
  user and instrument can have different rules with different cooldowns.
  The seed has arjun/RELIANCE ABOVE and BELOW; both use 300, but nothing
  forces that.
- No subset determines is_active or created_at either.

Checks:
- **1NF:** one direction and one threshold per row. A rule with two
  thresholds is two rows.
- **2NF:** no partial dependency (above).
- **3NF:** no non-prime column determines another.
- **BCNF:** the determinants are rule_id and the 4-column key, both
  keys. ✔ **BCNF**

---

## 7. alert_events

Columns: event_id, rule_id, tick_id, fired_at

| Item | Value |
|---|---|
| PK | event_id |
| Candidate keys | {event_id}, {rule_id, tick_id} |
| Prime | event_id, rule_id, tick_id |
| Non-prime | fired_at |

FDs:
- event_id → rule_id, tick_id, fired_at
- (rule_id, tick_id) → event_id, fired_at

Partial-dependency check:
- rule_id → fired_at is false, because one rule fires many times.
- tick_id → fired_at is false, because one tick can fire several rules.

Checks:
- **1NF:** atomic, with a PK.
- **2NF:** no partial dependency (above).
- **3NF:** fired_at determines nothing.
- **BCNF:** both determinants are keys. ✔ **BCNF**

What was deliberately NOT stored, because it would break 3NF:

| Column | Hidden FD it would create | Found instead via |
|---|---|---|
| instrument_id | tick_id → instrument_id (and rule_id → instrument_id) | price_ticks or alert_rules |
| observed_at | tick_id → observed_at | price_ticks |
| price | tick_id → price | price_ticks |

With any of these present, event_id → tick_id → price would be a
transitive dependency: the left side tick_id is not a key of
alert_events, and price is non-prime.

Not a normalization issue, but an integrity rule:
- The rule's instrument must equal the tick's instrument.
- This is a constraint across two tables, not an FD inside one.
- Phase 4 enforces it with a BEFORE INSERT trigger, without adding a
  column.

---

## 8. Summary

| Table | PK | Candidate keys | Composite CK? | Partial dep? | Transitive dep? | NF |
|---|---|---|---|---|---|---|
| users | user_id | user_id; username; email | no | impossible | none | BCNF |
| instruments | instrument_id | instrument_id; (exchange, symbol) | yes | none | none | BCNF |
| watchlists | watchlist_id | watchlist_id; (user_id, name) | yes | none | none | BCNF |
| watchlist_items | (watchlist_id, instrument_id) | same | yes | none | none | BCNF |
| price_ticks | tick_id | tick_id; (source, instrument_id, source_event_id) | yes | none | none | BCNF |
| alert_rules | rule_id | rule_id; (user_id, instrument_id, direction, threshold) | yes | none | none | BCNF |
| alert_events | event_id | event_id; (rule_id, tick_id) | yes | none | none | BCNF |

Design decisions that keep these results true:
- asset_class was removed (exchange → asset_class).
- alert_events has no copied price, observed_at or instrument_id.
- watchlist_items has no user_id and no symbol.
- The M:N relationship is a junction table, not a list column.

---

## 9. Five key examples (with WHY / VIVA / ANSWER)

### 9.1 Junction table vs comma-separated symbols

Bad design:

| watchlist_id | name | symbols |
|---|---|---|
| 2 | Long Term | RELIANCE,TCS,HDFCBANK |

Problems:
- It breaks 1NF, because one cell holds a list.
- You cannot put a FK on "TCS" inside a string, so a typo like
  "TSC" is stored silently.
- Duplicates: nothing stops "TCS,TCS".
- Removing one symbol means rewriting the string, and two concurrent
  edits can overwrite each other.
- "Which lists contain TCS?" needs string search, which cannot use a
  normal index well.
- There is no place to store per-item facts like added_at.

Actual design: one row per (list, instrument) in watchlist_items.
- The FK checks each instrument exists.
- The composite PK blocks duplicates.
- Removing an instrument is one DELETE of one row.

WHY: a list inside a cell hides many facts in one value, so the DBMS
cannot check or index them.
VIVA: "Why not store the symbols as a comma-separated column?"
ANSWER: It breaks 1NF. With a junction table each pair is one row, so FK
and PK constraints can enforce "the instrument exists" and "no
duplicates", and the M:N relationship is queryable.

### 9.2 tick_id PK while (source, instrument_id, source_event_id) is also a candidate key

- Both identify a tick uniquely, so both are candidate keys.
- tick_id was chosen as PK because it is one small BIGINT:
  - alert_events references it with one column instead of three.
  - Joins and indexes stay small.
  - It never changes.
- The natural key is still enforced with UNIQUE, so its guarantee is not
  lost.
- It is the duplicate detector: the same provider event arriving twice
  is rejected.

WHY: the surrogate PK is for referencing, and the natural key is for
correctness. Keeping both gives both.
VIVA: "If tick_id is the PK, what stops the same tick being stored twice?"
ANSWER: The UNIQUE constraint on (source, instrument_id, source_event_id).
Schema test A8 shows a second insert of the same event is rejected with
uq_price_ticks_source_event.

### 9.3 Why observed_at is NOT part of tick identity

- Two different real trades can happen in the same millisecond, and
  crypto feeds do this often.
- If (instrument_id, observed_at) were unique, the second genuine trade
  would be rejected as a "duplicate" and lost.
- Two copies of the same event always share the provider's event id, so
  the event id is the correct duplicate test.
- Schema test A10: same instrument, same observed_at, different event id
  → accepted.
- Ordering still works: ties are broken with (observed_at, tick_id).

WHY: a timestamp tells you when something happened, not which thing
happened.
VIVA: "Why not make (instrument_id, observed_at) the key?"
ANSWER: Timestamps can legitimately repeat, so that key would throw away
real data. Identity comes from the source's event id, and observed_at is
only used for ordering.

### 9.4 Why alert_events does not duplicate instrument_id, observed_at, price

- Every one of those is already determined by tick_id (price_ticks row).
- Copying them creates tick_id → price inside alert_events, a transitive
  dependency, so the table would no longer be in 3NF.
- Practical harm: the copies could disagree with the tick (an update
  anomaly), and every event stores data twice.
- Retrieval is a single join:
  ```sql
  SELECT e.event_id, i.symbol, t.observed_at, t.price
  FROM alert_events e
  JOIN price_ticks  t ON t.tick_id = e.tick_id
  JOIN instruments  i ON i.instrument_id = t.instrument_id;
  ```
- Ticks can't silently change behind the event: fk_alert_events_tick is
  RESTRICT, and ticks are append-only by design.

WHY: store each fact once, in the table whose key determines it.
VIVA: "Wouldn't storing the price in the event be faster?"
ANSWER: Slightly, but it duplicates a fact tick_id already determines,
which breaks 3NF and risks the two copies disagreeing. The join goes
through primary keys, so it is cheap.

### 9.5 Why alert_rules has the alternate key (user_id, instrument_id, direction, threshold)

- These four columns are what a rule means: "this user, this
  instrument, this direction, this price".
- Without the key, a double-click could create two identical rules, and
  one crossing would produce two alerts for the same thing.
- All four are needed (see the minimality table in section 6).
- cooldown_seconds and is_active are settings of a rule, not part of
  what it means, so they are excluded.
- rule_id is still the PK: alert_events references one BIGINT, not four
  columns.
- The key relies on the design rule that these four columns never
  change after creation.

WHY: the surrogate key identifies the row, and the alternate key stops
two rows meaning the same thing.
VIVA: "Why do you need a UNIQUE constraint if rule_id is already the PK?"
ANSWER: rule_id is always unique, even for two identical rules. The
UNIQUE on the four defining columns is what stops a user creating the
same rule twice, as schema test A11 shows.

---

## 10. Concerns found during this review (none is a normalization error)

| # | Concern | Status |
|---|---|---|
| 1 | source_event_id looks composite ("run:row") | atomic as long as it is never parsed in SQL; rule recorded above |
| 2 | "NSE ⇒ INR" is true in reality | not an FD (BINANCE counterexample); revisit only if all exchanges become single-currency |
| 3 | rule instrument = tick instrument across tables | integrity rule, not normalization; Phase 4 trigger |
| 4 | the alert_rules alternate key assumes immutable definition columns | design rule, not DB-enforced (approved) |
