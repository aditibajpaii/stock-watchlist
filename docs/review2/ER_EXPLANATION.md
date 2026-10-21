# Corrected ER diagram — what it shows and why

Files:
- `docs/review2/ER_CORRECTED.svg` and `.png`: **1. Conceptual ER Diagram — Chen Notation**
- `docs/review2/RELATIONAL_SCHEMA.svg` and `.png`: **2. Relational Schema — Tables, PKs and FKs** (a
  different kind of diagram: it shows the result of mapping, see `ER_TO_RELATIONAL_MAPPING.md`)
- Source: `scripts/review2_diagrams.py`. Every coordinate is written there; run
  `python scripts/review2_diagrams.py` to redraw both files.
- **Team presentation version:** `docs/review2/ER_CHEN_PRESENTATION.svg` and `.png` (same content, without
  the legend panels; checked element by element against this model: `sql_output/94_team_er_audit.out`),
  plus its companion `docs/review2/ER_READING_GUIDE.png` (keys, participation and integrity notes; every
  statement checked in `ER_FINAL_AUDIT.md` §6).
- Original Review 1 diagram, kept unchanged for comparison:
  `docs/review2/review1_original/REVIEW1_ER_AS_SUBMITTED.png` (page 5 of the submitted report, copied
  read-only; the PDF's checksum was identical before and after).

## How it was checked

| Check | Result | Evidence |
|---|---|---|
| No two shapes or labels overlap; no line passes through a shape or label it does not connect; no two lines cross | OK: 61 shapes/labels, 45 line segments | output of `python scripts/review2_diagrams.py` |
| Every text line fits inside its box | OK: 31 lines | same |
| Attributes, relationships, cardinality, participation, keys, and completeness (7 tables, 8 FKs, 14 keys) match the PostgreSQL catalog | **31/31 OK** (see `ER_FINAL_AUDIT.md`) | `docs/review2/sql_output/92_er_vs_catalog.out` (`--verify-db`) |
| Visual inspection of the rendered PNG | Done. The first render had text overflowing the integrity note box; this was fixed and re-rendered. | the PNG files |

## Notation (as in the faculty's Review 2 template sample)

| Symbol | Meaning |
|---|---|
| rectangle | entity type (singular names: USER, WATCHLIST, …) |
| oval | attribute; **underlined** = key attribute |
| oval with ovals attached | composite attribute (`listing` = exchange + symbol) |
| diamond | relationship type |
| plain line | connection. **There are no arrowheads:** in Chen notation an arrow carries no meaning on an attribute line. |
| double line | **total participation**: every entity on that side must take part |
| single line | partial participation |
| 1, N, M beside a line | cardinality ratio: the maximum number of entities on that side that one entity on the other side relates to |

## Entities

| Entity | Attributes (key underlined in the drawing) | Why it is an entity |
|---|---|---|
| USER | user_id, username, email, created_at | independent thing with its own identity; three keys (R1) |
| WATCHLIST | watchlist_id, name, created_at | a named list a user creates and deletes; it has its own identity (watchlist_id) that its items refer to, and it may exist while empty |
| INSTRUMENT | instrument_id, listing(exchange, symbol), name, quote_currency, is_active | a tradable listing; composite key `listing` |
| PRICE_TICK | tick_id, observed_at, price, volume, source, source_event_id, ingested_at | one market observation; referenced by alert events |
| ALERT_RULE | rule_id, direction, threshold, cooldown_seconds, is_active, created_at | a user's standing instruction; exists before and independently of any alert |
| ALERT_EVENT | event_id, fired_at | **associative entity**, see below |

No foreign-key columns appear as attributes (for example WATCHLIST has no `user_id` oval). In an ER
model the link to USER is the relationship OWNS. The column `user_id` only appears after mapping
(diagram 2).

## Relationships — cardinality and participation, derived from the SQL

Cardinality comes from whether the foreign-key column is unique on its own (none is, so every binary
relationship is 1:N). Participation of the "many" side comes from NOT NULL on the foreign key (all are
NOT NULL, so each is total). Nothing forces the "one" side to have children, so that side is partial.
This is also why **1:N does not imply total participation**: USER is on the 1 side of OWNS but takes
part partially, because a user may have zero watchlists.

| Relationship | Ratio | Participation | Implemented by |
|---|---|---|---|
| USER OWNS WATCHLIST | 1 : N | WATCHLIST total, USER partial | `fk_watchlists_user` (user_id NOT NULL) |
| USER CREATES ALERT_RULE | 1 : N | ALERT_RULE total, USER partial | `fk_alert_rules_user` |
| WATCHLIST CONTAINS INSTRUMENT (attribute added_at) | **M : N** | both partial (an empty watchlist and an unwatched instrument are both legal) | table `watchlist_items`, PK (watchlist_id, instrument_id) |
| ALERT_RULE MONITORS INSTRUMENT | N : 1 | ALERT_RULE total, INSTRUMENT partial | `fk_alert_rules_instrument` |
| INSTRUMENT HAS_TICK PRICE_TICK | 1 : N | PRICE_TICK total, INSTRUMENT partial (HDFCBANK has no ticks) | `fk_price_ticks_instrument` |
| ALERT_RULE GENERATES ALERT_EVENT | 1 : N | ALERT_EVENT total, ALERT_RULE partial (rule 5 never fired) | `fk_alert_events_rule` |
| ALERT_EVENT TRIGGERED_BY PRICE_TICK | N : 1 | ALERT_EVENT total, PRICE_TICK partial (22 of 30 ticks fired nothing) | `fk_alert_events_tick` |

## Why CONTAINS is a relationship, not a weak entity

The Review 1 diagram drew `Watchlist_item` as a weak entity (a double rectangle). That is not correct
here:
- A weak entity needs its own **partial key** (shown with a dashed underline), identified together with
  its owner's key. Watchlist_item has none: its whole identity is (watchlist_id, instrument_id), the
  keys of the two things it connects.
- Something identified only by the keys of the entities it links, and carrying one descriptive
  attribute (`added_at`), is exactly an **M:N relationship type with an attribute**.
- The Review 1 drawing was also incomplete as a weak entity. Its identifying relationships were single
  diamonds rather than double diamonds, there was no total participation, and the owner keys were
  copied in as attributes.

A composite primary key in the table (`pk_watchlist_items`) is a property of the *mapping* of an M:N
relationship. It does not make the conceptual object a weak entity.

## Why ALERT_EVENT is drawn as an entity (associative entity) and is defensible

Conceptually, an alert is the fact "rule R fired on tick T", which is an M:N relationship between
ALERT_RULE and PRICE_TICK. It is drawn as an entity because:
1. **It has its own identity, used on its own.** `event_id` is the payload of the
   `pg_notify('alert_events', …)` signal sent by the trigger, and it is returned by the API's alert list
   (`GET /users/{user_id}/alerts`, `schemas.AlertEvent.event_id`). Watchlist membership is never
   referenced on its own like that.
2. **It is a record of something that happened,** with its own attribute (`fired_at`), and it is queried
   as "alert history".
3. **It maps exactly onto the implemented table.** As an entity it becomes alert_events with PK
   `event_id`, two total 1:N relationships (two NOT NULL foreign keys), and the rule "at most one event
   per (rule, tick)" as `UNIQUE (rule_id, tick_id)`. Modelled as an M:N relationship instead, it would
   map to a table whose primary key is (rule_id, tick_id), with no event_id. That is not the table that
   exists.

Either representation is accepted ER practice. This one is chosen because it matches how the
application uses alerts, and it is labelled "associative entity" in the diagram's reading notes.

## Why WATCHLIST and PRICE_TICK are strong entities, although part of their natural key involves another entity

A watchlist's name is unique only per user, so (owner, name) identifies it. A tick's event id is
unique only per (source, instrument). Both could have been drawn as weak entities with partial keys
(`name`; `source` + `source_event_id`). They are drawn as strong entities because each has its **own
key attribute** (`watchlist_id`, `tick_id`), which other tables reference. An entity type that has a key
is strong by definition.

The per-owner uniqueness is not lost. It is shown in the diagram's **Keys** legend and implemented as
`uq_watchlists_user_name` and `uq_price_ticks_source_event`. A key that includes a relationship cannot be
drawn as an underlined attribute in Chen notation, which is why those keys go in the legend.

## Integrity rule shown as a note, not as a relationship

An ALERT_EVENT's rule and tick must be for the same instrument. This is a constraint across a cycle of
relationships (ALERT_RULE–MONITORS–INSTRUMENT and PRICE_TICK–HAS_TICK–INSTRUMENT), not a new relationship.
The diagram shows it as a dashed note.

**What the database actually enforces** (verified in `sql_output/22_integrity_scope.out`):
- **Writes to alert_events are checked.** Trigger `trg_alert_events_check_instrument` (BEFORE INSERT OR
  UPDATE OF rule_id, tick_id) rejects a mismatched rule and tick: RELIANCE rule + TCS tick → `ERROR 23514`
  (`14_triggers.out`, `22_integrity_scope.out` step 1).
- **Later changes on the parent rows are not checked.** `UPDATE alert_rules SET instrument_id = …` and
  `UPDATE price_ticks SET instrument_id = …` are accepted, and leave 2 and 1 events mismatched
  respectively (steps 2–3, rolled back).
- **Why it holds in practice:** no application path changes instrument_id. The only `UPDATE alert_rules`
  in `app/main.py` sets `is_active` and `cooldown_seconds`, and `AlertRulePatch` rejects every other field.
  Nothing updates price_ticks.

So the rule is guaranteed for every application write, not for every possible SQL statement. Closing the
gap would need extra triggers on alert_rules and price_ticks: a production schema change, not
applied (see the approval decisions).

## What changed compared with the Review 1 diagram

See `DESIGN_CHANGE_LOG.md`, entries D1–D8. All of them are **documentation corrections**; the database
was not changed.
