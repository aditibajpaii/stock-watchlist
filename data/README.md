# Replay data

## replay_prices.csv

Deterministic demo feed for `python -m app.replay`.

Columns (header required, in this order):

| Column | Meaning | Rules |
|---|---|---|
| offset_seconds | market time relative to the run start | integer ≥ 0, non-decreasing down the file |
| exchange | instrument exchange | must exist in `instruments` |
| symbol | instrument symbol | must exist in `instruments` |
| price | tick price | decimal > 0 |
| volume | traded volume | decimal ≥ 0, or blank = unknown (stored as NULL) |

- `observed_at = run_start + offset_seconds`
- `source_event_id = <run_id>:<row number, 6 digits>`; row 1 = first data row

### What the file is designed to trigger (seed rules)

| Row | Offset | Tick | Rule | Result |
|---|---|---|---|---|
| 6 | 20 s | RELIANCE 2994.00 → 3002.40 | 1 arjun ABOVE 3000 (cd 300 s) | **event** |
| 8, 11 | 30, 45 s | RELIANCE stays above | 1 | none (edge-triggered) |
| 9 | 35 s | TCS 3531.25 → 3498.00 | 4 priya BELOW 3500 (cd 0) | **event** |
| 10 | 40 s | BTCUSDT 99880 → 100120 | 3 arjun ABOVE 100000 (cd 60 s) | **event** |
| 12 | 50 s | TCS stays below | 4 | none |
| 16 | 80 s | BTCUSDT 99920 → 100050 | 3 | suppressed (80 < 40 + 60) |
| 18 | 110 s | ETHUSDT 3048.10 → 2994.60 | 6 kavya BELOW 3000 (cd 120 s) | **event** |
| 20 | 130 s | TCS 3512.00 → 3490.00 | 4 | **event** (cooldown 0) |
| 22 | 170 s | BTCUSDT 99800 → 100400 | 3 | **event** (170 ≥ 40 + 60) |
| 23 | 200 s | RELIANCE 2979.00 → 3004.00 | 1 | suppressed (200 < 20 + 300) |
| 26 | 310 s | INFY 1585 → 1612 | 5 priya ABOVE 1600 (inactive) | none (rule inactive) |
| 27 | 400 s | RELIANCE 2990.00 → 3021.50 | 1 | **event** (400 ≥ 20 + 300) |
| 28 | 430 s | RELIANCE stays above | 1 | none |
| 29 | 450 s | RELIANCE 3030.00 → 2795.00 | 2 arjun BELOW 2800 (cd 300 s) | **event** |
| 30 | 460 s | RELIANCE stays below | 2 | none |

Expected total per run: **8 alert events**, spread over rules 1 ×2, 2 ×1, 3 ×2, 4 ×2 and 6 ×1.

Other facts:
- 30 rows across 5 instruments: RELIANCE 12, TCS 6, BTCUSDT 8, ETHUSDT 2,
  INFY 2.
- Volume is blank (NULL) on 8 rows (3, 5, 11, 14, 18, 24, 28, 30).
- The logical span is 460 s. Each run's ticks run from run_start to
  run_start + 7 min 40 s.
- The count of 8 applies to a freshly seeded database. A second new run
  continues the same market history, so cooldowns and previous prices
  carry over. Example: run back to back with --start-after-latest, the
  new run starts 1 s after the previous run's last tick (+460 s). Its
  row 6 is then only 81 s after the previous run's row-27 rule-1 alert
  (+400 s), which is inside rule 1's 300 s cooldown. That run produces 7
  alerts.
