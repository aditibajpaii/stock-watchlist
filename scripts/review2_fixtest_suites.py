#!/usr/bin/env python3
"""Run the project's Python test suites against databases that include the
PROPOSED integrity fix (sql/review2/proposed/integrity_parent_update_fix.sql).

  python scripts/review2_fixtest_suites.py

Each suite builds its own throwaway template database by running
sql/00_schema.sql, 01_seed.sql, 03_functions_triggers.sql and 06_indexes.sql
through psql. This wrapper adds "-f <fix file>" after 06_indexes.sql in that
psql call, checks that the two new triggers really exist in the template, and
then runs the unchanged tests. Nothing in tests/ or app/ is modified, and the
classroom database stock_watchlist is not used (test_indexes, which reads it,
and the bash concurrency test are not part of this run).
"""

import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIX = ROOT / "sql" / "review2" / "proposed" / "integrity_parent_update_fix.sql"
SUITES = ["tests.test_replay", "tests.test_api", "tests.test_frontend", "tests.test_live_feed"]

_real_run = subprocess.run
applied = []      # (database, number of immutability triggers found)


def _run_with_fix(args, *a, **kw):
    if (isinstance(args, list) and args and str(args[0]).endswith("psql")
            and any(str(x).endswith("06_indexes.sql") for x in args)):
        i = max(k for k, x in enumerate(args) if str(x).endswith("06_indexes.sql"))
        args = args[:i + 1] + ["-f", str(FIX)] + args[i + 1:]
        result = _real_run(args, *a, **kw)
        if result.returncode == 0:
            db = args[args.index("-d") + 1]
            check = _real_run([args[0], "-X", "-At", "-d", db, "-c",
                               "SELECT count(*) FROM pg_trigger "
                               "WHERE tgname LIKE '%instrument_immutable'"],
                              capture_output=True, text=True)
            applied.append((db, check.stdout.strip()))
            print(f"   [fix added to {db}: {check.stdout.strip()} immutability triggers]",
                  file=sys.stderr, flush=True)
        return result
    return _real_run(args, *a, **kw)


def main():
    subprocess.run = _run_with_fix
    sys.path.insert(0, str(ROOT))
    failed = 0
    for name in SUITES:
        before = len(applied)
        suite = unittest.defaultTestLoader.loadTestsFromName(name)
        result = unittest.TextTestRunner(stream=sys.stdout, verbosity=1).run(suite)
        built = applied[before:]
        fixed = bool(built) and all(n == "2" for _, n in built)
        ok = result.wasSuccessful() and fixed
        failed += not ok
        print(f"SUITE {name}: {result.testsRun} tests, {len(result.failures)} failures, "
              f"{len(result.errors)} errors; template(s) with the fix: "
              f"{', '.join(db for db, _ in built) or 'NONE'} -> {'PASS' if ok else 'FAIL'}",
              flush=True)
    print("ALL SUITES PASSED WITH THE FIX" if not failed else f"{failed} SUITE(S) FAILED")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
