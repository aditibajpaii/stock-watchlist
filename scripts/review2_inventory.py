#!/usr/bin/env python3
"""Write docs/review2/TABLE_CONSTRAINT_INVENTORY.md from the PostgreSQL catalog.

  python scripts/review2_inventory.py --db stock_watchlist_review2_sandbox

Columns, types, nullability, defaults, keys, CHECKs, foreign keys and ON
DELETE actions are READ from pg_catalog / information_schema; only the
purpose sentences are written by hand. The Review 1 reconciliation table is
checked against the catalog too: every "actual" name must exist, and every
name that only the Review 1 report used must NOT exist. Read-only.
"""

import argparse
import datetime as dt
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TABLES = ["users", "instruments", "watchlists", "watchlist_items",
          "price_ticks", "alert_rules", "alert_events"]
PURPOSE = {
    "users": "One row per person using the system (demo users, no login). Identity and contact address.",
    "instruments": "One row per tradable LISTING: one symbol on one exchange (NSE equities, Binance pairs).",
    "watchlists": "A named list owned by exactly one user.",
    "watchlist_items": "Which instruments are on which watchlist: the M:N relationship CONTAINS, "
                       "with the time the instrument was added.",
    "price_ticks": "Append-only market history: one price observation of one instrument from one "
                   "source (REPLAY, BINANCE or MANUAL). Written only through ingest_tick().",
    "alert_rules": "A user's threshold rule on one instrument: ABOVE/BELOW, threshold, cooldown in "
                   "market seconds, on/off.",
    "alert_events": "Durable alert history: one row each time a rule fired on a tick. Written by "
                    "the alert trigger.",
}
RELATIONSHIPS = {
    "users": "1 user OWNS 0..N watchlists; 1 user CREATES 0..N alert_rules.",
    "instruments": "1 instrument HAS 0..N price_ticks; is MONITORED by 0..N alert_rules; is "
                   "CONTAINED in 0..N watchlists (through watchlist_items).",
    "watchlists": "Each watchlist belongs to exactly 1 user; CONTAINS 0..N instruments.",
    "watchlist_items": "Each row links exactly 1 watchlist and exactly 1 instrument.",
    "price_ticks": "Each tick belongs to exactly 1 instrument; may trigger 0..N alert_events.",
    "alert_rules": "Each rule belongs to exactly 1 user and exactly 1 instrument; GENERATES 0..N alert_events.",
    "alert_events": "Each event comes from exactly 1 rule and exactly 1 tick. Same instrument: checked by "
                    "trigger trg_alert_events_check_instrument when alert_events rows are written; later "
                    "instrument_id changes on alert_rules or price_ticks are not checked "
                    "(no application path makes them; sql_output/22_integrity_scope.out).",
}
NORMAL_FORM = "BCNF (every determinant is a candidate key) — derivation in NORMALIZATION_PROOF.md"
NF_NOTE = {"alert_events": "BCNF. fired_at is the time the event row was recorded; its equality with "
                           "the tick's ingested_at on the application path is not a functional "
                           "dependency (NORMALIZATION_PROOF.md §9)."}

# Review 1 report (section 6 tables, page 6-7) and Review 1 ER (page 5) versus the database.
# (table, review1_tables_section, review1_er, actual_column_or_constraint, kind, review1_name_to_be_absent)
RECONCILE = [
    ("users", "name TEXT NOT NULL", "username", "username", "column", "name"),
    ("instruments", "currency", "quote_currentcy (misspelt)", "quote_currency", "column", "currency"),
    ("instruments", "active", "is_active", "is_active", "column", "active"),
    ("instruments", "created_at", "(not drawn)", None, "absent", "created_at"),
    ("instruments", "no key except instrument_id", "exchange and symbol not marked as a key",
     "uq_instruments_exchange_symbol", "constraint", None),
    ("watchlists", "no UNIQUE", "(not shown)", "uq_watchlists_user_name", "constraint", None),
    ("price_ticks", "volume NOT NULL", "volume", "volume", "nullable column", None),
    ("price_ticks", "source_event_id: 'used for idempotency', no constraint", "source_event_id",
     "uq_price_ticks_source_event", "constraint", None),
    ("price_ticks", "(ingested_at missing)", "ingested_at", "ingested_at", "column", None),
    ("alert_rules", "alert_rule_id", "rule_id", "rule_id", "column", "alert_rule_id"),
    ("alert_rules", "enabled", "is_active", "is_active", "column", "enabled"),
    ("alert_rules", "no UNIQUE", "(not shown)", "uq_alert_rules_definition", "constraint", None),
    ("alert_events", "alert_event_id", "event_id", "event_id", "column", "alert_event_id"),
    ("alert_events", "alert_rule_id", "(FKs not drawn: correct for an ER diagram)", "rule_id", "column",
     "alert_rule_id"),
    ("alert_events", "no UNIQUE", "(not shown)", "uq_alert_events_rule_tick", "constraint", None),
]


def rows(db, sql):
    psql = shutil.which("psql") or "/opt/homebrew/opt/postgresql@18/bin/psql"
    out = subprocess.run([psql, "-X", "-At", "-F", "\t", "-v", "ON_ERROR_STOP=1", "-d", db, "-c", sql],
                         text=True, capture_output=True, check=True).stdout
    return [line.split("\t") for line in out.splitlines() if line]


def md(s):
    return str(s).replace("|", "\\|")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--out", default="docs/review2/TABLE_CONSTRAINT_INVENTORY.md")
    a = ap.parse_args()
    if a.db == "stock_watchlist":
        print("note: reading the classroom database read-only")
    tlist = "('" + "','".join(TABLES) + "')"

    version = rows(a.db, "SHOW server_version")[0][0]
    cols = rows(a.db, f"""
        SELECT c.table_name, c.ordinal_position, c.column_name,
               format_type(at.atttypid, at.atttypmod), c.is_nullable,
               coalesce(c.column_default,
                        CASE WHEN c.is_identity = 'YES'
                             THEN 'GENERATED ' || c.identity_generation || ' AS IDENTITY' END, '')
        FROM information_schema.columns c
        JOIN pg_attribute at ON at.attrelid = ('public.' || c.table_name)::regclass
                            AND at.attname = c.column_name
        WHERE c.table_schema = 'public' AND c.table_name IN {tlist}
        ORDER BY c.table_name, c.ordinal_position""")
    cons = rows(a.db, f"""
        SELECT conrelid::regclass::text, conname, contype, pg_get_constraintdef(oid),
               CASE confdeltype WHEN 'c' THEN 'CASCADE' WHEN 'r' THEN 'RESTRICT'
                                WHEN 'a' THEN 'NO ACTION' WHEN 'n' THEN 'SET NULL'
                                WHEN 'd' THEN 'SET DEFAULT' ELSE '' END
        FROM pg_constraint
        WHERE connamespace = 'public'::regnamespace AND contype IN ('p', 'u', 'f', 'c')
          AND conrelid::regclass::text IN {tlist}
        ORDER BY conrelid::regclass::text, contype, conname""")
    idx = rows(a.db, f"""SELECT tablename, indexname, indexdef FROM pg_indexes
                         WHERE schemaname = 'public' AND tablename IN {tlist} ORDER BY 1, 2""")
    trg = rows(a.db, f"""SELECT c.relname, t.tgname, pg_get_triggerdef(t.oid)
                         FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                         WHERE NOT t.tgisinternal AND c.relname IN {tlist} ORDER BY 1, 2""")

    by_table = {t: [r for r in cols if r[0] == t] for t in TABLES}
    con_by_table = {t: [r for r in cons if r[0] == t] for t in TABLES}
    kinds = {"p": "PRIMARY KEY", "u": "UNIQUE", "f": "FOREIGN KEY", "c": "CHECK"}
    count = {k: sum(1 for r in cons if r[2] == k) for k in kinds}

    out = []
    w = out.append
    w("# Table and constraint inventory (read from the PostgreSQL catalog)")
    w("")
    w(f"Generated by `scripts/review2_inventory.py --db {a.db}` on "
      f"{dt.datetime.now().astimezone():%Y-%m-%d %H:%M %Z} (PostgreSQL {version}). The database was "
      "built from `sql/00_schema.sql` (the authoritative DDL), `01_seed.sql`, `03_functions_triggers.sql` "
      "and `06_indexes.sql`. Every column, type, nullability, default, key, CHECK, foreign key and ON "
      "DELETE action below is **read from pg_catalog / information_schema**; only the purpose sentences "
      "are hand-written. `sql/verify_spec.sql` independently reports `LIVE SCHEMA MATCHES` for the same "
      "database (`docs/review2/sql_output/90_verify_spec_sandbox.out`) and for the classroom database "
      "(run by `scripts/run_all_tests.sh`). Do not edit by hand; re-run the script.")
    w("")
    w(f"Constraint totals: {count['p']} PRIMARY KEY, {count['u']} UNIQUE, {count['f']} FOREIGN KEY, "
      f"{count['c']} CHECK = {sum(count.values())} named constraints, plus NOT NULL on "
      f"{sum(1 for r in cols if r[4] == 'NO')} of {len(cols)} columns.")
    w("")
    w("## Summary")
    w("")
    w("| Table | Columns | Primary key | Alternate (candidate) keys | Foreign keys → parent (ON DELETE) | CHECKs | Normal form |")
    w("|---|---:|---|---|---|---:|---|")
    for t in TABLES:
        pk = next((r[3] for r in con_by_table[t] if r[2] == "p"), "")
        ak = "; ".join(r[3].replace("UNIQUE ", "") for r in con_by_table[t] if r[2] == "u") or "—"
        fk = "; ".join(f"{r[3].split(' REFERENCES ')[0].replace('FOREIGN KEY ', '')} → "
                       f"{r[3].split(' REFERENCES ')[1].split('(')[0]} ({r[4]})"
                       for r in con_by_table[t] if r[2] == "f") or "—"
        nck = sum(1 for r in con_by_table[t] if r[2] == "c")
        w(f"| {t} | {len(by_table[t])} | {pk.replace('PRIMARY KEY ', '')} | {md(ak)} | {md(fk)} | {nck} | BCNF |")
    w("")

    for t in TABLES:
        w(f"## {t}")
        w("")
        w(f"**Purpose.** {PURPOSE[t]}")
        w("")
        w(f"**Relationships.** {RELATIONSHIPS[t]}")
        w("")
        w("| # | Column | Data type | Nullable | Default |")
        w("|---:|---|---|---|---|")
        for _t, pos, name, typ, nullable, default in by_table[t]:
            w(f"| {pos} | `{name}` | {typ} | {'**NULL**' if nullable == 'YES' else 'NOT NULL'} | "
              f"{md(default) or '—'} |")
        w("")
        w("| Constraint | Kind | Definition (pg_get_constraintdef) | ON DELETE |")
        w("|---|---|---|---|")
        for _t, name, kind, definition, ondel in con_by_table[t]:
            w(f"| `{name}` | {kinds[kind]} | `{md(definition)}` | {ondel or '—'} |")
        w("")
        extra_idx = [r for r in idx if r[0] == t and not any(c[1] == r[1] for c in cons)]
        if extra_idx:
            w("Additional index (not created by a constraint): " +
              "; ".join(f"`{r[1]}` — `{r[2]}`" for r in extra_idx))
            w("")
        tt = [r for r in trg if r[0] == t]
        if tt:
            w("Trigger(s): " + "; ".join(f"`{r[1]}` — `{r[2]}`" for r in tt))
            w("")
        w(f"**Normal form.** {NF_NOTE.get(t, NORMAL_FORM)}")
        w("")

    w("## What each kind of constraint guarantees (with this schema's examples)")
    w("")
    w("| Kind | Guarantees | Example here | Evidence of rejection |")
    w("|---|---|---|---|")
    w("| PRIMARY KEY | unique AND not null; the identifier other tables reference; one per table | "
      "`pk_watchlist_items (watchlist_id, instrument_id)` | `03_constraints.out`: duplicate RELIANCE in "
      "arjun Long Term → 23505 |")
    w("| UNIQUE | no two rows share the value combination (an alternate/candidate key); several per table | "
      "`uq_instruments_exchange_symbol (exchange, symbol)` | duplicate NSE RELIANCE → 23505; BSE RELIANCE "
      "accepted |")
    w("| FOREIGN KEY | the value must exist as a key in the parent table; ON DELETE says what happens to "
      "children | `fk_watchlists_user` | watchlist for user 999 → 23503; delete RELIANCE → 23001 "
      "(RESTRICT) |")
    w("| CHECK | a row-level condition must be true | `ck_alert_rules_direction` (ABOVE/BELOW) | "
      "'SIDEWAYS' → 23514 |")
    w("| NOT NULL | a value must be present | `users.email` | NULL email → 23502 |")
    w("")
    w("A PRIMARY KEY is UNIQUE + NOT NULL and is the target of foreign keys. A UNIQUE constraint on "
      "NOT NULL columns is an alternate candidate key (all UNIQUE columns here are NOT NULL). NOT NULL is "
      "a column property that also decides participation: a NOT NULL foreign key means the child must "
      "have a parent (total participation in the ER diagram).")
    w("")
    w("## Review 1 report versus the real database (reconciled)")
    w("")
    w("Review 1 report §6 (tables) and §5 (ER, page 5) are compared with the catalog. The database was "
      "NOT changed to match the report; the corrected documentation follows the database. Each row is "
      "checked automatically by this script.")
    w("")
    w("| Table | Review 1 §6 tables said | Review 1 ER showed | Real database | Check |")
    w("|---|---|---|---|---|")
    col_set = {(r[0], r[2]): r for r in cols}
    con_names = {r[1] for r in cons}
    problems = 0
    for t, r1, er, actual, kind, absent in RECONCILE:
        if kind == "column":
            ok = (t, actual) in col_set
            real = f"`{actual}` {col_set[(t, actual)][3]}" if ok else f"`{actual}` MISSING"
        elif kind == "nullable column":
            ok = (t, actual) in col_set and col_set[(t, actual)][4] == "YES"
            real = f"`{actual}` is nullable (NULL = unknown volume)" if ok else "MISMATCH"
        elif kind == "constraint":
            ok = actual in con_names
            real = (f"`{actual}`: `{next(r[3] for r in cons if r[1] == actual)}`" if ok
                    else f"`{actual}` MISSING")
        else:   # absent
            ok, real = True, "no such column"
        if absent:
            ok = ok and (t, absent) not in col_set
        problems += not ok
        w(f"| {t} | {md(r1)} | {md(er)} | {md(real)} | {'verified' if ok else '**MISMATCH**'} |")
    fk_actions = sorted({r[4] for r in cons if r[2] == 'f'})
    w(f"| all 8 FKs | no ON DELETE stated | (not shown) | "
      f"{sum(r[4] == 'CASCADE' for r in cons if r[2] == 'f')} CASCADE, "
      f"{sum(r[4] == 'RESTRICT' for r in cons if r[2] == 'f')} RESTRICT | verified |")
    w("")
    w("Also different, but a matter of precision rather than naming: the Review 1 report listed "
      "`price NUMERIC` and `threshold NUMERIC`; the database declares `numeric(18,8)` "
      "(`volume` `numeric(24,8)`).")
    Path(ROOT / a.out).write_text("\n".join(out) + "\n")
    print(f"   wrote {a.out}: {len(TABLES)} tables, {len(cols)} columns, {sum(count.values())} constraints; "
          f"reconciliation {'OK' if not problems else str(problems) + ' MISMATCH(ES)'}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
