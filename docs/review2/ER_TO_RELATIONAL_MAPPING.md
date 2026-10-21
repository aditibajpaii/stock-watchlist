# From the conceptual ER model to the seven tables

Diagram 1 (`ER_CORRECTED.png`) is mapped to diagram 2 (`RELATIONAL_SCHEMA.png`) with the standard
ER-to-relational mapping steps (Elmasri & Navathe). Every target constraint named below exists in the
database (`TABLE_CONSTRAINT_INVENTORY.md`, read from the catalog), and `python scripts/review2_diagrams.py
--verify-db stock_watchlist_review2_sandbox` checks the correspondence automatically (31/31 OK,
`sql_output/92_er_vs_catalog.out`).

## Step by step

| Step | Rule | Applied here | Result |
|---|---|---|---|
| 1 | Each strong entity type → a table with its simple attributes; a composite attribute contributes its components; pick a primary key, keep other keys as UNIQUE | USER, WATCHLIST, INSTRUMENT, PRICE_TICK, ALERT_RULE, ALERT_EVENT | users, watchlists, instruments, price_ticks, alert_rules, alert_events. `listing` → columns exchange, symbol + `uq_instruments_exchange_symbol`. username, email → `uq_users_username`, `uq_users_email` |
| 2 | Weak entity → table with owner key + partial key | none (see ER_EXPLANATION.md) | — |
| 3 | 1:1 relationship → foreign key on one side | none | — |
| 4 | **1:N relationship → foreign key in the table on the N side**; total participation of the N side → the FK column is NOT NULL | OWNS, CREATES, MONITORS, HAS_TICK, GENERATES, TRIGGERED_BY | six foreign keys, all NOT NULL (table below) |
| 5 | **M:N relationship → a new table** whose primary key is the two foreign keys; the relationship's attributes become its columns | CONTAINS (added_at) | `watchlist_items(watchlist_id, instrument_id, added_at)`, PK (watchlist_id, instrument_id), two FKs |
| 6 | Multivalued attribute → its own table | none (every attribute is single-valued) | — |
| 7 | n-ary relationship (n > 2) → its own table | none | — |
| keys from the legend | a key that includes a relationship → a UNIQUE constraint that contains the FK column | WATCHLIST name per USER; PRICE_TICK event id per source and INSTRUMENT; ALERT_RULE definition; one ALERT_EVENT per (rule, tick) | `uq_watchlists_user_name`, `uq_price_ticks_source_event`, `uq_alert_rules_definition`, `uq_alert_events_rule_tick` |
| integrity note | a rule across a cycle → trigger | same instrument for rule and tick of an event | `trg_alert_events_check_instrument`: checks writes to alert_events only; parent-side `instrument_id` updates are not checked (`22_integrity_scope.out`) |

## Relationship → foreign key

| Relationship (diagram 1) | Foreign key (diagram 2) | Column | NOT NULL (= total) | ON DELETE | Why that action |
|---|---|---|---|---|---|
| USER OWNS WATCHLIST | `fk_watchlists_user` | watchlists.user_id → users | yes | CASCADE | a user's lists belong to the user |
| USER CREATES ALERT_RULE | `fk_alert_rules_user` | alert_rules.user_id → users | yes | CASCADE | a user's rules belong to the user |
| WATCHLIST CONTAINS INSTRUMENT | `fk_watchlist_items_watchlist` | watchlist_items.watchlist_id → watchlists | yes | CASCADE | items belong to their list |
| | `fk_watchlist_items_instrument` | watchlist_items.instrument_id → instruments | yes | RESTRICT | a listed instrument may not vanish from users' lists |
| ALERT_RULE MONITORS INSTRUMENT | `fk_alert_rules_instrument` | alert_rules.instrument_id → instruments | yes | RESTRICT | shared reference data |
| INSTRUMENT HAS_TICK PRICE_TICK | `fk_price_ticks_instrument` | price_ticks.instrument_id → instruments | yes | RESTRICT | market history must not be deleted with its instrument |
| ALERT_RULE GENERATES ALERT_EVENT | `fk_alert_events_rule` | alert_events.rule_id → alert_rules | yes | CASCADE | alert history is owned by the rule (and so by the user) |
| ALERT_EVENT TRIGGERED_BY PRICE_TICK | `fk_alert_events_tick` | alert_events.tick_id → price_ticks | yes | RESTRICT | a tick that fired an alert is evidence and must stay |

ON DELETE behaviour was read from `pg_constraint.confdeltype`. It is demonstrated in
`sql_output/02_dml.out` (deleting a user cascades to its watchlist, items and rule) and
`sql_output/03_constraints.out` (deleting RELIANCE is refused with 23001).

## Entity → table (attribute by attribute)

| Entity / relationship | Attributes in diagram 1 | Table columns added by mapping | Table |
|---|---|---|---|
| USER | user_id, username, email, created_at | — | users (4) |
| WATCHLIST | watchlist_id, name, created_at | user_id (OWNS) | watchlists (4) |
| INSTRUMENT | instrument_id, listing(exchange, symbol), name, quote_currency, is_active | — | instruments (6) |
| PRICE_TICK | tick_id, observed_at, price, volume, source, source_event_id, ingested_at | instrument_id (HAS_TICK) | price_ticks (8) |
| ALERT_RULE | rule_id, direction, threshold, cooldown_seconds, is_active, created_at | user_id (CREATES), instrument_id (MONITORS) | alert_rules (8) |
| ALERT_EVENT | event_id, fired_at | rule_id (GENERATES), tick_id (TRIGGERED_BY) | alert_events (4) |
| CONTAINS | added_at | watchlist_id, instrument_id (the two participants) | watchlist_items (3) |

Total: 37 columns in 7 tables. That is 6 entity tables plus 1 relationship table.

## A worked example: one relationship all the way to an output

1. **Conceptual (diagram 1):** WATCHLIST —M— CONTAINS —N— INSTRUMENT, with attribute added_at. Both sides
   partial.
2. **Mapping (step 5):** new table watchlist_items(watchlist_id, instrument_id, added_at). The primary key
   is the pair, and each column is a foreign key.
3. **DDL** (`sql/00_schema.sql`): `CONSTRAINT pk_watchlist_items PRIMARY KEY (watchlist_id, instrument_id)`,
   `fk_watchlist_items_watchlist … ON DELETE CASCADE`, `fk_watchlist_items_instrument … ON DELETE RESTRICT`.
4. **Constraint in action** (`sql_output/03_constraints.out`): adding RELIANCE twice to arjun's "Long Term"
   → `ERROR: duplicate key value violates unique constraint "pk_watchlist_items"` (23505).
5. **Query** (J07 or CQ03 in `QUERY_EVIDENCE.md`): the relationship is followed by joining watchlists →
   watchlist_items → instruments. CQ03's actual output lists arjun "Long Term" with RELIANCE and TCS (5
   alerts), and so on.
