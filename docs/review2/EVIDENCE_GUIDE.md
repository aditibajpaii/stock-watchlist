# Evidence guide — what to capture, with which command, for which requirement

**Status: no screenshot has been captured yet**, and no image was produced any other way. What *has*
been done is
real execution: every command below was run, and its actual output is saved in
`docs/review2/sql_output/` (per script) and `docs/review2/QUERY_EVIDENCE.md` (per query). Your
screenshots will show the same results. Timestamps will differ, because the replay starts at build
time.

**The 61 query screenshots (E12–E19)** are taken one per query ID, in your own Terminal window, by
`bash scripts/review2_capture_screenshots.sh` (instructions in `screenshots/README.md`). Their status,
PENDING → CAPTURED → VERIFIED, is tracked per query in `SCREENSHOT_MATRIX.md`. VERIFIED means the OCR check
passed **and** a person looked at the image. The other items below are captured by hand.

Level:
- **CHECKPOINT** = in the template's "Review 2 Requirements (checklist)", needed now.
- **TEMPLATE** = in the template's detailed sections; the full targets (probably for the final review).
- **R1-FIX** = repairs a Review 1 criterion (ER 3, tables 5, normal form 2).

## Before any capture session

```sh
cd "/Users/aditi/dbms project"
source .venv/bin/activate
export PATH="/opt/homebrew/opt/postgresql@18/bin:$PATH"
bash scripts/review2_sandbox.sh --index-explain   # fresh sandbox + every script + all checks (~1 min)
```

Then either run a whole script, so its output shows every query labelled `=== ID | … | question`:

```sh
psql -d stock_watchlist_review2_sandbox -f sql/review2/04_basic_queries.sql
```

or open `psql -d stock_watchlist_review2_sandbox` and paste a single query from `QUERY_EVIDENCE.md`.
Use one screenshot per query: the SQL and its result in the same picture.

Re-running a single file is safe, with three exceptions:
- Do **not** run `01_setup.sql` alone: it recreates schema `review2` empty. Run the runner instead.
- If you re-run `13_procedures_functions.sql`, re-run `17_security.sql` afterwards: it re-applies
  SECURITY DEFINER and ownership.
- `18_login_probe.sql` must be run as `r2_analyst` (see E26).

## Priority order

| # | ID | What the screenshot must show | Command / source | Supports | Level |
|---:|---|---|---|---|---|
| 1 | E01 | corrected Chen ER diagram | insert `docs/review2/ER_CHEN_PRESENTATION.png` (team version; same content as the generated `ER_CORRECTED.png`), followed by `ER_READING_GUIDE.png` (wording corrected on 2026-10-13, `ER_FINAL_AUDIT.md` §6) | template §5 "Updated ER diagram"; ER (3) | R1-FIX, CHECKPOINT (#10) |
| 1 | E02 | before / after: Review 1 ER beside the corrected ER | `review1_original/REVIEW1_ER_AS_SUBMITTED.png` + `ER_CHEN_PRESENTATION.png` | design changes since Review 1 | CHECKPOINT #10 |
| 1 | E03 | ER diagram matches the database | `python scripts/review2_diagrams.py --verify-db stock_watchlist_review2_sandbox` (31 `OK` lines) | credibility of the ER | optional |
| 2 | E04 | relational schema (tables, PK, FK) | insert `docs/review2/RELATIONAL_SCHEMA.png` | ER → tables mapping | R1-FIX |
| 3 | E05 | CREATE TABLE for each of the 7 tables | `SCHEMA_SCREENSHOT_GUIDE.md` §A | "table creation … screenshot"; checklist #1 | R1-FIX, CHECKPOINT #1 |
| 3 | E06 | `\d <table>` for each of the 7 tables | `SCHEMA_SCREENSHOT_GUIDE.md` §B | same | R1-FIX, CHECKPOINT #1 |
| 3 | E07 | all PK / UNIQUE / FK / CHECK constraints and ON DELETE | `psql -d stock_watchlist_review2_sandbox -f sql/inspect_schema.sql` | constraints | R1-FIX, CHECKPOINT #1 |
| 3 | E08 | constraints rejecting bad data (13 real errors) | `psql -d stock_watchlist_review2_sandbox -f sql/review2/03_constraints.sql` | constraints really work | R1-FIX |
| 3 | E09 | `LIVE SCHEMA MATCHES` | `psql -d stock_watchlist_review2_sandbox -v ON_ERROR_STOP=1 -f sql/verify_spec.sql` | DDL runs cleanly and matches the design | CHECKPOINT #1 |
| 4 | E10 | normalization: FDs, keys, NF per table | `NORMALIZATION_PROOF.md` (a document, not a screenshot); optional terminal evidence: `psql -d stock_watchlist_review2_sandbox -f sql/review2/20_normalization_evidence.sql` | normal form (2) | R1-FIX |
| 5 | E11 | INSERT, UPDATE, DELETE with before/after state and the row-count table | `psql -d stock_watchlist_review2_sandbox -f sql/review2/02_dml.sql` | checklist #2 | CHECKPOINT #2 |
| 5 | E12 | basic queries B01–B07 | `bash scripts/review2_capture_screenshots.sh` → `screenshots/<ID>.png` for B01 … B07 (whole file: `… -f sql/review2/04_basic_queries.sql`) | category A (≥ 6); checklist #3 | CHECKPOINT #3, TEMPLATE |
| 6 | E13 | aggregate queries AG01–AG06; **AG04** uses WHERE and HAVING in one statement; AG05 is the contrast | `bash scripts/review2_capture_screenshots.sh` → `screenshots/<ID>.png` for AG01 … AG06 (whole file: `… -f sql/review2/05_aggregate_queries.sql`) | category B (≥ 5) | CHECKPOINT #3, TEMPLATE |
| 7 | E14 | joins J01–J07 (INNER, LEFT, RIGHT, FULL OUTER, SELF ×2, CROSS) | `bash scripts/review2_capture_screenshots.sh` → `screenshots/<ID>.png` for J01 … J07 (whole file: `… -f sql/review2/06_join_queries.sql`) | category C (≥ 6) | CHECKPOINT #3, TEMPLATE |
| 7 | E15 | subqueries S01–S11, including the NOT IN NULL pitfall (S10 → 0) and its fix (S11 → 22) | `bash scripts/review2_capture_screenshots.sh` → `screenshots/<ID>.png` for S01 … S11 (whole file: `… -f sql/review2/07_subqueries.sql`) | category D (≥ 6) | CHECKPOINT #3, TEMPLATE |
| 7 | E16 | set operations SET01–SET05 | `bash scripts/review2_capture_screenshots.sh` → `screenshots/<ID>.png` for SET01 … SET05 (whole file: `… -f sql/review2/08_set_operations.sql`) | category E (≥ 4) | CHECKPOINT #3, TEMPLATE |
| 7 | E17 | advanced functions F01–F08 | `bash scripts/review2_capture_screenshots.sh` → `screenshots/<ID>.png` for F01 … F08 (whole file: `… -f sql/review2/09_advanced_functions.sql`) | category F (≥ 6) | TEMPLATE |
| 7 | E18 | window queries W01–W05 | `bash scripts/review2_capture_screenshots.sh` → `screenshots/<ID>.png` for W01 … W05 (whole file: `… -f sql/review2/10_window_queries.sql`) | category G (≥ 2, higher band) | TEMPLATE |
| 8 | E19 | complex queries CQ01–CQ12: question, SQL, **expected** (from `QUERY_EVIDENCE.md`) beside the actual output | `bash scripts/review2_capture_screenshots.sh` → `screenshots/<ID>.png` for CQ01 … CQ12 (whole file: `… -f sql/review2/11_complex_queries.sql`) | complex business queries (≥ 10) | TEMPLATE |
| 9 | E20 | views V1–V3: CREATE VIEW, a query on each, the updatability table, the CHECK OPTION error (44000), the non-updatable error (55000) | `… -f sql/review2/12_views.sql` | views (≥ 2 checkpoint; 2–3 typed in template) | CHECKPOINT #4, TEMPLATE |
| 10 | E21 | functions and procedures: catalog list, CREATE statements, calls, INOUT result, the 42809 and 0A000 errors | `… -f sql/review2/13_procedures_functions.sql` | ≥ 1 each (checkpoint), ≥ 2 each (template) | CHECKPOINT #6, TEMPLATE |
| 10 | E22 | triggers: catalog list, alert fires once and not again, the integrity trigger rejecting a mismatch | `… -f sql/review2/14_triggers.sql` | triggers (≥ 1 / ≥ 2) | CHECKPOINT #7, TEMPLATE |
| 11 | E23 | transactions: COMMIT, ROLLBACK, SAVEPOINT, ROLLBACK TO SAVEPOINT, atomicity with the trigger, new-connection check | `… -f sql/review2/16_transactions.sql` | checklist #5 | CHECKPOINT #5 |
| 12 | E24 | index + EXPLAIN comparison on 500,000 rows (WITHOUT then WITH the index) | `psql -d stock_watchlist_benchmark -f sql/07_benchmark_queries.sql`; sizes and medians: `docs/INDEX_BENCHMARK.md` §5–6 | checklist #8 | CHECKPOINT #8 |
| 12 | E25 | the index in the project database and its plan | `… -f sql/review2/19_index_evidence.sql` | same (supporting) | CHECKPOINT #8 |
| 13 | E26 | **password login** as the restricted user, on a throwaway server: no password → refused; wrong password → `FATAL: password authentication failed`; NOLOGIN role → `FATAL: … not permitted to log in`; correct password → `system_user = scram-sha-256:r2_analyst`, the allowed view, 5 × `permission denied` | `bash scripts/review2_auth_demo.sh --show` (starts and deletes its own temporary server; no password is ever printed) | "login as restricted user → forbidden operation → error", with real authentication | TEMPLATE |
| 13 | E26b | the same restricted session on the classroom server (`system_user` is NULL there, because its pg_hba.conf uses `trust`, so no credential is checked) | `psql -d postgres -c 'ALTER ROLE r2_analyst LOGIN'`, then `psql -U r2_analyst -d stock_watchlist_review2_sandbox -f sql/review2/18_login_probe.sql`, then `psql -d postgres -c 'ALTER ROLE r2_analyst NOLOGIN'` | authorization of a separate non-superuser session (not authentication) | optional |
| 13 | E27 | roles, GRANT matrix, `\dp`, SET ROLE denials, REVOKE before/after, SECURITY DEFINER settings | `… -f sql/review2/17_security.sql` | SQL security | TEMPLATE |
| 13 | E28 | cursors: DECLARE/FETCH/MOVE/CLOSE with `pg_cursors`; PL/pgSQL OPEN/FETCH/CLOSE; cursor result = set-based result (0 differing rows) | `… -f sql/review2/15_cursors.sql` | cursors (≥ 2) | TEMPLATE |
| 13 | E29 | change log | `DESIGN_CHANGE_LOG.md` (a document) | checklist #10 | CHECKPOINT #10 |

`…` = `psql -d stock_watchlist_review2_sandbox`.

## Notes for honest captions

- `sql/inspect_schema.sql` was corrected on 2026-10-13: its index heading now names
  `ix_price_ticks_instrument_time`, and its foreign-key query no longer stops with an ORDER BY error
  (`OLDER_DOCS_CORRECTIONS.md`). Capture E07 only from the corrected script.
- The sandbox has only 30 ticks. For index *performance*, cite the 500,000-row benchmark (E24), not E25.
- Times in EXPLAIN ANALYZE output change from run to run. Caption with the plan shape and the buffer
  counts, or with the medians in `INDEX_BENCHMARK.md`, not with one run's milliseconds.
- Three different things, not to be confused in captions:
  (1) `SET ROLE` in `17_security.sql` changes the privileges in force, but the session still belongs to
  the superuser who logged in, so nothing is authenticated;
  (2) E26b is a real separate session as `r2_analyst`, but the classroom server's `trust` rule checks no
  credential (`system_user` NULL);
  (3) E26 is a real password (SCRAM) login.
  Only E26 proves authentication. Never type or show a password in a screenshot; E26 never prints one.
- Query-by-query status: `SCREENSHOT_MATRIX.md` (61 queries; regenerated by the runner).
- When finished: `bash scripts/review2_sandbox.sh --cleanup` drops the sandbox and the r2_* roles.
