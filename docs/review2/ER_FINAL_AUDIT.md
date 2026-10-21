# Final ER audit — does the six-entity diagram map exactly onto the seven tables?

Automated evidence: `python scripts/review2_diagrams.py --verify-db stock_watchlist_review2_sandbox`
→ `docs/review2/sql_output/92_er_vs_catalog.out`. **Result: 31 / 31 checks OK** against the PostgreSQL
catalog (the database was built from `sql/00_schema.sql`).

## 1. Six entities + one many-to-many relationship → seven tables

| Diagram 1 | Kind | Table | Columns added by mapping |
|---|---|---|---|
| USER | entity | users | — |
| INSTRUMENT | entity (composite key `listing`) | instruments | — (`listing` → exchange, symbol) |
| WATCHLIST | entity | watchlists | user_id (from OWNS) |
| PRICE_TICK | entity | price_ticks | instrument_id (from HAS_TICK) |
| ALERT_RULE | entity | alert_rules | user_id (CREATES), instrument_id (MONITORS) |
| ALERT_EVENT | associative entity | alert_events | rule_id (GENERATES), tick_id (TRIGGERED_BY) |
| CONTAINS (M:N, attribute added_at) | relationship | watchlist_items | watchlist_id, instrument_id (its two participants) |

Checked: the catalog has exactly these 7 tables. Each entity's attributes equal its table's columns
minus the foreign-key columns (7 checks).

## 2. The eight foreign keys

8 = 6 one-to-many relationships × 1 foreign key + 1 many-to-many relationship × 2 foreign keys (checked).

| Relationship | Ratio | Participation (diagram) | Foreign key | FK unique on its own? | FK NOT NULL? |
|---|---|---|---|---|---|
| USER OWNS WATCHLIST | 1:N | WATCHLIST total, USER partial | fk_watchlists_user | no → N side | yes → total |
| USER CREATES ALERT_RULE | 1:N | ALERT_RULE total, USER partial | fk_alert_rules_user | no | yes |
| ALERT_RULE MONITORS INSTRUMENT | N:1 | ALERT_RULE total, INSTRUMENT partial | fk_alert_rules_instrument | no | yes |
| INSTRUMENT HAS_TICK PRICE_TICK | 1:N | PRICE_TICK total, INSTRUMENT partial | fk_price_ticks_instrument | no | yes |
| ALERT_RULE GENERATES ALERT_EVENT | 1:N | ALERT_EVENT total, ALERT_RULE partial | fk_alert_events_rule | no (part of UNIQUE(rule_id, tick_id)) | yes |
| ALERT_EVENT TRIGGERED_BY PRICE_TICK | N:1 | ALERT_EVENT total, PRICE_TICK partial | fk_alert_events_tick | no | yes |
| WATCHLIST CONTAINS INSTRUMENT | M:N | both partial | fk_watchlist_items_watchlist + fk_watchlist_items_instrument | the two together form the PK | yes (inside the relationship table) |

**Why every "one" side, and both sides of CONTAINS, is partial.** Total participation on a parent side
needs something that *rejects* a parent row without children. A CHECK constraint cannot look at another
table, and a foreign key only constrains the child. So only a trigger that raises an error could do it.

The only trigger on a parent table is `trg_price_ticks_evaluate_alerts`. Its function contains no RAISE:
it *creates* alert events when a crossing happens and never rejects a tick (checked).

The data agrees:
- 2 instruments have no ticks and no rules;
- rule 5 has no events;
- 22 of 30 ticks fired nothing.

Users without watchlists or rules, and empty watchlists, occur in the committed DML and transaction demos.

## 3. Candidate keys — all 14 are represented

| Key in the database | How diagram 1 shows it |
|---|---|
| users (user_id) PK, (username), (email) | three underlined attributes |
| instruments (instrument_id) PK | underlined |
| instruments (exchange, symbol) | underlined composite attribute `listing` |
| watchlists (watchlist_id) PK | underlined |
| watchlists (user_id, name) | Keys legend (involves the OWNS relationship) |
| watchlist_items (watchlist_id, instrument_id) PK | implied by the M:N relationship CONTAINS |
| price_ticks (tick_id) PK | underlined |
| price_ticks (source, instrument_id, source_event_id) | Keys legend (involves HAS_TICK) |
| alert_rules (rule_id) PK | underlined |
| alert_rules (user_id, instrument_id, direction, threshold) | Keys legend (involves CREATES and MONITORS) |
| alert_events (event_id) PK | underlined |
| alert_events (rule_id, tick_id) | Keys legend (involves GENERATES and TRIGGERED_BY) |

Checked: the 14 PRIMARY KEY / UNIQUE constraints in the catalog are exactly the 14 the diagram expresses
(8 underlined + 1 composite attribute + 4 in the legend + 1 from the M:N relationship), with none missing
and none extra.

## 4. Valid alternative interpretations (no single notation is mandatory)

The faculty template uses Chen notation (Elmasri & Navathe style), so diagram 1 does too. The choices
below are **also correct** and may be what a particular examiner expects. Each one maps to the same, or
an equivalent, set of tables and constraints.

| Alternative | When it is preferred | How it maps | Why diagram 1 does not use it |
|---|---|---|---|
| **Crow's Foot (IE) notation** instead of Chen | many textbooks and tools; it shows participation and cardinality as (0/1, 1/many) ends | identical tables | the course sample is Chen. A Crow's Foot ER diagram is equally valid **if it stays conceptual** (no FK columns, no types). Review 1's mistakes were not the notation family. |
| **(min, max) structural constraints** instead of 1/N/M plus single/double lines, e.g. WATCHLIST (1,1) — OWNS — (0,N) USER | when an examiner wants both constraints in one label | identical | Note that (min, max) is written next to the entity it describes. A 1:N label is read the other way, so the two styles must not be mixed in one diagram. |
| **WATCHLIST as a weak entity** of USER, with partial key `name` | if a watchlist is treated as identified by (owner, name) | PK (user_id, name), or a surrogate PK plus UNIQUE (user_id, name), which is what exists | it has its own key `watchlist_id`, which watchlist_items references, so it is strong by definition. The per-owner rule is in the Keys legend. |
| **PRICE_TICK as a weak entity** of INSTRUMENT, partial key (source, source_event_id) | if a tick is only meaningful within its instrument | PK (instrument_id, source, source_event_id), or a surrogate PK plus that UNIQUE, which is what exists | it has its own key `tick_id`, which alert_events references |
| **ALERT_EVENT as an M:N relationship** "FIRED_ON" between ALERT_RULE and PRICE_TICK, with attribute `fired_at` | a minimal conceptual model | a table with PK (rule_id, tick_id) and **no event_id** | the implemented table has its own `event_id`, used by `pg_notify` and returned by the API, so the associative-entity form matches the database exactly |
| **WATCHLIST_ITEM as an associative entity** in Crow's Foot or "logical" ER diagrams | tools that always draw a box for a junction table | identical table | in a conceptual Chen model a link with no identity of its own is a relationship. A box is acceptable only if labelled associative, never as a *weak* entity without a partial key (the Review 1 error). |
| **a derived attribute** `latest_price` (dashed oval) on INSTRUMENT | to show a value the application computes | not stored, so no column | optional; it was left out so that every attribute in diagram 1 corresponds to a column |

**Not valid here:** modelling ALERT_RULE as a *relationship* between USER and INSTRUMENT. A user can
hold two rules on the same instrument (arjun: RELIANCE ABOVE 3000 and BELOW 2800). A relationship
instance is identified by the entities it connects, so it cannot hold both. And ALERT_RULE itself takes
part in GENERATES, which a plain relationship cannot do without aggregation. It must be an entity.

## 5. A second ER image exists outside the repository — do not submit it as it is

`~/Downloads/Real-Time Stock Market ER Diagram.png` (1536 × 1024, created 2026-10-13 04:28, SHA-256
`2e04d545769b229c…`) is a recoloured variant of diagram 1. It was **not** produced by
`scripts/review2_diagrams.py`, and it does **not** match the database. Each difference below was checked
on a full-resolution crop of the image:

| # | What that image shows | What the database says | Effect |
|---|---|---|---|
| 1 | double line WATCHLIST — CONTAINS | a watchlist may have no items | wrong participation (total instead of partial) |
| 2 | double line CONTAINS — INSTRUMENT | an instrument may be on no watchlist | wrong participation |
| 3 | double line INSTRUMENT — HAS_TICK | HDFCBANK and M&M have no ticks | wrong participation |
| 4 | double line ALERT_RULE — GENERATES | rule 5 never fired | wrong participation |
| 5 | `is_active` of ALERT_RULE underlined | not a key | wrong key notation |
| 6 | `username`, `email` not underlined | both are keys (`uq_users_username`, `uq_users_email`) | keys hidden in the drawing (they appear only in its legend) |
| 7 | `listing` drawn as a **double oval**, and its legend says "composite attribute (double oval)" | in Chen notation a double oval means a **multivalued** attribute; a composite attribute is an oval with component ovals attached | wrong notation |
| 8 | note names trigger `alert_events_check_instrument` | actual name `trg_alert_events_check_instrument` | wrong name |

Four of these are participation errors, the same class of mistake the faculty criticised in Review 1.
Use `docs/review2/ER_CORRECTED.png`, which passes all 31 checks. If a recoloured version is wanted,
derive it from `scripts/review2_diagrams.py` so the same checks run again.

## 6. Team presentation diagram and reading guide (incorporated, corrected 2026-10-13)

| File in the repo | Origin | Role |
|---|---|---|
| `docs/review2/ER_CORRECTED.png` / `.svg` | generated by `scripts/review2_diagrams.py` | **the verified reference** (team decision): `--verify-db` 31/31 against the catalog |
| `docs/review2/ER_CHEN_PRESENTATION.svg` / `.png` | copy of `~/Downloads/ER_Corrected_Chen.svg` (`e28aba84…`), plus the two cosmetic edits of §6.2; PNG re-rendered from the edited SVG | the team's Chen diagram for the slide; same content as the reference (§6.1) |
| `docs/review2/ER_READING_GUIDE.svg` / `.png` | source recreated from `~/Downloads/ER_Explanation_Notes.png` (`7af7c00b…`), with the two wording corrections of §6.3 | companion page: keys, participation, integrity scope, notation; kept off the main slide by design |

The originals in Downloads were left untouched (SHA-256 unchanged).

### 6.1 Diagram content — checked from its SVG source

`python scripts/review2_diagrams.py --audit-svg docs/review2/ER_CHEN_PRESENTATION.svg`
(`sql_output/94_team_er_audit.out`) rebuilds the diagram from its geometry: which line touches which
shape, doubled lines, the nearest 1/N/M label, and underlined keys. It then compares the result with the
model that `--verify-db` checks against the catalog. **18 / 18 OK**, before and after the cosmetic edits:
- 6 entity types and 7 relationship types;
- 30 attributes, each with the right owner and key underline;
- all 14 relationship sides with the right cardinality and single or double line.

The auditor itself was tested by planting four errors in a copy of the SVG: one double line removed,
`is_active` underlined, M changed to N, and a double line added on the INSTRUMENT side of HAS_TICK. Each
was reported as a MISMATCH.

### 6.2 Rendering: the two cosmetic improvements (applied)

| Finding | Edit in `ER_CHEN_PRESENTATION.svg` |
|---|---|
| `cooldown_seconds` touched both ends of its oval | ellipse rx 112.5 → 130; its connector now ends at the new edge (x 372.5 → 390) |
| `listing` → `exchange` / `symbol` drawn as short vertical strokes | the two component ovals moved right (cx 2570 → 2600, rx 87 → 78, labels moved with them); angled links from the right end of `listing` (2482.5, 723) to each oval |

Nothing else was changed (8 exact text replacements). Verification:
- `--audit-svg` 18/18 after the edit;
- the original and the edited SVG were rendered by the same renderer and compared pixel by pixel.
  They differ only in three areas: x 2480–2680 / y 620–820 (listing components) and
  x 120–240, 280–520 / y 820–900 (the cooldown oval and its connector);
- the PNG is rendered in DejaVu Sans, the font named in the SVG and used in the team's original image
  (`python scripts/review2_diagrams.py --render … --font-dir <folder with DejaVuSans.ttf>`), and was
  inspected visually at full size.

No integrity note or key legend is on the slide, by design: both are on the reading guide, and the
diagram's footnote points to it.

### 6.3 Reading guide: every statement checked, two corrected

The guide existed only as an image. Its source was recreated as `ER_READING_GUIDE.svg` with the same
canvas, boxes, colours, font and line positions. Every text line of the recreated original lies on the
same pixel rows as the team's image. Text recognition of the team's image and of the recreation
returned the same 36 lines. Then only these lines were changed:

| Box | Before (team image) | After | Evidence |
|---|---|---|---|
| Cardinality vs participation | "An empty watchlist is permitted: CONTAINS remains partial on BOTH sides." (the reason covered one side only) | "An empty watchlist is permitted, and an instrument need not be on any watchlist: / CONTAINS remains partial on BOTH sides." | `92_er_vs_catalog.out` (both CONTAINS sides partial) |
| Integrity rule | "This alone does not prove later instrument_id edits on parent records are blocked." | "The current trigger does NOT prevent later instrument_id changes on parent records." | `22_integrity_scope.out` (parent UPDATEs accepted: 2 and 1 mismatched events, rolled back) |
| Integrity rule | "Before claiming a universal guarantee, verify parent UPDATE protection in PostgreSQL." (a to-do) | "Verified: PostgreSQL accepts such UPDATEs on alert_rules and price_ticks." / "The rule holds in practice only because no application path changes instrument_id." | same; `app/main.py` changes only is_active and cooldown_seconds |

All other statements were checked and are correct:
- six entities and seven tables;
- 1:N versus participation;
- all 14 keys (`TABLE_CONSTRAINT_INVENTORY.md`);
- the rule is checked on INSERT / UPDATE OF rule_id, tick_id (`14_triggers.out`);
- "no extra diamond";
- the five presentation lines (`ER_EXPLANATION.md`);
- the notation reminder.

Text recognition of the corrected PNG differs from the original only in the corrected lines. Every line
fits inside its box: the right-most text ends 274 px before the box edge in box B and 141 px before it in
box D. The PNG was inspected visually. A proposed fix for the parent-update gap is in
`PROPOSED_INTEGRITY_FIX.md`, not applied. If it is applied, these lines must change again.

### 6.4 Which file to use

- **Verified reference:** `ER_CORRECTED.png`, regenerable and checked against the catalog by
  `--verify-db`.
- **Slide / report figure:** `ER_CORRECTED.png`, or the team's `ER_CHEN_PRESENTATION.png` (same content,
  18/18). Use one of them, not both, as "the ER diagram". Put `ER_READING_GUIDE.png` on the next page or
  a backup slide.
- **Do not use** `~/Downloads/Real-Time Stock Market ER Diagram.png` (the recoloured copy with 8
  errors, §5), or the uncorrected `~/Downloads/ER_Explanation_Notes.png`.
