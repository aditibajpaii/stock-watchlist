# Older documentation: corrections applied (before → after)

**Status: APPLIED on 2026-10-13** (Review 2 decision 5), to the working documents listed below. Each
row keeps the replaced text, so nothing is silently rewritten. Line numbers are those **before** the
correction.

Not touched: the original Review 1 report (`~/Downloads/dbms project.docx.pdf`) and its ER page copy
(`review1_original/REVIEW1_ER_AS_SUBMITTED.png`). Their corrections belong in the new report
(`REPORT_FORMAT_AUDIT.md`, `DESIGN_CHANGE_LOG.md`). No schema, application or test file was changed by
these corrections.

## 1. Documents that are no longer in `docs/`

| When | What happened | Evidence |
|---|---|---|
| until 2026-10-02 | `docs/FACT_SHEET.md`, `VIVA_NOTES.md`, `EVIDENCE_CHECKLIST.md`, `RUBRIC.md`, `RESEARCH_BRIEF.md` and `DEMO_GUIDE.md` existed and were tracked by git | committed in `2b262dc` and earlier |
| 2026-10-02 | during a documentation clean-up, the six files were moved out of the repository to a sibling folder `dbms project notes/`; `docs/PHASE1_SPEC.md` was renamed to `docs/SCHEMA_DESIGN.md` | — |
| by 2026-10-12 | that folder no longer existed and was not in the Trash | checked on 2026-10-12 and 2026-10-13 (Spotlight, home folder, Trash) |

**Decision: not restored.** The working documentation does not depend on them, and their content is
not reconstructed here. They remain in git history (`git show 2b262dc:docs/FACT_SHEET.md`).

## 2. Corrections applied

Each corrected file now carries the line "Corrected on 2026-10-13 (Review 2); … listed in
docs/review2/OLDER_DOCS_CORRECTIONS.md".

### `docs/NORMALIZATION_NOTES.md`

| Line | Text before | Problem | Text now |
|---:|---|---|---|
| 42–43 | "…inserted in a rolled-back transaction on 2026-09-25 to prove the schema accepts them." | A row the schema accepts shows the database does not *enforce* an FD; it does not decide whether the FD holds. | "…to show that the schema does not enforce these FDs; whether an FD holds is decided by the business rules." |
| 90 | "FDs checked and rejected, with the counterexample the schema accepts:" | symbol → name is not rejected by a counterexample | "Candidate FDs checked (rejected by a counterexample, or not adopted as a business rule):" |
| 94 | symbol → name: "NSE RELIANCE and BSE RELIANCE share a symbol; in general different companies can share a ticker…" → "not an FD" | **Invalid counterexample** (same company, same name) | "not adopted as a business rule: symbols are unique only within an exchange (`uq_instruments_exchange_symbol`). The RELIANCE example … does not disprove it; no verified collision is claimed" → "not used as an FD" |
| 97 | exchange → asset_class: "would be TRUE (BINANCE is always crypto)" → "column removed from the design" | **Unsound:** false in general (NSE lists equities and ETFs) | "not valid in general …; if it held, it would be a partial dependency on (exchange, symbol), i.e. a 2NF violation" → "column not included" |
| 296 | "tick_id → fired_at is false, because one tick can fire several rules." | **Wrong reason:** on the application path all events of one tick share one fired_at | "tick_id → fired_at is not an FD: fired_at is the time the event row was recorded. On the application path … share one value, but that is a property of the write path, not a rule of the data (NORMALIZATION_PROOF.md §9)." |
| 304 | "…NOT stored, because it would break 3NF:" | **Misclassified:** tick_id is part of the candidate key (rule_id, tick_id) | "…because it would break 2NF (a partial dependency on the candidate key (rule_id, tick_id)):" |
| 312–314 | "event_id → tick_id → price would be a transitive dependency: the left side tick_id is not a key…" | the dependency is first of all **partial** | "tick_id → price … would be a partial dependency …. Seen from the primary key event_id alone, … also transitive." |
| 319–320 | "A BEFORE INSERT trigger enforces it, without adding a column." | **Overstated scope:** the trigger fires on INSERT or UPDATE OF rule_id, tick_id of alert_events only | trigger named with its real events; "Later instrument_id changes on alert_rules or price_ticks are not checked (22_integrity_scope.out); no application path makes them." |
| 337 | "asset_class was removed (exchange → asset_class)." | repeats the unsound FD | "asset_class is not stored (no feature needs it; exchange → asset_class is not a valid FD in general)." |

Lines 301 ("3NF: fired_at determines nothing") and 334 (alert_events … BCNF) were **left as they
were**. Under the fired_at decision (`NORMALIZATION_PROOF.md` §9) both are correct.

### `docs/SCHEMA_DESIGN.md`

| Line | Text before | Problem | Text now |
|---:|---|---|---|
| 46 | "No asset_class column (exchange → asset_class would violate 3NF)" | misclassified and unsound | "No asset_class column (not needed; if exchange → asset_class held, it would violate 2NF as a partial dependency on (exchange, symbol))" |
| 132 (alert_events) | no statement of what fired_at means | needed for the normalization argument | added "fired_at is the time the event row was recorded (`DEFAULT now()`)" |
| 152–154 | "## E. ER diagram" over a Mermaid Crow's Foot table sketch | **Mislabelled:** it is a relational sketch | "## E. Relational schema sketch (Crow's Foot)" + "The conceptual ER diagram (Chen notation) is docs/review2/ER_CORRECTED.png." |
| 178 (F table) | alert_events "event_id → *; (rule_id, tick_id) → * \| BCNF" | fired_at's meaning was not stated | adds: fired_at = time the event row was recorded; its equality with ingested_at on the application path is not an FD (§9) |
| 182 | "exchange → asset_class is true, so the column was removed." | unsound | "exchange → asset_class is not a valid FD in general (NSE lists equities and ETFs); asset_class is simply not part of the design." |
| 260–263 | "a BEFORE INSERT trigger on alert_events rejects the insert unless …" | overstated scope | trigger named with its real events (INSERT, UPDATE OF rule_id, tick_id) + "Scope: later instrument_id changes on alert_rules or price_ticks are not checked …; a fix is proposed, not applied: PROPOSED_INTEGRITY_FIX.md" |

### `docs/ER_DIAGRAM.md`

| Where | Text before | Problem | Text now |
|---|---|---|---|
| line 1 | "# ER Diagram — stock_watchlist (live schema)" | **Mislabelled:** a Crow's Foot diagram of the tables | "# Relational schema diagram (Crow's Foot) — stock_watchlist", with a pointer to `docs/review2/ER_CORRECTED.png` and a note on `ER_DIAGRAM.mmd` / `er_diagram.png` |
| Mermaid lines 29–30, 37–38, 48–58, 66–69 | `UK` marker on each column of a composite key (`exchange UK`, `symbol UK`), and incomplete comments (alert_rules instrument_id, direction, threshold had none) | reads as several **separate** unique keys | composite-key columns carry the comment `AK1 (…)` listing the whole key; `UK` stays only on username and email (single-column keys); the Notation table explains UK and AK1 |
| lines 123–125 | "An integrity trigger requires both paths to reach the same instrument" | overstated scope | names trg_alert_events_check_instrument, "when alert_events rows are written", and states that later parent-side instrument_id changes are not checked |

`docs/ER_DIAGRAM.mmd` and `docs/er_diagram.png` (untracked export of 2026-09-25) were **not renamed or
deleted**. The note at the top of `ER_DIAGRAM.md` says what they are. Rename or remove them yourself if
you want, but never present them as the ER diagram.

### `README.md`

| Line | Text before | Text now |
|---:|---|---|
| 98 | "\| docs/SCHEMA_DESIGN.md, docs/ER_DIAGRAM.md, docs/NORMALIZATION_NOTES.md \| schema design, ER diagram, FDs/BCNF \|" | "… \| schema design, relational schema diagram, FDs/BCNF (where they differ, docs/review2 is correct) \|", plus a new row for `docs/review2/README.md` |

### `sql/inspect_schema.sql` (read-only inspection script; no schema object or data is affected)

| Line | Text before | Text now |
|---:|---|---|
| 52 | `\echo '===== Indexes (currently only those created by PK / UNIQUE) ====='` | `\echo '===== Indexes (from PK / UNIQUE constraints, plus ix_price_ticks_instrument_time) ====='` |
| 50 | `ORDER BY child_table::text, conname;` | `ORDER BY conrelid::regclass::text, conname;` |

Line 50 was a real defect found while re-running the script for screenshot E07. An output-column alias
cannot be used inside an ORDER BY expression, so the script stopped with
`ERROR: column "child_table" does not exist` before the index and row-count sections. After the fix it
runs to the end on the sandbox (exit 0, all seven sections).

## 3. Checked and found consistent (no change)

| File | What was checked |
|---|---|
| `docs/INDEX_BENCHMARK.md` | all 15 query medians, both ingest_tick medians (30.081 → 0.199 ms), the four sizes (19 / 11 / 48 / 42 MB; 120 MB total) and the identical-results flags match `docs/benchmark_results/results.json` |
| `data/README.md` | "8 alert events" per fresh run, and the per-rule split, match the replayed sandbox (`01_setup.out`) |
| `sql/verify_spec.sql` | passes on the classroom database and the sandbox |
| `docs/SCHEMA_DESIGN.md` lines 115–118 | "Design rule, not enforced by the database (no trigger): user_id, instrument_id, direction and threshold never change": accurate |

## 4. Not covered

`docs/API.md`, `docs/FRONTEND.md` and `docs/LIVE_FEED.md` describe the application rather than the
database design. They were not re-audited line by line.
