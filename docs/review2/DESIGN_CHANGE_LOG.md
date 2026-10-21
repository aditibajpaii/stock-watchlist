# Design changes since Review 1 (change log with reasons)

For the Review 2 checklist item "Design changes since Review 1 — Change log with reasons".

Sources compared:
- **Review 1 submission:** `~/Downloads/dbms project.docx.pdf` (8 pages; left unchanged). Its ER page is
  copied to `docs/review2/review1_original/REVIEW1_ER_AS_SUBMITTED.png`.
- **Current database:** the PostgreSQL catalog of a database built from `sql/00_schema.sql`, `03` and
  `06` (`TABLE_CONSTRAINT_INVENTORY.md`).

Two kinds of change are kept apart:
- **A. Documentation correction:** the submitted diagram or text was wrong or incomplete. The database
  was already right.
- **B. Database implementation change:** the tables, constraints, functions, triggers or indexes
  changed.

## A. Documentation corrections

| # | OLD REVIEW 1 ISSUE | WHY IT WAS INCORRECT | CORRECTED REPRESENTATION | CURRENT VERIFICATION / EVIDENCE |
|---|---|---|---|---|
| D1 | ER (p.5): arrowheads on every attribute line and on relationship lines, some double-headed | Chen notation (the faculty template's sample) uses plain lines. An arrow on an attribute line means nothing. In notations that do use arrows, an arrow means "at most one", but several pointed into the **many** side and contradicted the 1/n labels. | plain lines only; cardinality shown by 1 / N / M beside each relationship line | `ER_CORRECTED.png`; layout check in `scripts/review2_diagrams.py` |
| D2 | ER: no total participation anywhere | Every watchlist, rule, tick and event must have its parent: all 8 foreign keys are NOT NULL. Leaving participation out drops half of each structural constraint. | double line on the WATCHLIST, ALERT_RULE (×2), PRICE_TICK and ALERT_EVENT (×2) sides; single lines where participation is optional | `sql_output/92_er_vs_catalog.out`: participation = FK NOT NULL for all 7 relationships |
| D3 | ER: `Watchlist_item` drawn as a weak entity (double rectangle) with single diamonds CONTAINS / ADDED_TO, and owner keys `watchlist_id`, `instrument_id` drawn as its own underlined attributes | It has no partial key of its own: its whole identity is the two owners' keys. That makes it an **M:N relationship**, not a weak entity. The weak-entity drawing was itself incomplete (no identifying double diamonds, no total participation). | relationship CONTAINS between WATCHLIST (M) and INSTRUMENT (N), with attribute `added_at`. No Watchlist_item entity. | `ER_EXPLANATION.md`; mapping step 5 in `ER_TO_RELATIONAL_MAPPING.md`; `92_er_vs_catalog.out` (CONTAINS is M:N) |
| D4 | ER: ADDED_TO linked Instruments to Watchlist_item | The real fact is "an instrument is on a watchlist". Linking it to the junction box shows the diagram was drawn from the tables. | one relationship CONTAINS between the two entities | `ER_CORRECTED.png` |
| D5 | ER: only surrogate ids underlined; `username`, `email` and the pair (exchange, symbol) not shown as keys | Normalization is tested against candidate keys, so missing keys hide the business rules (no duplicate listing, unique usernames). | `username` and `email` underlined; composite key attribute `listing` = (exchange, symbol) underlined; keys that include a relationship listed in the diagram's Keys legend | `92_er_vs_catalog.out`: underlined keys = single-column PK/UNIQUE; listing = `UNIQUE (exchange, symbol)`; 4 legend keys are declared UNIQUE constraints |
| D6 | ER: entity names mixed (User / Watchlists / Price_Ticks / Alert_events / Watchlist_item) | An entity type is named in the singular, and one convention should be used throughout. | USER, WATCHLIST, INSTRUMENT, PRICE_TICK, ALERT_RULE, ALERT_EVENT | `ER_CORRECTED.png` |
| D7 | ER: attribute spelt `quote_currentcy` | misspelling of the column `quote_currency` | `quote_currency` | `review1_original/REVIEW1_ER_AS_SUBMITTED.png` versus `ER_CORRECTED.png` |
| D8 | The ER diagram and the tables section contradicted each other in 8 places (`username`/`name`, `quote_currency`/`currency`, `is_active`/`active`, `rule_id`/`alert_rule_id`, `is_active`/`enabled`, `event_id`/`alert_event_id`, `instruments.created_at` only in the tables, `price_ticks.ingested_at` only in the ER) | Two documents described two different schemas, and the tables section did not match the database. | Both diagrams and the inventory follow the catalog. The database was **not** renamed to match the old report. | `TABLE_CONSTRAINT_INVENTORY.md` reconciliation (16 rows checked automatically) and `92_er_vs_catalog.out` |
| D9 | Tables section: constraints missing: `UNIQUE (exchange, symbol)`, `UNIQUE (user_id, name)`, `UNIQUE (source, instrument_id, source_event_id)`, `UNIQUE (user_id, instrument_id, direction, threshold)`, `UNIQUE (rule_id, tick_id)`, every ON DELETE action, the CHECKs on exchange and source | The documented design allowed duplicate listings, duplicate rules and duplicate alerts. It also claimed "idempotency" for `source_event_id` with no constraint enforcing it. | inventory read from the catalog: 36 named constraints (7 PK, 7 UNIQUE, 8 FK with 4 CASCADE + 4 RESTRICT, 14 CHECK) | `TABLE_CONSTRAINT_INVENTORY.md`; `sql_output/03_constraints.out` (13 real rejections) |
| D10 | Tables section: `volume NOT NULL`; `price` and `threshold` as plain `NUMERIC` | The column allows NULL (unknown volume ≠ 0; 8 replayed ticks have it), and the types are `numeric(18,8)` / `numeric(24,8)`. | as in the catalog | inventory; QE B06 |
| D11 | Tables section: no CREATE TABLE statements, no screenshots, no per-table description | The criterion is "Table creation with description and screenshot". | per-table purpose, keys and relationships in the inventory; exact screenshot commands | `SCHEMA_SCREENSHOT_GUIDE.md` (screenshots **pending manual capture**) |
| D12 | No normalization section (the only mention was one sentence in the abstract) | "Normal form" carries 2 of the 10 marks. | candidate keys, FDs, 1NF–BCNF per table, decomposition example, corrected earlier notes | `NORMALIZATION_PROOF.md` |
| D13 | ER readability: font sizes differed between ovals, long elbow connectors, one oval's text crossing its border | It is hard to read on a projector. | regenerated diagram with automated checks: no overlaps, no crossings, every text fits | `scripts/review2_diagrams.py` output (layout OK, text-fit OK); PNG inspected |
| D14 | The rule "an alert event's rule and tick are for the same instrument" was not shown | It is a real integrity rule across a cycle of relationships. | dashed note on the generated ER diagram, and the team's reading guide, stating its exact scope: checked on writes to alert_events, not on later parent-side instrument_id changes | `14_triggers.out` (RELIANCE rule + TCS tick → 23514); `22_integrity_scope.out` (parent UPDATEs accepted) |
| D15 | Earlier internal notes: an invalid counterexample (symbol → name), an overstated FD (exchange → asset_class), 3NF/2NF misclassifications, and a wrong reason given for tick_id ↛ fired_at | Precision of the normalization argument. | corrections listed in `NORMALIZATION_PROOF.md` §11, applied to the working documents on 2026-10-13 (before → after in `OLDER_DOCS_CORRECTIONS.md`). | `NORMALIZATION_PROOF.md` §9, §11; `sql_output/20_normalization_evidence.out` (N1: 8/8) |
| D16 | Report format: table-of-contents page numbers wrong, work breakdown numbers without a legend | Presentation accuracy. | to be fixed by the team in the report | `REPORT_FORMAT_AUDIT.md` |

## B. Database implementation changes

**None were made during this Review 2 work.** SHA-256 checksums of every pre-existing file in `sql/`,
`app/`, `scripts/`, `tests/`, `data/` and `docs/` (53 files) were recorded before the work started and
compared at the end. The only pre-existing files that changed are the documentation corrections of
2026-10-13 (`docs/NORMALIZATION_NOTES.md`, `docs/SCHEMA_DESIGN.md`, `docs/ER_DIAGRAM.md`, `README.md`)
and the read-only inspection script `sql/inspect_schema.sql` (one heading, one ORDER BY fix), all listed
in `OLDER_DOCS_CORRECTIONS.md`. No schema, function, trigger, index, application or test file changed.

What *was added* (new files only, nothing replaced):
- `sql/review2/*.sql`: academic demonstrations. They run only in the throwaway database
  `stock_watchlist_review2_sandbox`, and their objects live in schema `review2`.
- `scripts/review2_*.{sh,py}`: runner, evidence checker, diagram generator, inventory generator.
- `docs/review2/*`: these documents and the evidence logs.

Whether the constraints in D9 already existed in the database **at the time of Review 1** cannot be
decided from the files alone. The commit log records the base schema commit on 2026-09-25 13:12 IST.
`sql/00_schema.sql` was last modified on 2026-09-30 17:34 and was uncommitted when the Review 2 work
began (`git diff 2b262dc -- sql/00_schema.sql` shows those changes). If Review 1 was held
after 2026-09-25, the constraints existed and the report under-documented them. If it was held before,
they were implemented after Review 1. Please state which applies in the report.

**Decided, no change:** `alert_events.fired_at` is kept unchanged and documented as the time the event
row was recorded. On the application path its value equals the tick's `ingested_at` because both rows
are written in one transaction; that is a property of the write path, not a functional dependency, so no
2NF violation is claimed. Evidence: `sql_output/21_fired_at_analysis.out`; `NORMALIZATION_PROOF.md` §9.

**Proposed, not applied:** a fix for the parent-update gap of the same-instrument rule (D14), with
regression tests run in a separate throwaway database: `PROPOSED_INTEGRITY_FIX.md`.
