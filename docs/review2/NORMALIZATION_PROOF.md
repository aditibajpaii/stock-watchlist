# Normalization proof — the seven tables

Scope: the implemented schema (`sql/00_schema.sql`, verified against the catalog in
`TABLE_CONSTRAINT_INVENTORY.md`). Real query output quoted here comes from
`sql/review2/20_normalization_evidence.sql` → `docs/review2/sql_output/20_normalization_evidence.out`.

Result in one line: all seven tables are in **BCNF** for the functional dependencies the business
rules below define. `alert_events.fired_at` is the time the event row was recorded (team decision, §9).
On the application write path it happens to equal the tick's `ingested_at`, but that comes from how the
current code writes rows. It is not a functional dependency of the design, and no 2NF violation is claimed.

---

## 0. Method

### Definitions used (the general ones: they consider **every** candidate key, not only the primary key)

| Term | Meaning |
|---|---|
| FD X → Y | in every **legal** state of the table, two rows that agree on X agree on Y. "Legal" is decided by the business rules, not by the rows that happen to be stored today. |
| Superkey / candidate key | a set of columns that is unique in every legal state / a minimal superkey |
| Prime attribute | a column that belongs to some candidate key |
| 1NF | every column holds one atomic value; no repeating groups or lists |
| 2NF | 1NF, and no non-prime column depends on a **proper subset of any candidate key** (no *partial* dependency) |
| 3NF | for every non-trivial X → A: X is a superkey, or A is prime |
| BCNF | for every non-trivial X → A: X is a superkey |

Partial versus transitive: if the left side of a bad FD is **part of a candidate key**, it is a *partial*
dependency and the first normal form it breaks is **2NF**. It is *transitive* (breaks 3NF) when the left
side is not part of any key. The same FD can look "transitive" if you only look at the surrogate primary
key; the general definitions classify it by all candidate keys.

**A surrogate primary key does not prove BCNF.** `instrument_id` is a key, but if `instruments` also had a
column decided by `exchange` alone, that FD's left side (`exchange`) would not be a superkey and the
table would not be in BCNF, surrogate key or not. Every table below is therefore checked against its
*natural* candidate keys as well.

### Business rules that define the FDs

| # | Rule | Where it comes from |
|---|---|---|
| R1 | usernames are unique; emails are unique | declared: `uq_users_username`, `uq_users_email` |
| R2 | an instrument is a **listing**: one symbol on one exchange. Symbols are assigned by each exchange, so the system only promises uniqueness *within* an exchange | declared: `uq_instruments_exchange_symbol` |
| R3 | the quote currency belongs to the listing, not to the exchange: Binance quotes ETHBTC in BTC and BTCUSDT in USDT | real-world fact about Binance spot pairs |
| R4 | a watchlist name is unique per owner, not globally | declared: `uq_watchlists_user_name`; `03_constraints.out` shows priya may also create "Crypto" |
| R5 | a tick is identified by its source's event id **within that source and instrument**; Binance aggregate-trade ids are numbered per symbol, and MANUAL ids are free text | declared: `uq_price_ticks_source_event` |
| R6 | several trades can carry the same timestamp at different prices | real-world tick data; schema test A10 accepts it |
| R7 | a user may not create the same rule twice: one rule per (user, instrument, direction, threshold) | declared: `uq_alert_rules_definition` |
| R8 | at most one alert event per (rule, tick) | declared: `uq_alert_events_rule_tick` |
| R9 | alerts are evaluated **synchronously**, inside the tick's transaction (trigger `trg_price_ticks_evaluate_alerts`) | implementation fact, not a business rule; no FD is derived from it (§9) |

Each candidate FD below is one of: **declared** (enforced by a key), **rejected** (a sound
counterexample exists), or **not adopted** (true in today's rows but no rule guarantees it — so the
design must not rely on it).

---

## 1. users (user_id, username, email, created_at)

- Candidate keys: {user_id}, {username}, {email} — each single-column, all NOT NULL.
- FDs: user_id → username, email, created_at; username → user_id, email, created_at;
  email → user_id, username, created_at.
- Prime: user_id, username, email. Non-prime: created_at.
- Rejected: created_at → anything — the three seed users were created in one transaction and share the
  same created_at.

| NF | Status | Why |
|---|---|---|
| 1NF | yes | one email per user, stored as one value |
| 2NF | yes | every candidate key has one column, so a *proper subset* of a key is empty: no partial dependency is possible |
| 3NF | yes | the only non-prime column determines nothing |
| BCNF | **yes** | every determinant (user_id, username, email) is a candidate key |

## 2. instruments (instrument_id, exchange, symbol, name, quote_currency, is_active)

- Candidate keys: {instrument_id}, {exchange, symbol}. Minimal: exchange alone repeats (five NSE rows);
  symbol alone is not promised unique (R2).
- FDs: instrument_id → all other columns; (exchange, symbol) → instrument_id, name, quote_currency, is_active.
- Prime: instrument_id, exchange, symbol. Non-prime: name, quote_currency, is_active.

| Candidate FD | Status | Reason |
|---|---|---|
| exchange → quote_currency | **rejected** | R3: one exchange (Binance) quotes different pairs in different currencies (ETHBTC in BTC, BTCUSDT in USDT) |
| symbol → name | **not adopted** | R2: symbols are unique only within an exchange, so the design does not assume one symbol means one company everywhere. The current rows do satisfy it (each symbol appears once), which proves nothing about legal states. No real cross-exchange collision is claimed here, because none was verified. |
| symbol → quote_currency | **not adopted** | same reason as symbol → name |
| exchange → asset_class | not applicable | there is no asset_class column. It is also **not** a valid FD in general: NSE lists ETFs (for example NIFTYBEES) as well as equities. If it did hold, it would be a *partial* dependency on {exchange, symbol}, i.e. a **2NF** violation |

| NF | Status | Why |
|---|---|---|
| 1NF | yes | exchange and symbol are separate atomic columns, not one "NSE:RELIANCE" string |
| 2NF | yes | under R2 and R3 no non-prime column depends on exchange alone or on symbol alone |
| 3NF | yes | name, quote_currency and is_active do not determine each other |
| BCNF | **yes** | determinants are instrument_id and (exchange, symbol), both keys |

Caveat to state if asked: if the faculty decides that a symbol *does* identify the same company on every
exchange, then symbol → name becomes a partial dependency on {exchange, symbol} (2NF violation) and the
fix would be a separate SECURITY(symbol, name) relation. That is a different business rule, not an error
in the current design.

Minor integrity note (not a normal-form issue): for Binance the quote currency is also encoded at the end
of the symbol (BTC**USDT**). The database does not check that the two agree.

## 3. watchlists (watchlist_id, user_id, name, created_at)

- Candidate keys: {watchlist_id}, {user_id, name}. Minimal: user_id alone repeats (arjun owns two lists);
  name alone is not unique (R4).
- FDs: watchlist_id → user_id, name, created_at; (user_id, name) → watchlist_id, created_at.
- Prime: watchlist_id, user_id, name. Non-prime: created_at.
- Partial-dependency test on (user_id, name): user_id ↛ created_at (one user creates lists at different
  times); name ↛ created_at (two users may each have "Crypto").

1NF yes · 2NF yes · 3NF yes · **BCNF yes** (both determinants are keys).

## 4. watchlist_items (watchlist_id, instrument_id, added_at)

- Candidate key: {watchlist_id, instrument_id} only (it is the M:N relationship CONTAINS).
- FD: (watchlist_id, instrument_id) → added_at.
- Prime: watchlist_id, instrument_id. Non-prime: added_at.
- Partial test: watchlist_id ↛ added_at (items join one list at different times); instrument_id ↛ added_at.

1NF yes (one instrument per row, never a list) · 2NF yes · 3NF yes · **BCNF yes**.

## 5. price_ticks (tick_id, instrument_id, observed_at, price, volume, source, source_event_id, ingested_at)

- Candidate keys: {tick_id}, {source, instrument_id, source_event_id}. Minimality:
  - without source: a MANUAL tick typed with id "123" and a Binance tick whose aggregate-trade id is 123,
    both for BTCUSDT, are both legal (R5);
  - without instrument_id: Binance numbers aggregate trades per symbol, so id 123 exists for BTCUSDT and
    for ETHUSDT (R5);
  - without source_event_id: one source sends many ticks for one instrument.
- FDs: tick_id → all other columns; (source, instrument_id, source_event_id) → tick_id, observed_at,
  price, volume, ingested_at.
- Prime: tick_id, source, instrument_id, source_event_id. Non-prime: observed_at, price, volume, ingested_at.

| Candidate FD | Status | Reason |
|---|---|---|
| (instrument_id, observed_at) → price | rejected | R6 |
| (source, source_event_id) → instrument_id | rejected | R5 |
| observed_at → ingested_at | rejected | live, replayed and late ticks arrive at different times for the same market time |

| NF | Status | Why |
|---|---|---|
| 1NF | yes | `source_event_id` such as `r2demo:000006` is used as one opaque identifier (no query splits it); `volume` NULL is one unknown value |
| 2NF / 3NF | yes | no subset of the composite key determines a non-prime column, and non-prime columns do not determine each other |
| BCNF | **yes** | determinants are tick_id and the three-column key |

## 6. alert_rules (rule_id, user_id, instrument_id, direction, threshold, cooldown_seconds, is_active, created_at)

- Candidate keys: {rule_id}, {user_id, instrument_id, direction, threshold} (R7).

| Drop from the alternate key | Legal counterexample (so the column is needed) |
|---|---|
| threshold | arjun, RELIANCE, ABOVE 3000 and ABOVE 3100 |
| direction | arjun, RELIANCE, ABOVE 3000 and BELOW 3000 |
| instrument_id | arjun, ABOVE 3000 on RELIANCE and on TCS |
| user_id | arjun and kavya both RELIANCE ABOVE 3000 |

- FDs: rule_id → all; (user_id, instrument_id, direction, threshold) → rule_id, cooldown_seconds, is_active, created_at.
- Partial test: (user_id, instrument_id) ↛ cooldown_seconds — arjun has two RELIANCE rules, and nothing
  forces them to share a cooldown (the seed happens to use 300 for both).

1NF yes · 2NF yes · 3NF yes · **BCNF yes**.

Design rule, not a normal-form issue: the four definition columns are treated as immutable (the API only
changes cooldown and on/off). If a threshold were edited, old alert events would point to a rule whose
meaning changed.

## 7. alert_events (event_id, rule_id, tick_id, fired_at)

- Candidate keys: {event_id}, {rule_id, tick_id} (R8).
- Declared FDs: event_id → rule_id, tick_id, fired_at; (rule_id, tick_id) → event_id, fired_at.
- Prime: event_id, rule_id, tick_id. Non-prime: fired_at.
- Meaning of fired_at: the time **this event row was recorded** (`DEFAULT now()`). It describes the
  event, not the tick (the tick's own times are observed_at and ingested_at).
- Partial test on (rule_id, tick_id): rule_id ↛ fired_at (a rule fires many times); tick_id ↛ fired_at,
  because two events of one tick may legitimately be recorded at different times. On today's
  application path they share one value; §9 explains why that is not an FD.

1NF yes · 2NF yes · 3NF yes · **BCNF yes**.

---

## 8. Why these columns are NOT duplicated

| Question | FD it would create | Classification | What would go wrong |
|---|---|---|---|
| Why doesn't watchlist_items store `user_id`? | watchlist_id → user_id | watchlist_id is part of the key (watchlist_id, instrument_id): **partial → breaks 2NF** | the owner would be copied into every item; correcting an owner means changing many rows, and copies can disagree. The owner is one join away (watchlists). |
| Why doesn't watchlist_items store `symbol`? | instrument_id → symbol (and exchange, name) | **partial → breaks 2NF** | N3/N4 below: four instruments would be stored twice even in this small data set |
| Why doesn't alert_events store `price`? | tick_id → price | tick_id is part of the key (rule_id, tick_id): **partial → breaks 2NF**. Seen only from the primary key event_id it is also transitive (event_id → tick_id → price) | the price belongs to the tick; a second copy can disagree with price_ticks |
| Why doesn't alert_events store `instrument_id`? | tick_id → instrument_id and rule_id → instrument_id | **partial → breaks 2NF** (either way) | the "same instrument" rule is checked by trigger `trg_alert_events_check_instrument` on writes to alert_events, instead of by a copied column. Parent-side instrument_id updates are not checked (`22_integrity_scope.out`); a declarative alternative (copy instrument_id plus composite FKs) would enforce it fully, at the price of exactly this 2NF violation. |
| Why are rule definitions stored apart from fired events? | rule_id → direction, threshold, cooldown_seconds, is_active | in a table keyed by (rule_id, tick_id): **partial → breaks 2NF** | update anomaly (changing a cooldown rewrites every past event), insertion anomaly (a rule could not exist before it first fires), deletion anomaly (deleting a rule's last event deletes the rule) |

**The role of the composite candidate keys.** They are the business uniqueness rules R2, R4, R5, R7 and R8
written as constraints, and they are exactly the keys the partial-dependency tests above run against. The
surrogate primary keys (user_id, instrument_id, watchlist_id, tick_id, rule_id, event_id) give short,
stable foreign-key targets, but they do not replace the natural keys: without the UNIQUE constraints,
two "NSE RELIANCE" rows or two events for the same rule and tick could be stored. The Review 1 table
section left most of them out.

---

## 9. `alert_events.fired_at`: the event row's recording time

**Decision (team, Review 2):** the column is kept unchanged and is defined as **the time the
alert_events row was recorded**: `DEFAULT now()`, the start time of the recording transaction. The
schema, the API and the tests are not changed.

The question was examined from the code and the catalog, not only from the eight stored rows (N1)
(`sql/review2/21_fired_at_analysis.sql` → `sql_output/21_fired_at_analysis.out`).

### 9.1 What the implementation does (catalog and code)

| Fact | Evidence |
|---|---|
| `alert_events.fired_at` and `price_ticks.ingested_at` both default to `now()`, i.e. the **start time of the current transaction** | 21 A1 |
| The only production statement that writes alert_events is `INSERT INTO alert_events (rule_id, tick_id)`, inside the AFTER INSERT trigger on price_ticks. It never supplies fired_at, so the default applies. | 21 A2 (lines of `pg_get_functiondef`); `grep` of `app/` finds no write to alert_events |
| The trigger runs once, inside the transaction that inserts the tick. A tick is inserted exactly once (`uq_price_ticks_source_event`), and late or old ticks are never re-evaluated. | `sql/03_functions_triggers.sql`; 21 B1 |
| No trigger or CHECK looks at fired_at (the check trigger fires only on `UPDATE OF rule_id, tick_id`) | 21 A3 |
| The only login role on the classroom server is the superuser `aditi` (also the role the application uses), so direct INSERT and UPDATE on alert_events are *permitted* | 21 A4; catalog query on `stock_watchlist` |

What the rows show (rolled back):
- **B1, one tick firing two rules:** both events carry the same fired_at, and it equals the tick's
  ingested_at.
- **B2, two different ticks ingested in one transaction:** their events share one fired_at. The value
  is the time of the *recording transaction*, not of a tick. The project's own alert test 10d asserts
  the same thing ("all 3 events share one fired_at").
- **B3:** on everything produced through the application path, 0 ticks have more than one fired_at.
- **C1–C3:** an event recorded by hand with its own fired_at, and an `UPDATE` of fired_at, are both
  accepted. Tick 6 then has two events with different fired_at values.

### 9.2 Consequence for the functional dependencies

- The FDs of alert_events are the declared ones: event_id → rule_id, tick_id, fired_at and
  (rule_id, tick_id) → event_id, fired_at. Both determinants are candidate keys, so the table is in
  **BCNF**.
- **tick_id → fired_at is not an FD of the design.** fired_at says when an event row was recorded. Two
  events of one tick may legitimately be recorded at different times, for example by a later
  re-evaluation or a manual correction (C1–C3 are such states, and the schema accepts them).
- The equality seen on the application path (B1–B3; N1: 8 of 8 equal to ingested_at) holds because the
  current code records every event inside the tick's own transaction. It describes the **write path**,
  not a rule about the data, so it is not used to classify the table. No 2NF violation is claimed.
- If the team ever adopted "alerts are recorded only, and synchronously, in the tick's transaction" as a
  business rule, tick_id → fired_at would become an FD and a partial dependency on (rule_id, tick_id).
  That is not the adopted definition.

### 9.3 Viva wording

- Say: "fired_at is when the alert row was recorded. Today that is the tick's transaction, so the values
  coincide with ingested_at, but the design does not depend on that."
- Do not say: "fired_at is the tick's time", or "alert_events violates 2NF because of fired_at".

## 10. Educational decomposition (illustration, not a proof of all seven tables)

This shows how mixing users, watchlists, instruments and alert rules in one place causes redundancy and
anomalies, and how FDs split it. It derives four of the seven relations. Watchlists as separate rows,
surrogate keys, price_ticks and alert_events come from the ER model and other requirements (§10.4).

### 10.1 Unnormalized: one "sheet" row per user (actual output N2)

```text
 username |       email       |                                     watchlist_entries                                      |                                    alert_rules
----------+-------------------+--------------------------------------------------------------------------------------------+------------------------------------------------------------------------------------
 arjun    | arjun@example.com | Crypto: BTCUSDT; Crypto: ETHUSDT; Long Term: HDFCBANK; Long Term: RELIANCE; Long Term: TCS | RELIANCE ABOVE 3000 cd 300; RELIANCE BELOW 2800 cd 300; BTCUSDT ABOVE 100000 cd 60
 kavya    | kavya@example.com | Main: BTCUSDT; Main: INFY; Main: RELIANCE                                                  | ETHUSDT BELOW 3000 cd 120
 priya    | priya@example.com | Auto: M&M; Tech: INFY; Tech: TCS                                                           | TCS BELOW 3500 cd 0; INFY ABOVE 1600 cd 600
```

Not 1NF: two repeating groups (watchlist entries and rules) are packed into single cells. Questions like
"who watches TCS?" need string searching, and nothing stops an invalid symbol inside the text.

### 10.2 First normal form: move each repeating group into its own relation, carrying the key

- USER(<u>username</u>, email) — email is also a key (R1)
- WATCH_ENTRY(<u>username, watchlist_name, exchange, symbol</u>, instrument_name, quote_currency)
- RULE(<u>username, exchange, symbol, direction, threshold</u>, instrument_name, cooldown_seconds)

Moving each repeating group into a separate relation (rather than flattening both into one table)
avoids pairing every watchlist entry with every rule, which would create spurious combinations.

WATCH_ENTRY with the real data (actual output N3):

```text
 username | watchlist_name | exchange |  symbol  |        instrument_name        | quote_currency
----------+----------------+----------+----------+-------------------------------+----------------
 arjun    | Crypto         | BINANCE  | BTCUSDT  | Bitcoin / Tether              | USDT
 kavya    | Main           | BINANCE  | BTCUSDT  | Bitcoin / Tether              | USDT
 arjun    | Crypto         | BINANCE  | ETHUSDT  | Ether / Tether                | USDT
 arjun    | Long Term      | NSE      | HDFCBANK | HDFC Bank Ltd                 | INR
 kavya    | Main           | NSE      | INFY     | Infosys Ltd                   | INR
 priya    | Tech           | NSE      | INFY     | Infosys Ltd                   | INR
 priya    | Auto           | NSE      | M&M      | Mahindra & Mahindra Ltd       | INR
 arjun    | Long Term      | NSE      | RELIANCE | Reliance Industries Ltd       | INR
 kavya    | Main           | NSE      | RELIANCE | Reliance Industries Ltd       | INR
 arjun    | Long Term      | NSE      | TCS      | Tata Consultancy Services Ltd | INR
 priya    | Tech           | NSE      | TCS      | Tata Consultancy Services Ltd | INR
```

Anomalies still present:
- **Redundancy / update:** "Reliance Industries Ltd" is stored once per watcher (N4: BTCUSDT, INFY,
  RELIANCE and TCS are each stored twice). Renaming a company means updating several rows.
- **Insertion:** a new listing (for example NSE SBIN) cannot be recorded until somebody watches it.
- **Deletion:** removing HDFCBANK from arjun's "Long Term" deletes the only row that says what HDFCBANK is.

### 10.3 Second normal form: remove the partial dependencies

(exchange, symbol) → instrument_name, quote_currency, and (exchange, symbol) is only **part** of
WATCH_ENTRY's key and of RULE's key. Split on it:

- INSTRUMENT(<u>exchange, symbol</u>, instrument_name, quote_currency)
- WATCH_ENTRY(<u>username, watchlist_name, exchange, symbol</u>)
- RULE(<u>username, exchange, symbol, direction, threshold</u>, cooldown_seconds)
- USER(<u>username</u>, email)

Each split is on an FD X → Y where X becomes the key of the new relation, so by Heath's theorem the join
of the pieces gives back exactly the original rows (**lossless**). Every FD of the example lies inside
one relation (**dependency-preserving**).

### 10.4 Third normal form and BCNF

USER: username → email and email → username, both keys. INSTRUMENT: only its key determines anything
(R2, R3). WATCH_ENTRY is all-key. RULE: its key determines cooldown_seconds. **All four are in BCNF.**

From here to the implemented schema: these are design decisions, not further FD steps.
1. WATCHLIST(username, watchlist_name, created_at) becomes its own relation (an entity in the ER model),
   so a watchlist can exist while empty. WATCH_ENTRY then becomes watchlist_items.
2. Surrogate keys (user_id, instrument_id, watchlist_id, rule_id) are added as compact foreign-key
   targets. The natural keys stay as UNIQUE constraints.
3. price_ticks and alert_events come from separate requirements (market history and alert history).
   They are not derived from this sheet.

---

## 11. Review of the earlier normalization notes (corrections, not silent rewrites)

These corrections were applied to the working documents on 2026-10-13. The replaced text is kept in
`OLDER_DOCS_CORRECTIONS.md`. The Review 1 report itself had no normalization section.

| Where | Earlier claim | Problem | Correct statement |
|---|---|---|---|
| `docs/NORMALIZATION_NOTES.md` §2, rejected-FD table | "symbol → name: NSE RELIANCE and BSE RELIANCE share a symbol" | **Invalid counterexample.** Same company, same name: it is consistent with the FD, not against it. | symbol → name is *not adopted* (R2). No verified collision is claimed. |
| `docs/NORMALIZATION_NOTES.md` §2 | "exchange → asset_class would be TRUE (BINANCE is always crypto)" | **Overstated.** False in general: NSE lists ETFs as well as equities. | Not an FD in general. If it held, it would be a partial dependency (2NF). |
| `docs/SCHEMA_DESIGN.md`, instruments | "exchange → asset_class would violate 3NF" | **Misclassified** under the general definitions: exchange is part of the candidate key (exchange, symbol), so it is a partial dependency. | "would violate **2NF** (and therefore 3NF and BCNF)" |
| `docs/NORMALIZATION_NOTES.md` §7 | storing price / instrument_id "would break 3NF … transitive dependency" | **Incomplete under the notes' own §0.1 definitions.** tick_id is part of the candidate key (rule_id, tick_id), so it is a partial dependency. | "breaks **2NF**; seen from the primary key alone it is also transitive" |
| `docs/NORMALIZATION_NOTES.md` §0.2 | rolled-back inserts "prove the schema accepts" counterexamples | **Overstatement if read as proof.** The schema accepting a row shows the database does not *enforce* an FD; it does not show the FD is false in the business. | FDs are accepted or rejected by business rules R1–R9. Test inserts are supporting evidence only. |
| `docs/NORMALIZATION_NOTES.md` §7 | "tick_id → fired_at is false, because one tick can fire several rules" | **Wrong reason.** On the application path all events of one tick share one fired_at, so "several rules" does not refute anything. | tick_id → fired_at is not an FD because fired_at is the event row's recording time (§9). |

---

## 12. Summary

| Table | Candidate keys | Non-prime columns | Highest NF | Note |
|---|---|---|---|---|
| users | {user_id}, {username}, {email} | created_at | BCNF | |
| instruments | {instrument_id}, {exchange, symbol} | name, quote_currency, is_active | BCNF | relies on R2 and R3 |
| watchlists | {watchlist_id}, {user_id, name} | created_at | BCNF | |
| watchlist_items | {watchlist_id, instrument_id} | added_at | BCNF | the M:N relationship CONTAINS |
| price_ticks | {tick_id}, {source, instrument_id, source_event_id} | observed_at, price, volume, ingested_at | BCNF | |
| alert_rules | {rule_id}, {user_id, instrument_id, direction, threshold} | cooldown_seconds, is_active, created_at | BCNF | |
| alert_events | {event_id}, {rule_id, tick_id} | fired_at | BCNF | fired_at = the event row's recording time (§9) |
