# Proposed fix: parent-side `instrument_id` changes (NOT APPLIED)

**Status:** proposal for the team's decision. It is **not** applied to `stock_watchlist`,
`stock_watchlist_benchmark` or the Review 2 sandbox. It was tested only in the throwaway database
`stock_watchlist_review2_fixtest`, which the test script creates and drops.

| File | Purpose |
|---|---|
| `sql/review2/proposed/integrity_parent_update_fix.sql` | the fix (refuses the three databases above unless run with `-v confirm_apply=yes`) |
| `sql/review2/proposed/integrity_parent_update_fix_tests.sql` | regression tests, phase `before` and phase `after` |
| `sql/review2/proposed/integrity_parent_update_fix_rollback.sql` | removes exactly what the fix adds |
| `scripts/review2_integrity_fix_test.sh` | builds the test database, runs everything, drops it |
| `scripts/review2_fixtest_suites.py` | runs the project's Python suites with the fix added to their own test databases |
| `sql_output/95_integrity_fix_test.out` | output: before, apply, after, rollback |
| `sql_output/proposed_fix_regression_suites.out` | output: SQL suites, `verify_spec.sql`, Python suites, all with the fix |

Run: `source .venv/bin/activate && bash scripts/review2_integrity_fix_test.sh`

## 1. The gap

Rule: an alert event's rule and tick must be for the same instrument. Trigger
`trg_alert_events_check_instrument` checks it only when **alert_events** rows are inserted or their
`rule_id` / `tick_id` change. A later change of `instrument_id` on the **parent** row is accepted today
(`95_integrity_fix_test.out`, phase BEFORE; also `22_integrity_scope.out`):

| Statement (rolled back) | Result today | Events left inconsistent |
|---|---|---|
| `UPDATE alert_rules SET instrument_id = 2 WHERE rule_id = 1` | accepted | 2 (events 1 and 7) |
| `UPDATE price_ticks SET instrument_id = 2 WHERE tick_id = 6` | accepted | 1 (event 1) |

No application path makes such an update, so the rule holds for all application writes. It is not
guaranteed by the database.

## 2. What changes

Three new objects. No table, column, constraint, index or row changes.

```sql
CREATE FUNCTION forbid_instrument_change() ...   -- raises check_violation (23514)
                                                 -- when NEW.instrument_id IS DISTINCT FROM OLD.instrument_id
CREATE TRIGGER trg_alert_rules_instrument_immutable
    BEFORE UPDATE OF instrument_id ON alert_rules FOR EACH ROW EXECUTE FUNCTION forbid_instrument_change();
CREATE TRIGGER trg_price_ticks_instrument_immutable
    BEFORE UPDATE OF instrument_id ON price_ticks FOR EACH ROW EXECUTE FUNCTION forbid_instrument_change();
```

Why "immutable" and not "immutable only while alert events exist":
- The check reads no other row, so concurrent transactions cannot slip past it. An "only if the row has
  no events" check would race with the alert trigger under READ COMMITTED: a tick inserted concurrently
  could create an event that the updating transaction does not see.
- It matches the documented design. A rule's definition is immutable (the API changes only `is_active`
  and `cooldown_seconds`), and a tick is a historical fact.

Alternative not proposed: copying `instrument_id` into alert_events with composite foreign keys would
enforce the rule declaratively. It would change the table and add a partial dependency (2NF), as
explained in `NORMALIZATION_PROOF.md` §8.

## 3. What becomes prohibited

Rejected with SQLSTATE 23514 for every role, the superuser included (tests T2–T6 in phase AFTER):

| Update | Test |
|---|---|
| `alert_rules.instrument_id` changed, rule **with** events | T2: `alert_rules: instrument_id cannot be changed (row 1, 1 -> 2)` |
| `price_ticks.instrument_id` changed, tick **with** an event | T3 |
| the same for a rule or tick **without** events | T4, T5 |
| a multi-row UPDATE that changes any one row | T6: whole statement rejected; instrument 1 still has 12 ticks |

The instrument key itself was already unchangeable: `instruments.instrument_id` is
`GENERATED ALWAYS AS IDENTITY` (T13: SQLSTATE 428C9). All 8 foreign keys are `ON UPDATE NO ACTION`
(catalog query C2), so no cascading update can reach the two columns either.

## 4. What still works

| Operation | Test |
|---|---|
| UPDATE that sets `instrument_id` to its current value | T7: 12 rows updated |
| the API's `PATCH /alert-rules` statement, copied from `app/main.py` | T8: rule 1 → is_active f, cooldown 120 |
| corrections to other tick columns | T9: volume updated |
| `ingest_tick` and the alert engine | T10: two ticks INSERTED; rule 1 events 2 → 3 |
| the existing alert_events check | T11: still 23514 |
| deletes and ON DELETE CASCADE | T12: deleting rule 1 removes its 2 events |

## 5. Effect on the application

**None found.**
- **Code:** no statement in `app/` or in `sql/03_functions_triggers.sql` updates `instrument_id`. The only
  `alert_rules` UPDATE is `PATCH /alert-rules` (`is_active`, `cooldown_seconds`); its request model
  rejects any other field. Ticks are only inserted, through `ingest_tick` (replay, live feed, API).
- **Project test suites with the fix applied** (`proposed_fix_regression_suites.out`):

| Suite | Result with the fix |
|---|---|
| `sql/02_schema_tests.sql` | 51/51 passed |
| `sql/04_alert_tests.sql` | 50/50 passed |
| `tests.test_replay` | 18 tests OK |
| `tests.test_api` | 32 tests OK |
| `tests.test_frontend` | 14 tests OK |
| `tests.test_live_feed` | 24 tests OK |

  The wrapper confirms that each suite's template database contained both new triggers.
- **Not run with the fix:**
  - `tests.test_indexes` reads the classroom database, which must not be changed.
  - `tests/concurrency_test.sh` builds its own database in bash.
  - Both exercise only inserts and reads, which the new triggers do not fire on.

## 6. If the team approves it

1. Apply it: `psql -d stock_watchlist -v ON_ERROR_STOP=1 -v confirm_apply=yes -f sql/review2/proposed/integrity_parent_update_fix.sql`.
2. Update `sql/verify_spec.sql`. With the fix it reports
   `SPEC MISMATCH: 0 column, 0 constraint, 3 function/trigger/index differences` (step 6 of the suites
   log), because it lists the expected functions and triggers. Update `docs/SCHEMA_DESIGN.md` likewise.
3. Re-word the documents that say parent-side changes are "not checked":
   - `ER_CORRECTED` integrity note (`scripts/review2_diagrams.py`);
   - the reading guide;
   - `NORMALIZATION_PROOF.md` §8, `TABLE_CONSTRAINT_INVENTORY.md`, `ER_FINAL_AUDIT.md`;
   - `sql/review2/22_integrity_scope.sql`, which would then show rejections.
4. Undo if needed: `integrity_parent_update_fix_rollback.sql` (tested: afterwards `verify_spec.sql`
   reports LIVE SCHEMA MATCHES again).

Limit: like every trigger, it does not apply while triggers are disabled
(`ALTER TABLE … DISABLE TRIGGER`, or `session_replication_role = replica`). Only a table owner or
superuser can do that. The benchmark and index tests disable only `trg_price_ticks_evaluate_alerts`, by
name.
