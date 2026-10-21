# Review 2 requirements audit

Authority: the faculty's `Project Template - review 2.docx` (read in full), checked line by line. It has
two levels that are **not identical**, and they are reported separately:

- **CHECKPOINT:** the short "Review 2 Requirements (checklist)" table (items 1–10). Needed at Review 2.
- **TEMPLATE:** the detailed sections (SQL Implementation categories A–G, Advanced SQL Implementation).
  These are the full targets; whether all of them are due at Review 2 or only at the final review is
  **not stated** in the template, so ask the faculty. Everything at this level is implemented anyway.

Plus the Review 1 rubric (ER 3, tables with description and screenshot 5, normal form 2), as printed
in your own Review 1 report's evaluation table.

Status values: PASS · PARTIAL · FAIL · NOT VERIFIED · NOT YET REQUIRED. Screenshot parts are
**PENDING** until a real screenshot exists *and* has been looked at. Execution is verified for every
item; no image has been produced yet. For the 61 queries, the per-query state (PENDING / CAPTURED /
VERIFIED) is generated in `SCREENSHOT_MATRIX.md`.

Updated 2026-10-13 after the team's final Review 2 decisions:
- `fired_at` is the event row's recording time;
- `ER_CORRECTED.png` is the verified reference;
- the presentation diagram has two cosmetic fixes and the reading guide two wording corrections;
- the integrity fix is proposed, not applied;
- the older documents are corrected;
- the screenshot tooling is ready.

---

## 1. Materials examined (Stage A)

| Material | Available? | Where | Note |
|---|---|---|---|
| Review 1 submitted report | yes | `~/Downloads/dbms project.docx.pdf` (8 pages) | read in full; not modified (SHA-256 `6bdcd39d…8942` identical before and after) |
| Review 1 ER diagram | yes | report page 5 → copy `docs/review2/review1_original/REVIEW1_ER_AS_SUBMITTED.png` | Chen-style diagram; findings re-checked at full resolution |
| Strict Review 1 evaluation | yes | working notes (not kept as a file) | used as the issue list; every issue re-verified against the PDF |
| Faculty template | yes | `~/Downloads/Project Template - review 2.docx` | text, tables and sample ER image read |
| `docs/ER_DIAGRAM.md`, `docs/ER_DIAGRAM.mmd`, `docs/er_diagram.png` | yes | repo | a Mermaid **table** diagram. It is **not** the Review 1 diagram, and was not treated as one. |
| `docs/NORMALIZATION_NOTES.md` | yes | repo | reviewed; errors listed in `NORMALIZATION_PROOF.md` §11 and **corrected on 2026-10-13** (before → after in `OLDER_DOCS_CORRECTIONS.md`) |
| `docs/PHASE1_SPEC.md` | renamed | now `docs/SCHEMA_DESIGN.md` (renamed during the 2 Oct clean-up) | reviewed |
| `docs/FACT_SHEET.md` | **NOT AVAILABLE** | moved on 2 Oct, during a documentation clean-up, into the sibling folder `dbms project notes/`. That folder was later removed: no copy on disk, in Spotlight or in the Trash. It exists only in git history. | not used and **not restored** (team decision); history in `OLDER_DOCS_CORRECTIONS.md` §1 |
| `sql/00_schema.sql` | yes | repo | authoritative DDL; built into the sandbox; catalog = design (`verify_spec`) |
| `sql/verify_spec.sql` and all other `sql/*.sql` | yes | repo | run read-only; unchanged, except `sql/inspect_schema.sql` (read-only inspection script: corrected heading, and an ORDER BY error fixed, so that it runs to the end) |

---

## 2. Requirement-by-requirement audit

### 2.1 Review 1 criteria (the corrections)

| Requirement | Level | Status | Evidence | Missing work | Priority | Verification method |
|---|---|---|---|---|---|---|
| Correct ER diagram (Chen, keys, cardinality, participation) | R1 / template §5 | **PASS** | **verified reference: `ER_CORRECTED.png/.svg`** (`--verify-db` 31/31). Team presentation version `ER_CHEN_PRESENTATION.png/.svg` (two cosmetic fixes applied on 2026-10-13; audit 18/18) with `ER_READING_GUIDE.png/.svg` (two wording corrections). `ER_EXPLANATION.md`, `ER_FINAL_AUDIT.md` §6. | insert in report. **Do not use** the recoloured copy in `~/Downloads` (8 errors, `ER_FINAL_AUDIT.md` §5). | 1 | automated layout and text-fit checks; `--verify-db` 31/31 against the catalog (7 tables, 8 FKs, 14 keys, participation); `--audit-svg` 18/18 for the team SVG; same-renderer diff (only the two fixed areas changed); OCR diff of the reading guide (only the corrected lines changed); visual inspection of all three PNGs |
| ER diagram consistent with tables | R1 | **PASS** | `92_er_vs_catalog.out`; inventory reconciliation (16/16 verified) | — | 1 | catalog queries |
| Table description + relationships per table | R1 / template §6 | **PASS** | `TABLE_CONSTRAINT_INVENTORY.md` (read from the catalog) | write captions in the report | 2 | generator reads pg_catalog |
| Screenshots of table creation | R1 / template §6 | **PARTIAL** — PENDING MANUAL CAPTURE | commands in `SCHEMA_SCREENSHOT_GUIDE.md` (each tested) | capture 7 CREATE TABLE + 7 `\d` + constraint listing | 1 | the commands were executed while writing the guide |
| Normal form per table | R1 / template §6 | **PASS** (all seven tables BCNF) | `NORMALIZATION_PROOF.md` (§9: `fired_at` = the event row's recording time, team decision; no 2NF violation claimed); `20_normalization_evidence.out`, `21_fired_at_analysis.out` | — | 2 | FD analysis per table; the application-path equality of fired_at and ingested_at checked against code, catalog and accepted counter-states, and classified as a write-path property, not an FD |

### 2.2 Review 2 checkpoint (template checklist items 1–10)

| # | Requirement | Status | Evidence | Missing work | Priority | Verification method |
|---|---|---|---|---|---|---|
| 1 | CREATE TABLE scripts + all constraints ("01_ddl.sql runs cleanly") | **PASS** | `sql/00_schema.sql` (the project's DDL file, not named 01_ddl.sql) builds the sandbox with ON_ERROR_STOP; `90_verify_spec_sandbox.out`: LIVE SCHEMA MATCHES | screenshots (row 9) | 1 | runner build step + verify_spec |
| 2 | INSERT, UPDATE, DELETE + row-count table | **PASS** | `sql/review2/02_dml.sql` → `02_dml.out` (8 statements, before/after state, ROW_COUNT summary, counts restored) | screenshots | 1 | executed; checker OK |
| 3 | Basic, aggregate, join, subquery, set-operation queries (≥ 20) | **PASS (36)** | `QUERY_EVIDENCE.md` | screenshots | 1 | every query run alone; ≥ 1 row each; keyword coverage checked |
| 4 | Views (≥ 2) | **PASS (3)** | `12_views.out` | screenshots | 2 | executed; updatability read from information_schema |
| 5 | Transactions: COMMIT / ROLLBACK / SAVEPOINT demonstration script | **PASS** | `16_transactions.out` (T1–T5) | screenshots | 2 | executed; expected errors 2/2 confirmed |
| 6 | Procedures and functions (≥ 1 each working) | **PASS** (2 procedures, 3 callable functions) | `13_procedures_functions.out` | screenshots | 2 | executed |
| 7 | Triggers (≥ 1 working) | **PASS** (2) | `14_triggers.out` | screenshots | 2 | executed (alert fired once, then not; integrity error 23514) |
| 8 | Indexes + one EXPLAIN comparison | **PASS** | `91_index_explain_benchmark.out` (fresh run on 500,000 rows, without and with the index); `INDEX_BENCHMARK.md`; `19_index_evidence.out` | screenshots | 2 | executed on `stock_watchlist_benchmark`; the heavy benchmark was not re-run |
| 9 | Execution screenshots with SQL | **PARTIAL** — 0 of 61 query screenshots captured; other screenshots also pending | real output in `sql_output/`; `SCREENSHOT_MATRIX.md`: 61/61 queries showable with SQL + output in one 150 × 42 window; capture script, OCR check and visual-check record ready (`screenshots/README.md`) | **run `bash scripts/review2_capture_screenshots.sh` in Terminal.app**, look at each image and record it (`visual-ok`); capture the non-query items of `EVIDENCE_GUIDE.md` by hand | 1 | dry run of all 61 displays (0 errors, max 36 lines × 143 columns); OCR checker tested on test images (pass, fail and REDO cases) |
| 10 | Design changes since Review 1 (change log with reasons) | **PASS** | `DESIGN_CHANGE_LOG.md` (D1–D16; no database changes) | include in the report | 1 | each entry cites a file |

### 2.3 Template — SQL Implementation (categories A–G)

| Category | Minimum | Status | Actual | Coverage verified | Evidence |
|---|---:|---|---:|---|---|
| A. Basic: SELECT, WHERE, ORDER BY, DISTINCT, BETWEEN, IN, LIKE, IS NULL | 6 | **PASS** | 7 | all 8 keywords | QE B01–B07 |
| B. Aggregate: COUNT, SUM, AVG, MIN, MAX, GROUP BY, HAVING; WHERE vs HAVING in one query | 5 | **PASS** | 6 | all, plus AG04 (WHERE and HAVING in one statement) | QE AG01–AG06 |
| C. Joins: INNER, LEFT, RIGHT, FULL OUTER, SELF, CROSS | 6 | **PASS** | 7 | all 6 kinds (SELF twice) | QE J01–J07 |
| D. Subqueries: scalar, single-row, multi-row IN/ANY/ALL, correlated, EXISTS, NOT EXISTS, NOT IN with the NULL pitfall | 6 | **PASS** | 11 | all; pitfall S10 = 0, fix S11 = 22 | QE S01–S11 |
| E. Set operations: UNION, UNION ALL, INTERSECT, EXCEPT | 4 | **PASS** | 5 | all; cross-checked with J04 (4 + 7 + 1 = 12) | QE SET01–SET05 |
| F. Advanced functions: CASE, COALESCE, NULLIF, date/time, string, numeric | 6 | **PASS** | 8 | all | QE F01–F08 |
| G. Window/analytic (recommended, higher band) | 2 | **PASS** | 5 | ROW_NUMBER, RANK, DENSE_RANK, LAG, LEAD, running total, moving average | QE W01–W05 |
| "Screenshot of each query with at least one output" | all | **PARTIAL** — PENDING (0 of 61 captured) | 49 executed (61 with the complex queries) | all showable with SQL + ≥ 1 row in one shot; capture tooling ready | `SCREENSHOT_MATRIX.md`, `screenshots/README.md` |

### 2.4 Template — Advanced SQL Implementation

| Requirement | Minimum | Status | Actual | Evidence |
|---|---|---|---|---|
| Complex business queries with ID, business question, SQL, expected output (predicted before execution), actual output, explanation | 10 | **PASS** (screenshots pending) | 12; each uses ≥ 3 tables or a nested/analytic construct (checked automatically); all 12 predictions matched | QE CQ01–CQ12 |
| Views: ≥ 3-table join, aggregated, security/row-restricting; purpose, CREATE VIEW, query, why useful, updatable or not | 2–3 | **PASS** | 3 (V1: 5 tables, not updatable; V2: aggregated, not updatable; V3: row-restricting, updatable WITH CHECK OPTION, the support role's only access path) | `12_views.out`, `17_security.out` |
| Stored procedures | 2 | **PASS** | 2 (`CREATE PROCEDURE`: sp_add_watchlist_item, sp_set_rule_active with INOUT) | `13_procedures_functions.out` |
| User-defined functions | 2 | **PASS** | 3 callable: `ingest_tick` (production) + `review2.fn_latest_price`, `review2.fn_rule_distance_pct` | same |
| Triggers | 2 | **PASS** | 2 (production triggers re-used; none added) | `14_triggers.out` |
| Cursors | 2 | **PASS** | 2: SQL-level SCROLL cursor; PL/pgSQL explicit cursor in `review2.fn_max_drawdown` (result equals the set-based result, 0 differing rows) | `15_cursors.out` |
| Security: ≥ 3 users/roles (CREATE ROLE script) | 3 | **PASS** | 4: r2_owner, r2_analyst, r2_support, r2_feed (sandbox-only privileges, NOLOGIN) | `17_security.out` |
| GRANT per role matrix + `\dp` | — | **PASS** | matrix from has_*_privilege; `\dp` for 2 tables and the review2 views | same |
| REVOKE with before/after | — | **PASS** | REVOKE SELECT ON price_ticks (\dp and query before/after); REVOKE EXECUTE … FROM PUBLIC (t → f) | same |
| Least privilege: log in as a restricted user → forbidden operation → error | — | **PASS** (screenshot pending) | (1) **password login**: on a throwaway server with SCRAM authentication, a wrong password and a NOLOGIN role are refused; with the correct password `system_user = scram-sha-256:r2_analyst`, and 5 operations fail with 42501. (2) On the classroom server, the same probe opens a real non-superuser session, but that server's `trust` rule checks no credential (`system_user` NULL), so it is authorization only. (3) `SET ROLE` in 17 is authorization testing inside the superuser's session, **not** a login. | `93_auth_demo.out`; `18_login_probe.out`; `17_security.out` |
| Secure exposure: views/procedures as the only access path | — | **PASS** | support: view V3 + definer procedure; feed: definer function; analyst: view V2; direct base-table access denied | `17_security.out` |

### 2.5 Not a faculty requirement: known limitation and proposal

| Item | Status | Evidence | Decision needed |
|---|---|---|---|
| Same-instrument rule for alert events | enforced on writes to alert_events; **not** on later parent-side `instrument_id` changes (accepted today; no application path makes them) | `22_integrity_scope.out` | — |
| Proposed fix: `instrument_id` immutable on alert_rules and price_ticks (2 triggers, 1 function) | **PROPOSED, NOT APPLIED**. Tested only in a throwaway database: 7/7 expected rejections; SQL suites 51/51 and 50/50; Python suites 88 tests OK with the fix; no application change needed | `PROPOSED_INTEGRITY_FIX.md`; `95_integrity_fix_test.out`; `proposed_fix_regression_suites.out` | approve or decline; if approved, also update `verify_spec.sql` and `SCHEMA_DESIGN.md` |

### 2.6 Report document (team writes it)

| Item | Status | Note |
|---|---|---|
| Cover, abstract, contacts, intro, scope | NOT VERIFIED (report not written yet) | Review 1 versions reviewed in `REPORT_FORMAT_AUDIT.md`; the abstract needs a rewrite |
| Table of contents with correct page numbers | FAIL in Review 1 | regenerate |
| Software requirements with versions | PARTIAL in Review 1 | versions listed in the format audit |
| Accurate individual work breakdown | NOT VERIFIED | only the team knows who did what; Review 1 had no legend |
| SQL and Advanced SQL sections | NOT VERIFIED (to be written) | all evidence ready |

---

## 3. Final cross-check — CHECKPOINT (Review 2 checklist)

| REQUIREMENT | FACULTY MINIMUM | ACTUAL COUNT | VERIFIED EVIDENCE | STATUS |
|---|---|---|---|---|
| CREATE TABLE + all constraints | runs cleanly | 7 tables, 36 named constraints, 36 of 37 columns NOT NULL | runner build (ON_ERROR_STOP); `90_verify_spec_sandbox.out` | PASS |
| INSERT / UPDATE / DELETE + row-count table | present | 4 INSERT, 2 UPDATE, 2 DELETE (+ cascade) | `02_dml.out` | PASS |
| Categorized queries (basic, aggregate, join, subquery, set) | ≥ 20 | 36 | `QUERY_EVIDENCE.md` | PASS |
| Views | ≥ 2 | 3 | `12_views.out` | PASS |
| Transactions demo | present | 5 scenarios (COMMIT, ROLLBACK, SAVEPOINT + ROLLBACK TO, atomicity with trigger, new connection) | `16_transactions.out` | PASS |
| Procedures / functions | ≥ 1 each | 2 procedures / 3 callable functions | `13_procedures_functions.out` | PASS |
| Triggers | ≥ 1 | 2 | `14_triggers.out` | PASS |
| Indexes + EXPLAIN comparison | 1 | 1 index, comparison on 500,000 rows (4 query shapes, without/with) | `91_index_explain_benchmark.out`, `INDEX_BENCHMARK.md` | PASS |
| Execution screenshots with SQL | each item | 0 captured (61 queries + the other items) | tooling: `scripts/review2_capture_screenshots.sh` | **PARTIAL — PENDING** |
| Design changes since Review 1 | change log | 16 documented corrections, 0 database changes | `DESIGN_CHANGE_LOG.md` | PASS |

## 4. Final cross-check — TEMPLATE (detailed targets)

| REQUIREMENT | FACULTY MINIMUM | ACTUAL COUNT | VERIFIED EVIDENCE | STATUS |
|---|---|---|---|---|
| A. Basic | 6 | 7 | QE | PASS |
| B. Aggregate (with WHERE vs HAVING) | 5 | 6 | QE (AG04) | PASS |
| C. Joins | 6 | 7 | QE | PASS |
| D. Subqueries | 6 | 11 | QE | PASS |
| E. Set operations | 4 | 5 | QE | PASS |
| F. Advanced functions | 6 | 8 | QE | PASS |
| G. Window/analytic (recommended) | 2 | 5 | QE | PASS |
| Complex business queries | 10 | 12 | QE (expected = actual for 12/12) | PASS |
| Views (join ≥ 3 tables, aggregated, security/row-restricting) | 2–3 | 3 | `12_views.out`, `17_security.out` | PASS |
| Stored procedures | 2 | 2 | `13_procedures_functions.out` | PASS |
| User-defined functions | 2 | 3 | same | PASS |
| Triggers | 2 | 2 | `14_triggers.out` | PASS |
| Cursors | 2 | 2 | `15_cursors.out` | PASS |
| Users/roles | 3 | 4 | `17_security.out` | PASS |
| GRANT matrix, REVOKE before/after, restricted login error (password-authenticated), secure exposure | each | all four | `17_security.out`, `93_auth_demo.out`, `18_login_probe.out` | PASS |
| Screenshot of each query / object | each | 0 captured | — | **PARTIAL — PENDING** |

## 5. Readiness verdict

| Level | Implemented and verified | Missing |
|---|---|---|
| **Faculty checkpoint** (checklist items 1–10) | items 1–8 and 10 PASS | item 9: screenshots (0 captured) |
| **Template targets** (categories A–G, advanced SQL) | every target met or exceeded (table §4) | the screenshot of each query / object |
| Review 1 corrections | ER, tables, normal form: PASS | table-creation screenshots |

**NOT READY TO SUBMIT.**
- **Technically complete and verified:** every checkpoint and template item is implemented, executed and
  checked.
- **Still missing:**
  1. the screenshots (checkpoint item 9, mandatory). Query screenshots: run the capture script, then
     the visual check. Other screenshots: by hand;
  2. the team-written report sections (`REPORT_FORMAT_AUDIT.md`).
- **Open decision, not a blocker:** whether to apply the proposed integrity fix (§2.5).

Re-assess after both missing items are done.
