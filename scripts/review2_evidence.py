#!/usr/bin/env python3
"""Review 2 evidence tool. Reads files and the sandbox database only.

  python scripts/review2_evidence.py check docs/review2/sql_output/*.out
      Verifies real psql output. Every "ERROR:" line must be announced by
      a  >>> EXPECTED ERROR [sqlstate]  marker and confirmed by the
      <<< actual SQLSTATE: <code>  line that follows it. Any other error,
      a missing error, or a different SQLSTATE fails the check.

  python scripts/review2_evidence.py queries \
         --db stock_watchlist_review2_sandbox --out docs/review2/QUERY_EVIDENCE.md
      Runs every catalogued query of sql/review2/04..11 ONE AT A TIME on the
      sandbox, records the actual output and row count, checks that the
      required keywords of each faculty category are really present, and
      writes the evidence file. Nothing in it is typed by hand.

  python scripts/review2_evidence.py ids
  python scripts/review2_evidence.py block <ID> --out <file.sql>
      List the 61 query IDs / write one query as a psql script (used by
      scripts/review2_capture_screenshots.sh, which takes the screenshots).

  python scripts/review2_evidence.py verify-shots --db stock_watchlist_review2_sandbox
      Reads every screenshot in docs/review2/screenshots/ with macOS text
      recognition (scripts/review2_ocr.swift) and checks that it shows the
      query label, the first SQL line, the column headings and the first
      result row. Results: docs/review2/screenshots/ocr_check.json; then
      the matrix is regenerated.

  python scripts/review2_evidence.py visual-ok <ID>... --by <name> [--result REDO --note "..."]
      Records that a person looked at the screenshot (VISUAL_CHECK.csv,
      tied to the file's SHA-256, so a new capture needs a new check).

Query blocks in the SQL files look like:
  \\echo '=== B01 | SELECT, WHERE, ORDER BY | Which NSE instruments ...?'
  -- @expected: ...      (complex queries: prediction written before running)
  -- @explain: ...
  -- @rows: 0            (only when an empty result is the point, e.g. NOT IN pitfall)
  SELECT ...;
"""

import argparse
import csv
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SQL_DIR = ROOT / "sql" / "review2"
PSQL = [os.path.join(os.environ.get("PG_BIN", "/opt/homebrew/opt/postgresql@18/bin"), "psql"),
        "-X", "-q", "-v", "ON_ERROR_STOP=1", "-P", "pager=off"]

# --------------------------------------------------------------------------
# check
# --------------------------------------------------------------------------
ERR_RE = re.compile(r"^psql:[^:]+:\d+: ERROR:")
EXP_RE = re.compile(r"^>>> EXPECTED ERROR \[([0-9A-Z]{5})\]")
ACT_RE = re.compile(r"^<<< actual SQLSTATE: ?([0-9A-Z]{5})")


def check_file(path: Path):
    problems, expected, errors, confirmed = [], 0, 0, 0
    pending = None
    for n, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
        if m := EXP_RE.match(line):
            if pending:
                problems.append(f"line {n}: previous expected error [{pending}] never confirmed")
            pending, expected = m.group(1), expected + 1
        elif ERR_RE.match(line):
            errors += 1
            if pending is None:
                problems.append(f"line {n}: UNEXPECTED {line.strip()}")
        elif m := ACT_RE.match(line):
            if pending is None:
                problems.append(f"line {n}: SQLSTATE line without an expected-error marker")
            elif m.group(1) != pending:
                problems.append(f"line {n}: expected SQLSTATE {pending}, got {m.group(1)}")
            else:
                confirmed += 1
            pending = None
    if pending:
        problems.append(f"expected error [{pending}] at end of file never confirmed")
    if errors != expected:
        problems.append(f"{errors} ERROR line(s) but {expected} expected-error marker(s)")
    return problems, expected, confirmed


def cmd_check(files):
    failed = 0
    for f in map(Path, files):
        problems, expected, confirmed = check_file(f)
        state = "OK  " if not problems else "FAIL"
        print(f"   {state} {f.name:<40} expected errors confirmed: {confirmed}/{expected}")
        for p in problems:
            print(f"        - {p}")
        failed += bool(problems)
    if failed:
        print(f"CHECK FAILED in {failed} file(s)")
        return 1
    return 0


# --------------------------------------------------------------------------
# queries
# --------------------------------------------------------------------------
CATEGORIES = [  # file, key, title, template minimum, required coverage tags
    ("04_basic_queries.sql", "A", "A. Basic", 6,
     ["SELECT", "WHERE", "ORDER BY", "DISTINCT", "BETWEEN", "IN", "LIKE", "IS NULL"]),
    ("05_aggregate_queries.sql", "B", "B. Aggregate", 5,
     ["COUNT", "SUM", "AVG", "MIN", "MAX", "GROUP BY", "HAVING", "WHERE vs HAVING"]),
    ("06_join_queries.sql", "C", "C. Joins", 6,
     ["INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL OUTER JOIN", "SELF JOIN", "CROSS JOIN"]),
    ("07_subqueries.sql", "D", "D. Subqueries", 6,
     ["scalar", "single-row", "multi-row IN", "ANY", "ALL", "correlated", "EXISTS",
      "NOT EXISTS", "NOT IN", "NULL pitfall"]),
    ("08_set_operations.sql", "E", "E. Set operations", 4,
     ["UNION", "UNION ALL", "INTERSECT", "EXCEPT"]),
    ("09_advanced_functions.sql", "F", "F. Advanced functions", 6,
     ["CASE", "COALESCE", "NULLIF", "date/time", "string", "numeric"]),
    ("10_window_queries.sql", "G", "G. Window/analytic (recommended, higher band)", 2,
     ["ROW_NUMBER", "RANK", "LAG", "LEAD", "running total"]),
    ("11_complex_queries.sql", "CQ", "Complex business queries", 10, []),
]

# A declared tag is only accepted if this pattern really occurs in the SQL.
TAG_PATTERNS = {
    "SELECT": r"\bSELECT\b", "WHERE": r"\bWHERE\b", "ORDER BY": r"\bORDER\s+BY\b",
    "DISTINCT": r"\bDISTINCT\b", "BETWEEN": r"\bBETWEEN\b", "IN": r"\bIN\s*\(",
    "LIKE": r"\bI?LIKE\b", "IS NULL": r"\bIS\s+NULL\b",
    "COUNT": r"\bcount\s*\(", "SUM": r"\bsum\s*\(", "AVG": r"\bavg\s*\(",
    "MIN": r"\bmin\s*\(", "MAX": r"\bmax\s*\(", "GROUP BY": r"\bGROUP\s+BY\b",
    "HAVING": r"\bHAVING\b", "WHERE vs HAVING": r"(?s)\bWHERE\b.*\bHAVING\b",
    "INNER JOIN": r"\bINNER\s+JOIN\b", "LEFT JOIN": r"\bLEFT\s+(OUTER\s+)?JOIN\b",
    "RIGHT JOIN": r"\bRIGHT\s+(OUTER\s+)?JOIN\b", "FULL OUTER JOIN": r"\bFULL\s+OUTER\s+JOIN\b",
    "CROSS JOIN": r"\bCROSS\s+JOIN\b",
    "SELF JOIN": r"(?s)\bFROM\s+(\w+)\s+\w+\b.*\bJOIN\s+\1\s+\w+",
    "scalar": r"\(\s*SELECT\b", "single-row": r"\(\s*SELECT\b", "multi-row IN": r"\bIN\s*\(\s*SELECT\b",
    "ANY": r"\bANY\s*\(", "ALL": r"\bALL\s*\(\s*SELECT\b", "correlated": r"\(\s*SELECT\b",
    "EXISTS": r"\bEXISTS\s*\(", "NOT EXISTS": r"\bNOT\s+EXISTS\s*\(", "NOT IN": r"\bNOT\s+IN\s*\(",
    "NULL pitfall": r"\bNOT\s+IN\s*\(",
    "UNION": r"\bUNION\b(?!\s+ALL)", "UNION ALL": r"\bUNION\s+ALL\b",
    "INTERSECT": r"\bINTERSECT\b", "EXCEPT": r"\bEXCEPT\b",
    "CASE": r"\bCASE\b", "COALESCE": r"\bcoalesce\s*\(", "NULLIF": r"\bnullif\s*\(",
    "date/time": r"\b(extract|date_trunc|make_interval|to_char|age|date_part|justify_interval)\s*\(|\binterval\b",
    "string": r"\b(upper|lower|length|initcap|split_part|concat_ws|format|left|right|replace|repeat|position|substring|lpad|rpad)\s*\(",
    "numeric": r"\b(round|abs|ceil|floor|trunc|sign|power|mod|greatest|least)\s*\(",
    "ROW_NUMBER": r"\brow_number\s*\(\s*\)\s*OVER\b", "RANK": r"\brank\s*\(\s*\)\s*OVER\b",
    "DENSE_RANK": r"\bdense_rank\s*\(\s*\)\s*OVER\b", "LAG": r"\blag\s*\(", "LEAD": r"\blead\s*\(",
    "running total": r"\bsum\s*\([^)]*\)\s*OVER\s*\([^)]*ROWS\b",
    "moving average": r"\bavg\s*\([^)]*\)\s*OVER\s*\([^)]*ROWS\b",
}
TABLES = ["users", "instruments", "watchlists", "watchlist_items", "price_ticks",
          "alert_rules", "alert_events"]
BLOCK_RE = re.compile(r"^\\echo '=== ([A-Z]+\d+[a-z]?) \| (.*?) \| (.*)'\s*$")
META_RE = re.compile(r"^-- @(\w+):\s?(.*)$")


def parse_blocks(path: Path):
    blocks, cur = [], None
    for n, line in enumerate(path.read_text().splitlines(), 1):
        if m := BLOCK_RE.match(line):
            cur = {"id": m.group(1), "covers": [t.strip() for t in m.group(2).split(",")],
                   "question": m.group(3), "meta": {}, "sql": [], "start": n, "end": n}
            blocks.append(cur)
            continue
        if cur is None or cur.get("done"):
            continue
        if not cur["sql"] and (m := META_RE.match(line)):
            cur["meta"].setdefault(m.group(1), []).append(m.group(2))
            continue
        if not cur["sql"] and (not line.strip() or line.lstrip().startswith("--")):
            continue
        cur["sql"].append(line)
        cur["end"] = n
        if line.rstrip().endswith(";") and not line.lstrip().startswith("--"):
            cur["done"] = True
    for b in blocks:
        b["sql"] = "\n".join(b["sql"]).strip()
    return blocks


def run_query(db, sql):
    script = "\\pset null '(null)'\n\\pset footer on\n" + sql + "\n"
    p = subprocess.run(PSQL + ["-d", db, "-f", "-"], input=script, text=True, capture_output=True)
    out = (p.stdout + p.stderr).rstrip()
    rows = re.findall(r"^\((\d+) rows?\)$", out, re.M)
    return p.returncode, out, int(rows[-1]) if rows else None


def strip_comments(sql):
    return "\n".join(l for l in sql.splitlines() if not l.lstrip().startswith("--"))


def cmd_queries(db, out_path):
    version = subprocess.run(PSQL + ["-At", "-d", db, "-c", "SHOW server_version"],
                             text=True, capture_output=True).stdout.strip()
    sections, summary, all_ok, checkpoint = [], [], True, 0
    seen_ids = set()
    for fname, key, title, minimum, required in CATEGORIES:
        blocks = parse_blocks(SQL_DIR / fname)
        covered, cat_ok = set(), True
        sections.append(f"\n## {title}\n\nSource: `sql/review2/{fname}`\n")
        for b in blocks:
            if b["id"] in seen_ids:
                raise SystemExit(f"duplicate query id {b['id']}")
            seen_ids.add(b["id"])
            code, out, rows = run_query(db, b["sql"])
            sql_nc = strip_comments(b["sql"])
            tag_problems = [t for t in b["covers"]
                            if t in TAG_PATTERNS and not re.search(TAG_PATTERNS[t], sql_nc, re.I)]
            covered.update(t for t in b["covers"] if t not in tag_problems)
            want_rows = int(b["meta"]["rows"][0]) if "rows" in b["meta"] else None
            if key == "CQ":
                n_tables = sum(bool(re.search(rf"\b{t}\b", sql_nc)) for t in TABLES)
                nested = bool(re.search(r"\(\s*SELECT\b|\bOVER\s*\(|\bLATERAL\b|\bWITH\b", sql_nc, re.I))
                cq_ok = n_tables >= 3 or nested
            else:
                n_tables, nested, cq_ok = None, None, True
            ok = (code == 0 and rows is not None and not tag_problems and cq_ok and
                  (rows == want_rows if want_rows is not None else rows >= 1))
            cat_ok &= ok
            status = "PASS" if ok else "FAIL"
            note = f"{rows} row(s)" if rows is not None else "no result table"
            if want_rows is not None:
                note += f" (expected exactly {want_rows}: an empty result is the point of this example)"
            sections.append(f"\n### {b['id']} — {b['question']}\n")
            sections.append(f"- Requirement covered: {', '.join(b['covers'])}")
            if key == "CQ":
                sections.append(f"- Tables used: {n_tables} of the 7; nested/analytic construct: "
                                f"{'yes' if nested else 'no'} (template: ≥ 3 tables OR nested/analytic)")
            sections.append(f"- Execution: **{status}** — psql exit {code}, {note}")
            if tag_problems:
                sections.append(f"- Declared but not found in the SQL: {', '.join(tag_problems)}")
            sections.append("- Screenshot: status per query in docs/review2/SCREENSHOT_MATRIX.md")
            for label, k in (("Expected result (predicted before execution)", "expected"),
                             ("Explanation", "explain")):
                if k in b["meta"]:
                    sections.append(f"- {label}: " + " ".join(b["meta"][k]))
            sections.append(f"\n```sql\n{b['sql']}\n```\n\nActual output:\n\n```text\n{out}\n```")
        missing = [t for t in required if t not in covered]
        all_ok &= cat_ok and not missing and len(blocks) >= minimum
        if key in ("A", "B", "C", "D", "E"):
            checkpoint += len(blocks)
        summary.append((title, minimum, len(blocks), cat_ok, required, missing))

    lines = [
        "# Review 2 — SQL query evidence (actual execution output)",
        "",
        f"Generated by `scripts/review2_evidence.py queries` on "
        f"{dt.datetime.now().astimezone():%Y-%m-%d %H:%M %Z} from database `{db}` "
        f"(PostgreSQL {version}). Every query below was executed on its own, and the output "
        "block is exactly what psql printed. Timestamps in outputs depend on when the sandbox "
        "was built (the replay starts at the build time); everything else is deterministic.",
        "",
        "Do not edit this file by hand; re-run `bash scripts/review2_sandbox.sh`.",
        "",
        "## Summary",
        "",
        "| Category | Template minimum | Distinct queries | All executed with ≥ 1 row (or the documented row count) | Required coverage missing |",
        "|---|---:|---:|---|---|",
    ]
    for title, minimum, n, ok, required, missing in summary:
        lines.append(f"| {title} | {minimum} | {n} | {'PASS' if ok else 'FAIL'} | "
                     f"{', '.join(missing) if missing else ('none' if required else 'n/a')} |")
    lines += ["",
              f"Review 2 checkpoint item 3 (basic + aggregate + join + subquery + set-operation "
              f"queries, at least 20): **{checkpoint}** distinct queries.",
              "",
              f"Overall: **{'PASS' if all_ok else 'FAIL'}**. This file is execution evidence, "
              "not a screenshot; screenshot status is in SCREENSHOT_MATRIX.md."]
    out_path.write_text("\n".join(lines + sections) + "\n")
    print(f"   wrote {out_path.relative_to(ROOT)}: "
          + ", ".join(f"{t.split()[0]} {n}" for t, _, n, *_ in summary)
          + f"; checkpoint queries {checkpoint}; overall {'PASS' if all_ok else 'FAIL'}")
    return 0 if all_ok else 1


# --------------------------------------------------------------------------
# matrix: one row per query - can it be shown with its SQL and real output,
# and has a screenshot actually been captured?
# --------------------------------------------------------------------------
TERM_COLS, TERM_ROWS = 160, 50          # a readable terminal on one screenshot
TIME_RE = re.compile(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}|\b\d{2}:\d{2}:\d{2}\b")


def cmd_matrix(db, out_path):
    ocr, checks = load_ocr(), load_visual_checks()
    rows, n = [], 0
    for fname, key, title, *_ in CATEGORIES:
        log = ROOT / "docs" / "review2" / "sql_output" / (Path(fname).stem + ".out")
        log_lines = log.read_text(errors="replace").splitlines() if log.exists() else []
        for b in parse_blocks(SQL_DIR / fname):
            n += 1
            code, out, nrows = run_query(db, b["sql"])
            sql_lines, out_lines = b["sql"].splitlines(), out.splitlines()
            width = max(len(line) for line in sql_lines + out_lines)
            height = len(sql_lines) + len(out_lines) + 1
            # in the per-script log: the label, then the echoed SQL, then a row-count footer
            label = f"=== {b['id']} |"
            at = next((i for i, line in enumerate(log_lines) if line.startswith(label)), None)
            in_log = False
            if at is not None:
                window = log_lines[at + 1: at + 1 + len(sql_lines) + len(out_lines) + 5]
                in_log = (any(sql_lines[0].strip() in w for w in window)
                          and any(re.match(r"^\(\d+ rows?\)$", w) for w in window))
            shown = code == 0 and nrows is not None and nrows >= 1 and in_log
            fit = []
            if width > TERM_COLS:
                fit.append(f"WIDE {width} cols")
            if height > TERM_ROWS:
                fit.append(f"TALL {height} lines")
            shots = shot_files(b["id"])
            rows.append({
                "n": n, "id": b["id"], "cat": title.split(" (")[0], "covers": ", ".join(b["covers"]),
                "src": f"sql/review2/{fname}:{b['start']}-{b['end']}",
                "log": f"sql_output/{log.name}:{at + 1}" if at is not None else "MISSING",
                "rows": nrows, "size": f"{height} × {width}",
                "fit": "; ".join(fit) or "fits one shot",
                "time": "yes" if TIME_RE.search(out) else "no",
                "shown": "PASS" if shown else "FAIL",
                "shot": shot_status(b["id"], shots, ocr, checks),
            })
    captured = sum(not r["shot"].startswith("PENDING") for r in rows)
    verified = sum(r["shot"].startswith("VERIFIED") for r in rows)
    lines = [
        "# Screenshot coverage matrix — all queries",
        "",
        f"Generated by `scripts/review2_evidence.py matrix --db {db}` on "
        f"{dt.datetime.now().astimezone():%Y-%m-%d %H:%M %Z}. Each query was executed again for this table.",
        "",
        "- **Shown with SQL + output** = the query ran without error, returned at least one row, and its "
        "per-script log (`docs/review2/sql_output/`) contains the label, the echoed SQL and the row-count "
        "footer, so one screenshot can show question, SQL and result together.",
        f"- **Size** = lines × columns of SQL + output. One readable screenshot is taken as at most "
        f"{TERM_ROWS} lines × {TERM_COLS} columns; anything larger is flagged.",
        "- **Time-dependent** = the output contains clock times, which come from the replay start, so a "
        "new screenshot shows different times than the log (all other values are identical).",
        "- **Screenshot**: PENDING until an image named after the query ID exists in "
        "`docs/review2/screenshots/` (for example `CQ03.png`, taken by "
        "`scripts/review2_capture_screenshots.sh`). CAPTURED means the file exists; the OCR check "
        "(`verify-shots`) then reads it for the label, the first SQL line, the column headings and the "
        "first result row. **VERIFIED** needs a passing OCR check AND a recorded visual check of that "
        "exact file (`VISUAL_CHECK.csv`, matched by SHA-256).",
        "",
        "## Summary",
        "",
        "| Item | Count |",
        "|---|---:|",
        f"| queries | {len(rows)} |",
        f"| shown with SQL + at least one output | {sum(r['shown'] == 'PASS' for r in rows)} |",
        f"| fit one screenshot as they are | {sum(r['fit'] == 'fits one shot' for r in rows)} |",
        f"| wider than {TERM_COLS} columns (smaller font, or split columns) | {sum('WIDE' in r['fit'] for r in rows)} |",
        f"| taller than {TERM_ROWS} lines (two shots, or scroll) | {sum('TALL' in r['fit'] for r in rows)} |",
        f"| output contains build-time clock values | {sum(r['time'] == 'yes' for r in rows)} |",
        f"| screenshots VERIFIED (OCR pass + visual check) | {verified} |",
        f"| screenshots captured, not yet verified | {captured - verified} |",
        f"| screenshots PENDING (no image yet) | {len(rows) - captured} |",
        "",
        "## Matrix",
        "",
        "| # | ID | Category | Covers | SQL source | Log line | Rows | Size | Fit | Time-dependent | Shown with SQL + output | Screenshot |",
        "|---:|---|---|---|---|---|---:|---|---|---|---|---|",
    ]
    for r in rows:
        lines.append(f"| {r['n']} | {r['id']} | {r['cat']} | {r['covers']} | `{r['src']}` | `{r['log']}` | "
                     f"{r['rows']} | {r['size']} | {r['fit']} | {r['time']} | {r['shown']} | {r['shot']} |")
    out_path.write_text("\n".join(lines) + "\n")
    ok = all(r["shown"] == "PASS" for r in rows)
    shown_path = out_path.relative_to(ROOT) if out_path.is_relative_to(ROOT) else out_path
    print(f"   wrote {shown_path}: {len(rows)} queries, shown-with-output "
          f"{sum(r['shown'] == 'PASS' for r in rows)}/{len(rows)}, verified {verified}, "
          f"captured but not verified {captured - verified}, pending {len(rows) - captured}")
    return 0 if ok else 1


# --------------------------------------------------------------------------
# screenshots: capture support, OCR check, visual-check record
# --------------------------------------------------------------------------
SHOTS_DIR = ROOT / "docs" / "review2" / "screenshots"
OCR_JSON = SHOTS_DIR / "ocr_check.json"
VISUAL_CSV = SHOTS_DIR / "VISUAL_CHECK.csv"
VISUAL_FIELDS = ["id", "sha256", "checked_by", "date", "result", "note"]


def all_blocks():
    for fname, *_ in CATEGORIES:
        for b in parse_blocks(SQL_DIR / fname):
            b["file"] = fname
            yield b


def find_block(qid):
    for b in all_blocks():
        if b["id"] == qid:
            return b
    raise SystemExit(f"unknown query id {qid}")


def shot_files(qid):
    if not SHOTS_DIR.exists():
        return []
    return sorted(p for p in SHOTS_DIR.iterdir()
                  if p.suffix.lower() in (".png", ".jpg", ".jpeg")
                  and (p.stem == qid or p.stem.startswith(qid + "_")))


def files_sha(files):
    h = hashlib.sha256()
    for f in files:
        h.update(f.read_bytes())
    return h.hexdigest()


def load_ocr():
    return json.loads(OCR_JSON.read_text()) if OCR_JSON.exists() else {}


def load_visual_checks():
    if not VISUAL_CSV.exists():
        return {}
    latest = {}
    with VISUAL_CSV.open(newline="") as f:
        for row in csv.DictReader(f):
            latest[(row["id"], row["sha256"])] = row
    return latest


def shot_status(qid, files, ocr, checks):
    if not files:
        return "PENDING (no screenshot yet)"
    names = ", ".join(p.name for p in files)
    sha = files_sha(files)
    result = ocr.get(qid)
    if not result or result.get("sha256") != sha:
        return f"CAPTURED: {names}; OCR check not run on this file"
    if not result["pass"]:
        return f"CAPTURED: {names}; OCR FAIL ({result['detail']})"
    check = checks.get((qid, sha))
    if check is None:
        return f"CAPTURED: {names}; OCR pass; visual check PENDING"
    if check["result"] != "OK":
        return f"REDO: {names}; visual check by {check['checked_by']}: {check['note']}"
    return f"VERIFIED: {names}; OCR pass; visual check by {check['checked_by']} on {check['date']}"


def ocr_binary():
    """Compile scripts/review2_ocr.swift once into a cache folder."""
    src = ROOT / "scripts" / "review2_ocr.swift"
    out_dir = Path(os.environ.get("TMPDIR", tempfile.gettempdir())) / "review2_bin"
    exe = out_dir / "review2_ocr"
    if not exe.exists() or exe.stat().st_mtime < src.stat().st_mtime:
        out_dir.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-O", str(src), "-o", str(exe)], check=True)
    return exe


def ocr_images(paths):
    """{path: [text lines]} from macOS Vision text recognition."""
    p = subprocess.run([str(ocr_binary())] + [str(x) for x in paths], text=True, capture_output=True)
    result, cur = {}, None
    for line in p.stdout.splitlines():
        if line.startswith("== "):
            cur = result.setdefault(line[3:].rsplit(" ", 1)[0], [])
        elif cur is not None:
            cur.append(line.split("\t", 2)[-1])
    return result


def norm(text):
    return re.sub(r"[^a-z0-9]", "", text.lower())


def expected_marks(b, out):
    """What a screenshot of this query must show: label, first SQL line, headings, first row."""
    sql_lines = [l for l in strip_comments(b["sql"]).splitlines() if len(norm(l)) >= 6]
    out_lines = out.splitlines()
    dash = next((i for i, l in enumerate(out_lines) if re.match(r"^-+(\+-+)*$", l.strip())), None)
    headings = [c.strip() for c in out_lines[dash - 1].split("|")] if dash else []
    first_row = ([c.strip() for c in out_lines[dash + 1].split("|")]
                 if dash is not None and dash + 1 < len(out_lines) else [])
    cells = [c for c in first_row if c and not TIME_RE.search(c)][:3]
    return {"label": b["id"], "sql": norm(sql_lines[0])[:24] if sql_lines else "",
            "headings": [norm(h) for h in headings if norm(h)], "cells": [norm(c) for c in cells]}


def cmd_verify_shots(db, matrix_out):
    blocks = [b for b in all_blocks() if shot_files(b["id"])]
    files = [f for b in blocks for f in shot_files(b["id"])]
    ocr_text = ocr_images(files) if files else {}
    results = load_ocr()
    for b in blocks:
        shots = shot_files(b["id"])
        text = " ".join(t for f in shots for t in ocr_text.get(str(f), []))
        flat = norm(text)
        code, out, _ = run_query(db, b["sql"])
        want = expected_marks(b, out)
        found = {
            "label": re.search(rf"\b{re.escape(want['label'])}\b", text) is not None,
            "sql": bool(want["sql"]) and want["sql"] in flat,
            "headings": bool(want["headings"]) and
                        sum(h in flat for h in want["headings"]) >= max(1, (len(want["headings"]) + 1) // 2),
            "first row": bool(want["cells"]) and any(c in flat for c in want["cells"]),
        }
        missing = [k for k, v in found.items() if not v]
        results[b["id"]] = {"files": [f.name for f in shots], "sha256": files_sha(shots),
                            "pass": not missing, "found": found,
                            "detail": "label, SQL, headings and first row read" if not missing
                                      else "not read: " + ", ".join(missing),
                            "checked": f"{dt.datetime.now().astimezone():%Y-%m-%d %H:%M %Z}"}
        print(f"   {b['id']:<6} {'PASS' if not missing else 'FAIL'}  {results[b['id']]['detail']}")
    for qid in [k for k in results if not shot_files(k)]:
        del results[qid]            # image removed since the last check
    SHOTS_DIR.mkdir(parents=True, exist_ok=True)
    OCR_JSON.write_text(json.dumps(results, indent=1, sort_keys=True) + "\n")
    print(f"   OCR checked {len(blocks)} screenshot(s); pass {sum(r['pass'] for r in results.values())}")
    return cmd_matrix(db, matrix_out)


def cmd_visual_ok(ids, by, result, note):
    rows = []
    for qid in ids:
        find_block(qid)
        files = shot_files(qid)
        if not files:
            raise SystemExit(f"{qid}: no screenshot in {SHOTS_DIR.relative_to(ROOT)}")
        rows.append({"id": qid, "sha256": files_sha(files), "checked_by": by,
                     "date": f"{dt.date.today():%Y-%m-%d}", "result": result, "note": note})
    new = not VISUAL_CSV.exists()
    SHOTS_DIR.mkdir(parents=True, exist_ok=True)
    with VISUAL_CSV.open("a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=VISUAL_FIELDS)
        if new:
            w.writeheader()
        w.writerows(rows)
    print(f"   recorded {len(rows)} visual check(s) as {result} by {by}")
    return 0


def cmd_block(qid, out):
    b = find_block(qid)
    Path(out).write_text("\\pset null '(null)'\n\\pset footer on\n"
                         f"\\echo '=== {b['id']} | {', '.join(b['covers'])} | {b['question']}'\n"
                         f"{b['sql']}\n")
    print(f"sql/review2/{b['file']}:{b['start']}-{b['end']}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("files", nargs="+")
    for name in ("queries", "matrix"):
        q = sub.add_parser(name)
        q.add_argument("--db", required=True)
        q.add_argument("--out", required=True)
    sub.add_parser("ids")
    k = sub.add_parser("block")
    k.add_argument("id")
    k.add_argument("--out", required=True)
    v = sub.add_parser("verify-shots")
    v.add_argument("--db", default="stock_watchlist_review2_sandbox")
    v.add_argument("--out", default="docs/review2/SCREENSHOT_MATRIX.md")
    o = sub.add_parser("visual-ok")
    o.add_argument("ids", nargs="+")
    o.add_argument("--by", required=True)
    o.add_argument("--result", default="OK", choices=["OK", "REDO"])
    o.add_argument("--note", default="")
    args = ap.parse_args()
    if args.cmd == "check":
        return cmd_check(args.files)
    if args.cmd == "ids":
        print("\n".join(b["id"] for b in all_blocks()))
        return 0
    if args.cmd == "block":
        return cmd_block(args.id, args.out)
    if args.cmd == "visual-ok":
        return cmd_visual_ok(args.ids, args.by, args.result, args.note)
    if args.db in ("stock_watchlist", "postgres"):
        raise SystemExit("refusing: queries run only on the Review 2 sandbox")
    if args.cmd == "matrix":
        return cmd_matrix(args.db, ROOT / args.out)
    if args.cmd == "verify-shots":
        return cmd_verify_shots(args.db, ROOT / args.out)
    return cmd_queries(args.db, ROOT / args.out)


if __name__ == "__main__":
    sys.exit(main())
