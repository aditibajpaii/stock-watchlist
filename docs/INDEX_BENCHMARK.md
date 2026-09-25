# Index Benchmark (Phase 6) — study notes, not report text

All numbers come from one run of `tests/benchmark_indexes.py` on 2026-09-25.
The raw evidence is in `docs/benchmark_results/`:

| File | Contents |
|---|---|
| results.json | every timing run, buffers, node types, sizes, result hashes |
| plans_baseline.txt / plans_btree.txt / plans_brin.txt | full `EXPLAIN (ANALYZE, BUFFERS)` text |
| trigger_auto_explain_baseline.txt / _btree.txt | plans of the queries run *inside* the alert trigger (auto_explain) |

Re-run: `python tests/benchmark_indexes.py`. The numbers will differ
slightly on each run.

---

## 1. Environment

| Item | Value |
|---|---|
| Machine | Apple M3, 8 cores, 8 GB RAM, macOS 27 (arm64) |
| DBMS | PostgreSQL 18.6 (Homebrew), default configuration |
| shared_buffers / work_mem | 160 MB / 4 MB |
| random_page_cost / effective_cache_size | 4 / ~5 GB |
| jit / max_parallel_workers_per_gather | on / 2 (no JIT or parallel plan appeared) |
| Client | Python 3.13.15, psycopg 3.3.6 |
| Database | `stock_watchlist_benchmark` (throwaway; dev DB not used) |

## 2. Dataset

| Item | Value |
|---|---|
| Rows in price_ticks | **500,000** |
| Instruments | 20 (7 seed + 13 `NSE BENCH01…13`), 25,000 ticks each |
| Time | one tick every 100 ms overall, rows interleaved across instruments; each instrument ticks every 2 s; span ≈ 13.9 h |
| Price | `1000 + instrument×150 + 50·sin(g/5000)`, rounded to 2 dp (always > 0) |
| Volume | NULL on every 10th row, otherwise 1–500 |
| Identity | source `REPLAY`, source_event_id `bench:0000001…0500000` (unique) |
| Deterministic | yes (generate_series; no randomness) |
| Load time | 7.7 s (INSERT … SELECT) |
| Load method | **benchmark only:** direct INSERT with `trg_price_ticks_evaluate_alerts` DISABLED on the throwaway DB, then re-enabled, then `VACUUM ANALYZE` |

- The production database never has its trigger disabled. Application
  ingestion always goes through `ingest_tick`.
- Physical order equals time order, since rows were inserted in
  observed_at order. That is realistic for a feed and favours BRIN (§7).

## 3. Indexes that already existed (from PK/UNIQUE)

| Index | Columns | Useful for "one instrument, in time order"? |
|---|---|---|
| pk_price_ticks | (tick_id) | no |
| uq_price_ticks_source_event | (source, instrument_id, source_event_id) | only partly: see skip scan below |

- **PostgreSQL 18 skip scan.** At baseline the planner used
  `uq_price_ticks_source_event` with `Index Cond: (instrument_id = …)`,
  even though instrument_id is its second column. The plan shows
  `Index Searches: 2`: it skips through each distinct `source` value, and
  this dataset has one.
- What skip scan gives: it finds all 25,000 rows of the instrument.
- What it doesn't give: time order, so a Sort is needed. And the rows are
  scattered over **all 6,371 heap pages**, so every query touched the
  whole table.
- **Honest baseline:** not a plain Seq Scan, but a full-table heap visit
  plus Sort for every query.

## 4. Queries (the project's real shapes)

The parameters were RELIANCE (instrument_id 1), with a middle point of its
history.

| Id | Used by | Shape |
|---|---|---|
| A | web UI: latest ticks | `WHERE instrument_id = ? ORDER BY observed_at DESC, tick_id DESC LIMIT 50` |
| B | history/chart | `WHERE instrument_id = ? AND observed_at >= ? AND observed_at < ? ORDER BY observed_at, tick_id` (30 min → 900 rows) |
| C | **alert trigger**: previous tick | `WHERE instrument_id = ? AND (observed_at, tick_id) < (?, ?) ORDER BY observed_at DESC, tick_id DESC LIMIT 1` |
| D | web UI: latest price per watchlist item | `watchlist_items` → `LATERAL (… ORDER BY observed_at DESC, tick_id DESC LIMIT 1)` (3 instruments) |
| E | **alert trigger**: late-tick check | `EXISTS (… WHERE instrument_id = ? AND observed_at > ?)`, where ? = the latest tick, so no match (the normal case) |
| F | **alert engine end-to-end** | `ingest_tick(...)` with the trigger on, 50 calls, each in its own rolled-back transaction |

Method:
- 2 warm-up runs, then **7 timed** `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`
  runs per query. The median is reported.
- The cache is warm: every buffer is a shared **hit**, read = 0.
- Every query returned identical results (SHA-256) in all three stages.

## 5. Results — before vs after `ix_price_ticks_instrument_time`

| Query | Baseline plan | Baseline median | Buffers | B-tree plan | B-tree median | Buffers |
|---|---|---|---|---|---|---|
| A latest 50 | Limit → **Sort** → Bitmap Heap Scan → Bitmap Index Scan (uq, skip scan) | **9.461 ms** | 6,371 | Limit → **Index Scan** using ix (no Sort) | **0.020 ms** | 16 |
| B 30-min range | **Sort** → Bitmap Heap Scan → Bitmap Index Scan (uq) | **4.539 ms** | 6,371 | **Sort** → Bitmap Heap Scan → Bitmap Index Scan using ix | **0.328 ms** | 228 |
| C previous tick | Limit → **Sort** → Bitmap Heap Scan → Bitmap Index Scan (uq) | **6.017 ms** | 6,371 | Limit → **Index Scan** using ix, row comparison in Index Cond | **0.007 ms** | 4 |
| D watchlist latest prices | per instrument: Limit → Sort → Bitmap Heap Scan (uq) | **22.880 ms** | 19,122 | per instrument: Limit → Index Scan using ix | **0.030 ms** | 15 |
| E late-tick check | Bitmap Heap Scan → Bitmap Index Scan (uq) | **4.274 ms** | 6,371 | **Index Only Scan** using ix | **0.004 ms** | 3 |
| F ingest_tick (trigger on) | trigger's late check = **Seq Scan, 500,001 rows removed** | **30.081 ms/call** | – | both trigger queries use ix | **0.199 ms/call** | – |

Spread of the 7 runs (min–max): A 9.295–9.576 → 0.019–0.020 ms; C
5.985–6.141 → 0.007–0.008 ms; F (50 calls) 11.7–30.9 → 0.16–2.6 ms.

What changed, query by query:
- **A, C, D:** the explicit Sort disappeared. The index already stores
  each instrument's ticks in (observed_at DESC, tick_id DESC) order, so
  LIMIT stops after reading 1 or 50 entries. Buffers fell from the whole
  table to a handful.
- **B:** the planner still chose Bitmap Heap Scan + Sort, not an ordered
  Index Scan. The 900 wanted rows sit on ~220 different heap pages, and a
  bitmap reads them in physical order. Sorting 900 rows (60 kB,
  quicksort) is cheap. The index still cut buffers 6,371 → 228 and time
  about 14×. **An index does not always remove a Sort.**
- **E:** an Index Only Scan with `Heap Fetches: 0`. All the needed columns
  are in the index and the table was VACUUMed, so the visibility map lets
  the scan skip the heap entirely.
- **C:** `Index Cond: ((instrument_id = $1) AND (ROW(observed_at, tick_id)
  < ROW(…)))`. PostgreSQL uses the whole row comparison inside the index,
  so it jumps straight to the right place and reads 4 buffers.
- **F (alert engine):** at baseline, the trigger's late-tick check ran as
  a Seq Scan over all 500,001 rows (22.6 ms) on *every* tick. The trigger
  runs it with parameters, and for that generic plan the planner picked a
  sequential scan. With the index, both trigger queries use it (0.003 ms
  and 0.009 ms), and ingest_tick is about **150× faster**.
  - Evidence: `trigger_auto_explain_*.txt`.
  - Why it matters: ingestion cost would otherwise grow with the size of
    the history table.

## 6. Sizes (B-tree stage)

| Relation | Size |
|---|---|
| price_ticks (heap) | 48 MB (49,930,240 bytes) |
| pk_price_ticks | 11 MB |
| uq_price_ticks_source_event | 42 MB |
| **ix_price_ticks_instrument_time** | **19 MB (20,307,968 bytes)** ≈ 41 % of the heap |
| price_ticks total (heap + all indexes + TOAST) | 100 MB → **120 MB** with the new index |
| B-tree build time (500k rows) | 0.40 s |

Trade-off:
- Disk: +19 MB, about +20 % of the table's total footprint.
- Writes: every INSERT must also add an entry to this B-tree. The +1 index
  write per tick is small compared with what it saves: the trigger itself
  reads this index on every insert.
- No UPDATE/DELETE cost in practice, because ticks are append-only by
  design.

## 7. BRIN comparison (benchmark DB only; NOT installed in the project)

`CREATE INDEX ix_bench_brin_observed_at ON price_ticks USING brin (observed_at)`,
tested with the B-tree dropped.

| Item | Result |
|---|---|
| Size | **24 kB** (B-tree: 19 MB), about 800× smaller |
| Build time | 0.03 s |
| A latest 50 | not used; same plan as baseline (uq skip scan + Sort), 9.480 ms |
| B 30-min range | **used**: BitmapAnd(BRIN time range, uq instrument) → 3.166 ms, 663 buffers (baseline 4.539 ms / 6,371; B-tree 0.328 ms / 228) |
| C previous tick | not used; 6.146 ms |
| D watchlist latest prices | not used; 23.286 ms |
| E late-tick check | used with BitmapAnd → 1.257 ms, 358 buffers (B-tree 0.004 ms) |

Conclusions:
- BRIN stores only the min/max observed_at per block range (128 pages),
  so it is tiny. It only helps when the query restricts a time range AND
  the table is physically in time order, which is true here.
- BRIN cannot return rows in order and knows nothing about instrument_id,
  so it can't serve "latest N for one instrument" (A, C, D). Those are the
  queries the UI and the alert trigger run most often.
- Decision: **not kept**. The project's queries are per-instrument and
  ordered, which is what the composite B-tree is built for.

## 8. Final index

```sql
CREATE INDEX IF NOT EXISTS ix_price_ticks_instrument_time
    ON price_ticks (instrument_id, observed_at DESC, tick_id DESC);
```

- File: `sql/06_indexes.sql`, kept separate from `00_schema.sql`, because
  it is a physical performance choice, not part of the logical design.
- Installed on the dev database stock_watchlist on 2026-09-25.
- Tests: `tests/test_indexes.py` (15). `sql/verify_spec.sql` now expects
  exactly this index and still reports any other index as EXTRA.

Why this column order:
1. `instrument_id` first, because every query is "one instrument" (an
   equality). Leading with it groups each instrument's ticks together.
2. `observed_at` next: range filters and ORDER BY happen on time, within
   one instrument.
3. `tick_id` last: the tie-breaker in the (observed_at, tick_id) ordering
   used by the trigger. It makes the index order match ORDER BY exactly,
   so LIMIT needs no Sort even when timestamps repeat.
4. `DESC` makes a forward scan return latest-first, which is the most
   common access (A, C, D, E).
   - An all-ASC index would also work, because PostgreSQL can scan a
     B-tree backwards (`Index Scan Backward`).
   - DESC matters only when directions are mixed, so it is a readability
     and intent choice, not a correctness requirement.

No other index was added:
- alert_events cooldown lookup (`WHERE rule_id = …`) is already served by
  `uq_alert_events_rule_tick (rule_id, tick_id)`, visible in the trigger
  plans.
- The event → tick join uses `pk_price_ticks`.
- alert_rules has 6 rows; a Seq Scan there is the cheapest plan.

## 9. Limitations of this benchmark

- Warm cache only. Every buffer was a memory hit; macOS can't easily drop
  the OS cache, so cold-disk timings weren't measured.
- One machine and one run. Medians of 7 runs are stable, runs within about
  3 % of each other, but absolute times will differ on other hardware.
- Synthetic, evenly interleaved data with one `source` value. Real data
  mixes 3 sources (REPLAY/BINANCE/MANUAL), which gives skip scan more
  distinct values to jump through at baseline.
- Physical time order favours BRIN, so its result is a best case.
- 500k rows. The effect grows with table size for the baseline plans,
  which touch every heap page, while the B-tree plans read about 3–16
  pages regardless of size.
- Planner choices are cost-based and may change with statistics or
  settings; tests check plan *properties*, not exact text.
- Write overhead was not measured in isolation. The ingest_tick numbers
  include the index maintenance and still improved 150×, because the
  trigger reads the same index.
