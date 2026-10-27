"""Review 3 concurrency demo: two sessions ingest RELIANCE prices at the same time.

    python scripts/review3_concurrency_demo.py <database>

Uses three real PostgreSQL connections (session A, session B, observer).
Connection settings come from PGHOST / PGPORT / PGUSER (+ pgpass).

Scenario 1 - lock wait (prevents a double alert):
  baseline RELIANCE = 2990 (committed). Rule #1 = RELIANCE ABOVE 3000.
  A: BEGIN; ingest_tick(3005)  -> crosses 3000, alert fires, A keeps the
     instrument row locked (FOR NO KEY UPDATE) for 3 seconds.
  B: one second later, ingest_tick(3010) -> must WAIT for A's lock.
  A commits. B continues and now sees 3005 as the previous price, so
  3005 -> 3010 is not a new crossing: no second alert.
  Without the lock B would compare 2990 -> 3010 and fire a duplicate alert.

Scenario 2 - same event sent twice at the same time:
  A and B both send source_event_id 'cc:dup'. One is INSERTED, the other
  gets DUPLICATE (UNIQUE (source, instrument_id, source_event_id)).

The ticks are stamped 2 hours after now() so they are newer than any replay tick.
"""
import sys
import threading
import time

import psycopg

DB = sys.argv[1] if len(sys.argv) > 1 else "stock_watchlist_review3"
T0 = time.monotonic()


def log(who, msg):
    print(f"[{time.monotonic() - T0:5.2f}s] {who:<9}{msg}", flush=True)


def connect(name):
    return psycopg.connect(dbname=DB, application_name=name, autocommit=True)


INGEST = ("SELECT status, tick_id FROM ingest_tick('NSE','RELIANCE', "
          "now() + interval '2 hours' + %s::interval, %s, 1, 'MANUAL', %s)")

setup = connect("cc_setup")
print(f"Database: {DB}   isolation level: "
      f"{setup.execute('SHOW default_transaction_isolation').fetchone()[0]}")
print("Rule #1: arjun  RELIANCE ABOVE 3000\n")
print("=== Scenario 1: A and B send RELIANCE prices at the same time ===")
r = setup.execute(INGEST, ("0 s", 2990, "cc:base")).fetchone()
log("setup", f"baseline tick 2990 committed -> {r[0]} tick {r[1]}")
events_before = setup.execute("SELECT count(*) FROM alert_events WHERE rule_id = 1").fetchone()[0]


def session_a():
    c = connect("cc_A")
    c.execute("BEGIN")
    st, tid = c.execute(INGEST, ("1 s", 3005, "cc:A")).fetchone()
    n = c.execute("SELECT count(*) FROM alert_events WHERE tick_id = %s", (tid,)).fetchone()[0]
    log("A", f"BEGIN; ingest_tick(3005) -> {st} tick {tid}, alerts fired: {n}  (row lock held)")
    time.sleep(3)
    c.execute("COMMIT")
    log("A", "COMMIT  (lock released)")
    c.close()


def session_b():
    time.sleep(1)
    c = connect("cc_B")
    c.execute("BEGIN")
    log("B", "BEGIN; ingest_tick(3010) ... waiting for the RELIANCE lock")
    t = time.monotonic()
    st, tid = c.execute(INGEST, ("2 s", 3010, "cc:B")).fetchone()
    n = c.execute("SELECT count(*) FROM alert_events WHERE tick_id = %s", (tid,)).fetchone()[0]
    log("B", f"returned after waiting {time.monotonic() - t:.2f}s -> {st} tick {tid}, alerts fired: {n}")
    c.execute("COMMIT")
    log("B", "COMMIT")
    c.close()


def observer():
    time.sleep(2)
    c = connect("cc_observer")
    row = c.execute("""
        SELECT w.application_name, w.wait_event_type, blk.application_name
        FROM pg_stat_activity w
        CROSS JOIN LATERAL unnest(pg_blocking_pids(w.pid)) AS b(pid)
        JOIN pg_stat_activity blk ON blk.pid = b.pid
        WHERE w.application_name = 'cc_B'""").fetchone()
    if row:
        log("observer", f"pg_stat_activity: {row[0]} wait_event_type={row[1]}, blocked by {row[2]}")
    else:
        log("observer", "B is not blocked")
    c.close()


threads = [threading.Thread(target=f) for f in (session_a, session_b, observer)]
for t in threads:
    t.start()
for t in threads:
    t.join()

events_after = setup.execute("SELECT count(*) FROM alert_events WHERE rule_id = 1").fetchone()[0]
print(f"\nResult: new alert events for rule #1 = {events_after - events_before} "
      "(exactly one alert for one real crossing; no duplicate alert)")

print("\n=== Scenario 2: the SAME event is sent by two sessions at once ===")
results = {}


def send(name):
    c = connect(name)
    results[name] = c.execute(INGEST, ("3 s", 3020, "cc:dup")).fetchone()
    c.close()


threads = [threading.Thread(target=send, args=(n,)) for n in ("cc_A", "cc_B")]
for t in threads:
    t.start()
for t in threads:
    t.join()
for name in ("cc_A", "cc_B"):
    st, tid = results[name]
    log(name[-1], f"ingest_tick(source_event_id 'cc:dup') -> {st}" + (f" tick {tid}" if tid else ""))
n = setup.execute("SELECT count(*) FROM price_ticks WHERE source_event_id = 'cc:dup'").fetchone()[0]
print(f"\nResult: rows stored for 'cc:dup' = {n} (UNIQUE (source, instrument_id, source_event_id))")
setup.close()
