# Review 2 screenshot queries

One SQL file per screenshot. `scripts/take_screenshots.ps1` runs each file
in a real console window with psql and saves `docs/screenshots/<same name>.png`.
Each image shows the command, the SQL (echoed by `psql -e`) and PostgreSQL's
real output. Expected errors in the constraint/security demos are real
PostgreSQL errors.

Retake everything (rebuilds the dev DB; ends as seed + replay):
`powershell -ExecutionPolicy Bypass -File scripts/take_screenshots.ps1`
Retake some: `... -Only "0[5-6]*"`. Steps 111–113 need the benchmark DB
(`python tests/benchmark_indexes.py`).

## Map to "Project Template - review 2.docx"

| Template section | Screenshots |
|---|---|
| 6. Tables and Constraints: CREATE TABLE statements | S02–S08 |
| 6. Table structure / constraints / relationships | S13–S20 (`\d`), S21 (36 constraints), S22 (8 FKs, ON DELETE) |
| 6. Normal forms (evidence) | N01 (rejected FDs are false), N02 (PK + candidate keys) |
| Checklist 1: DDL runs cleanly | S02–S12 |
| Checklist 2: INSERT / UPDATE / DELETE + row counts | S09, M01, M02, M03, S23 (after seed), M04 (final) |
| Constraints rejecting bad data | CN01 UNIQUE, CN02 CHECK, CN03 FK, CN04 RESTRICT, CN05 CASCADE, CN06 duplicate tick |
| 7A Basic (≥6) | A1–A6 |
| 7B Aggregate (≥5, WHERE vs HAVING) | B1–B5 (B4 = WHERE vs HAVING) |
| 7C Joins (≥6) | C1 INNER, C2 LEFT, C3 RIGHT, C4 FULL OUTER, C5 SELF, C6 CROSS |
| 7D Subqueries (≥6) | D1 scalar, D2 single-row, D3 IN, D4 ANY/ALL, D5 correlated, D6 EXISTS, D7 NOT EXISTS, D8 NOT IN + NULL pitfall |
| 7E Set operations (≥4) | E1 UNION, E2 UNION ALL, E3 INTERSECT, E4 EXCEPT |
| 7F Functions (≥6) | F1 CASE, F2 COALESCE, F3 NULLIF, F4 date/time, F5 string, F6 numeric |
| 7G Window (≥2) | G1 ROW_NUMBER/RANK/DENSE_RANK, G2 running total, G3 LAG/LEAD |
| 8. Complex business queries (≥10) | CQ01–CQ10 |
| 8. Views (2–3) | V1 4-table join, V2 aggregated, V3 row-restricting security view, V4 updatability |
| 8. Stored procedures (≥2) | P1 list, P2 sp_create_watchlist, P3 sp_set_rule_active |
| 8. User-defined functions (≥2) | U1 fn_latest_price, U2 fn_price_change_pct |
| 8. Triggers (≥2) | S10 creation, T1 list, T2 alert fires, T3 cooldown, T4 late tick, T5 integrity trigger |
| 8. Cursors (≥2) | CR1/CR2 explicit cursor function, CR3 refcursor procedure, CR4 SQL scroll cursor |
| 8. Security | S12 (CREATE ROLE / GRANT script run), SEC1 roles, SEC2 `\dp`, SEC3 privilege matrix, SEC4 REVOKE before/after, SEC5 forbidden operations, V3 view as the only access path |
| Checklist 5: Transactions | X01 SAVEPOINT + COMMIT, X02 ROLLBACK, CN05 |
| Checklist 8: Indexes + EXPLAIN | S11, IX1 index list, IX2 without index, IX3 with index, IX4 sizes |
| Feed demo | R01 replay run (30 ticks, 8 alerts) |

## Design change since Review 1 (facts for the change log)

- Added `sql/09_review2_objects.sql`: schema `reporting` with 3 views,
  2 procedures, 3 functions (one uses a cursor), 1 procedure with a
  refcursor, and roles sw_admin / sw_analyst / sw_enduser / arjun / priya.
- Reason: Review 2 requires views, procedures, functions, cursors and
  role-based security. Kept in a separate schema so the 7 tables, 36
  constraints, ingest_tick() and the 2 triggers are unchanged
  (`sql/verify_spec.sql` still passes).
- `scripts/reset_demo_db.sh` now also runs 09.
- Roles have no passwords; the demos use `SET ROLE` from the postgres
  session to act as the restricted role.
