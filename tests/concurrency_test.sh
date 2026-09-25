#!/usr/bin/env bash
# =====================================================================
# concurrency_test.sh
# Real multi-session tests for ingest_tick locking and NOTIFY delivery.
# Each "session" is a separate psql process (separate connection and
# transaction) running at the same time as the others.
#
# Uses a THROWAWAY database (stock_watchlist_ctest), built from
# sql/00, 01, 03 and dropped at the end. The dev database is not touched.
#
# Run:  bash tests/concurrency_test.sh
# Exit code 0 = all checks passed.
# =====================================================================
set -u

PG_BIN="${PG_BIN:-/opt/homebrew/opt/postgresql@18/bin}"
DB="stock_watchlist_ctest"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
T0="2026-01-05 09:15:00+05:30"
FAILS=0

q()  { "$PG_BIN/psql" -X -q -At -d "$DB" -v ON_ERROR_STOP=1 "$@"; }
val() { grep "^$1|" "$2" | head -1 | cut -d'|' -f2-; }   # value after "KEY|"
check() {   # check "<name>" "<expected>" "<actual>"
    if [ "$2" = "$3" ]; then printf '  PASS  %-70s %s\n' "$1" "$3"
    else printf '  FAIL  %-70s expected=%s actual=%s\n' "$1" "$2" "$3"; FAILS=$((FAILS+1)); fi
}
cleanup() { "$PG_BIN/dropdb" --if-exists "$DB" >/dev/null 2>&1; rm -rf "$OUT"; }
trap cleanup EXIT

echo "== setup: fresh database $DB"
"$PG_BIN/dropdb" --if-exists "$DB" >/dev/null 2>&1
"$PG_BIN/createdb" "$DB" || exit 1
for f in 00_schema.sql 01_seed.sql 03_functions_triggers.sql; do
    q -f "$ROOT/sql/$f" >/dev/null 2>&1 || { echo "setup failed on $f"; exit 1; }
done
q -c "SHOW default_transaction_isolation" | sed 's/^/   isolation: /'

# =====================================================================
# Scenario 1: same instrument, A holds the lock, B must wait.
# RELIANCE, seed rule 1 = ABOVE 3000.  Committed baseline tick 2990.
# A ingests 3005 (crossing) and keeps its transaction open for 3 s.
# B ingests 3010 one second later.
#   With the lock:    B waits, then sees A's 3005 as previous -> no event.
#   Without the lock: B would see 2990 as previous -> a second event.
# =====================================================================
echo
echo "== Scenario 1: A holds the RELIANCE lock, B waits"
q -c "SELECT * FROM ingest_tick('NSE','RELIANCE','$T0',2990,1,'MANUAL','c1:base')" >/dev/null

PGAPPNAME=conc_A q > "$OUT/s1_A.txt" 2>&1 <<SQL &
BEGIN;
SELECT 'A_result|' || status || '|' || tick_id
FROM ingest_tick('NSE','RELIANCE',timestamptz '$T0' + interval '1 s',3005,1,'MANUAL','c1:A');
SELECT pg_sleep(3);
SELECT 'A_commit|' || extract(epoch FROM clock_timestamp());
COMMIT;
SQL

PGAPPNAME=conc_B q > "$OUT/s1_B.txt" 2>&1 <<SQL &
SELECT pg_sleep(1);
BEGIN;
SELECT 'B_call|' || extract(epoch FROM clock_timestamp());
SELECT 'B_result|' || status || '|' || tick_id
FROM ingest_tick('NSE','RELIANCE',timestamptz '$T0' + interval '2 s',3010,1,'MANUAL','c1:B');
SELECT 'B_return|' || extract(epoch FROM clock_timestamp());
COMMIT;
SQL

# Observer (third session): who is B waiting for?
q > "$OUT/s1_OBS.txt" 2>&1 <<SQL &
SELECT pg_sleep(2);
SELECT 'OBS_waiting|' || count(*) || '|' || coalesce(string_agg(blk.application_name, ','), '-')
       || '|' || coalesce(string_agg(DISTINCT w.wait_event_type, ','), '-')
FROM pg_stat_activity w
CROSS JOIN LATERAL unnest(pg_blocking_pids(w.pid)) AS b(pid)
JOIN pg_stat_activity blk ON blk.pid = b.pid
WHERE w.application_name = 'conc_B' AND w.wait_event_type = 'Lock';
SELECT 'OBS_event|' || coalesce(string_agg(wait_event_type || ':' || wait_event, ','), '-')
FROM pg_stat_activity WHERE application_name = 'conc_B';
SQL
wait

A_commit=$(val A_commit "$OUT/s1_A.txt"); B_call=$(val B_call "$OUT/s1_B.txt"); B_return=$(val B_return "$OUT/s1_B.txt")
waited=$(awk -v a="$B_call" -v b="$B_return" 'BEGIN{printf "%.2f", b-a}')
echo "   A: $(val A_result "$OUT/s1_A.txt")    B: $(val B_result "$OUT/s1_B.txt")    B blocked for ${waited}s"
echo "   observer while B blocked: B waits on $(val OBS_event "$OUT/s1_OBS.txt") (a row-lock waiter waits for the holder's transaction)"

check "1a observer: B waiting on a Lock, blocked by session A (count|blocker|type)" "1|conc_A|Lock" "$(val OBS_waiting "$OUT/s1_OBS.txt")"
check "1b B blocked >= 1.5 s" "yes" "$(awk -v w="$waited" 'BEGIN{print (w>=1.5)?"yes":"no"}')"
check "1c B returned only after A committed" "yes" "$(awk -v a="$A_commit" -v b="$B_return" 'BEGIN{print (b>=a)?"yes":"no"}')"
check "1d both ticks INSERTED" "INSERTED INSERTED" \
      "$(val A_result "$OUT/s1_A.txt" | cut -d'|' -f1) $(val B_result "$OUT/s1_B.txt" | cut -d'|' -f1)"
check "1e tick order (observed_at, tick_id): base < A < B" "c1:base,c1:A,c1:B" \
      "$(q -c "SELECT string_agg(source_event_id, ',' ORDER BY observed_at, tick_id) FROM price_ticks WHERE source_event_id LIKE 'c1:%'")"
check "1f tick_id of A < tick_id of B" "t" \
      "$(q -c "SELECT (SELECT tick_id FROM price_ticks WHERE source_event_id='c1:A') < (SELECT tick_id FROM price_ticks WHERE source_event_id='c1:B')")"
check "1g previous tick of B is A (3005)" "c1:A" \
      "$(q -c "SELECT p.source_event_id FROM price_ticks b JOIN price_ticks p ON p.instrument_id = b.instrument_id AND (p.observed_at, p.tick_id) < (b.observed_at, b.tick_id) WHERE b.source_event_id='c1:B' ORDER BY p.observed_at DESC, p.tick_id DESC LIMIT 1")"
check "1h exactly ONE alert for rule 1, on tick A (no duplicate from B)" "1|c1:A" \
      "$(q -c "SELECT count(*) || '|' || string_agg(t.source_event_id, ',') FROM alert_events e JOIN price_ticks t USING (tick_id) WHERE e.rule_id = 1")"

# =====================================================================
# Scenario 2 (CONTROL): the same race WITHOUT ingest_tick's lock, using
# direct INSERTs. TCS, seed rule 4 = BELOW 3500, cooldown 0.
# Expected: B does not wait and a DUPLICATE alert appears. This proves
# the test really detects the race, and that the lock is what fixes it.
# =====================================================================
echo
echo "== Scenario 2 (control): same race with direct INSERT, no lock"
q -c "SELECT * FROM ingest_tick('NSE','TCS','$T0',3600,1,'MANUAL','c2:base')" >/dev/null

q > "$OUT/s2_A.txt" 2>&1 <<SQL &
BEGIN;
INSERT INTO price_ticks (instrument_id, observed_at, price, source, source_event_id)
SELECT instrument_id, timestamptz '$T0' + interval '1 s', 3490, 'MANUAL', 'c2:A'
FROM instruments WHERE exchange='NSE' AND symbol='TCS';
SELECT pg_sleep(3);
COMMIT;
SQL

q > "$OUT/s2_B.txt" 2>&1 <<SQL &
SELECT pg_sleep(1);
BEGIN;
SELECT 'B_call|' || extract(epoch FROM clock_timestamp());
INSERT INTO price_ticks (instrument_id, observed_at, price, source, source_event_id)
SELECT instrument_id, timestamptz '$T0' + interval '2 s', 3480, 'MANUAL', 'c2:B'
FROM instruments WHERE exchange='NSE' AND symbol='TCS';
SELECT 'B_return|' || extract(epoch FROM clock_timestamp());
COMMIT;
SQL
wait

waited2=$(awk -v a="$(val B_call "$OUT/s2_B.txt")" -v b="$(val B_return "$OUT/s2_B.txt")" 'BEGIN{printf "%.2f", b-a}')
echo "   B blocked for ${waited2}s"
check "2a without the lock B does NOT wait (< 0.5 s)" "yes" "$(awk -v w="$waited2" 'BEGIN{print (w<0.5)?"yes":"no"}')"
check "2b without the lock ONE crossing produced TWO alerts (the bug)" "2|c2:A,c2:B" \
      "$(q -c "SELECT count(*) || '|' || string_agg(t.source_event_id, ',' ORDER BY t.tick_id) FROM alert_events e JOIN price_ticks t USING (tick_id) WHERE e.rule_id = 4")"

# =====================================================================
# Scenario 3: B waits, then turns out to be LATE.
# ETHUSDT, seed rule 6 = BELOW 3000.  Baseline 3100 at T0.
# A ingests 2990 at T0+10 s (crossing), holds the lock 3 s.
# B ingests 2980 at T0+5 s (older market time) while A is open.
#   With the lock: B waits, then sees A's later tick -> B is late -> no event.
#   Without it:    B would compare with 3100 -> second event.
# =====================================================================
echo
echo "== Scenario 3: B waits and is then classified as late"
q -c "SELECT * FROM ingest_tick('BINANCE','ETHUSDT','$T0',3100,1,'MANUAL','c3:base')" >/dev/null

q > "$OUT/s3_A.txt" 2>&1 <<SQL &
BEGIN;
SELECT * FROM ingest_tick('BINANCE','ETHUSDT',timestamptz '$T0' + interval '10 s',2990,1,'MANUAL','c3:A');
SELECT pg_sleep(3);
COMMIT;
SQL

q > "$OUT/s3_B.txt" 2>&1 <<SQL &
SELECT pg_sleep(1);
BEGIN;
SELECT 'B_call|' || extract(epoch FROM clock_timestamp());
SELECT 'B_result|' || status FROM ingest_tick('BINANCE','ETHUSDT',timestamptz '$T0' + interval '5 s',2980,1,'MANUAL','c3:B');
SELECT 'B_return|' || extract(epoch FROM clock_timestamp());
COMMIT;
SQL
wait

waited3=$(awk -v a="$(val B_call "$OUT/s3_B.txt")" -v b="$(val B_return "$OUT/s3_B.txt")" 'BEGIN{printf "%.2f", b-a}')
echo "   B blocked for ${waited3}s"
check "3a B blocked >= 1.5 s" "yes" "$(awk -v w="$waited3" 'BEGIN{print (w>=1.5)?"yes":"no"}')"
check "3b late B tick stored" "INSERTED" "$(val B_result "$OUT/s3_B.txt")"
check "3c exactly ONE alert for rule 6, on tick A" "1|c3:A" \
      "$(q -c "SELECT count(*) || '|' || string_agg(t.source_event_id, ',') FROM alert_events e JOIN price_ticks t USING (tick_id) WHERE e.rule_id = 6")"

# =====================================================================
# Scenario 4: NOTIFY is delivered only for committed events.
# A listener session LISTENs while a writer session:
#   (1) commits a BTCUSDT crossing   (seed rule 3 = ABOVE 100000)
#   (2) creates a RELIANCE BELOW-2800 crossing, then ROLLS BACK
#   (3) re-sends the committed BTC event (DUPLICATE)
# Expected: exactly one notification, payload = the committed event_id.
# =====================================================================
echo
echo "== Scenario 4: NOTIFY on commit only"
q -c "SELECT * FROM ingest_tick('BINANCE','BTCUSDT','$T0',99000,1,'MANUAL','c4:base')" >/dev/null

"$PG_BIN/psql" -X -d "$DB" > "$OUT/s4_L.txt" 2>&1 <<SQL &
LISTEN alert_events;
SELECT pg_sleep(4);
SELECT 'listener done';
SQL

q > "$OUT/s4_W.txt" 2>&1 <<SQL &
SELECT pg_sleep(1);
BEGIN;
SELECT * FROM ingest_tick('BINANCE','BTCUSDT',timestamptz '$T0' + interval '1 s',100500,1,'MANUAL','c4:commit');
COMMIT;
BEGIN;
SELECT * FROM ingest_tick('NSE','RELIANCE',timestamptz '$T0' + interval '3 s',2790,1,'MANUAL','c4:rollback');
SELECT 'W_rolled_back_events|' || count(*) FROM alert_events WHERE rule_id = 2;
ROLLBACK;
SELECT 'W_dup|' || status FROM ingest_tick('BINANCE','BTCUSDT',timestamptz '$T0' + interval '1 s',100500,1,'MANUAL','c4:commit');
SQL
wait

committed_id=$(q -c "SELECT e.event_id FROM alert_events e JOIN price_ticks t USING (tick_id) WHERE t.source_event_id = 'c4:commit'")
payloads=$(grep -o 'Asynchronous notification "alert_events" with payload "[0-9]*"' "$OUT/s4_L.txt" | grep -o '"[0-9]*"' | tr -d '"' | paste -sd, -)
echo "   notifications received: ${payloads:-none}    committed event_id: $committed_id"
check "4a rolled-back crossing existed inside its transaction (1 event)" "1" "$(val W_rolled_back_events "$OUT/s4_W.txt")"
check "4b duplicate re-send returned DUPLICATE" "DUPLICATE" "$(val W_dup "$OUT/s4_W.txt")"
check "4c listener got exactly one notification = committed event_id" "$committed_id" "${payloads:-none}"
check "4d nothing from the rolled-back crossing remains (ticks|events)" "0|0" \
      "$(q -c "SELECT (SELECT count(*) FROM price_ticks WHERE source_event_id='c4:rollback') || '|' || (SELECT count(*) FROM alert_events WHERE rule_id = 2)")"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL CONCURRENCY CHECKS PASSED"; else echo "$FAILS CHECK(S) FAILED"; fi
exit "$FAILS"
