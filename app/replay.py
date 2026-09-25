"""Offline price replay: feed a CSV of price events into PostgreSQL.

Every event goes through the database function ingest_tick(...), which
locks the instrument, inserts the tick (or reports DUPLICATE) and lets
the alert trigger fire - exactly the path a live feed will use.

Usage (from the project root, virtual environment active):

    python -m app.replay data/replay_prices.csv
    python -m app.replay data/replay_prices.csv --delay-ms 300
    python -m app.replay data/replay_prices.csv --dry-run
    python -m app.replay data/replay_prices.csv --run-id <id>   # retry a run

Exit codes: 0 success, 1 invalid CSV/arguments, 2 database/ingestion error.
"""

import argparse
import csv
import re
import sys
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from zoneinfo import ZoneInfo

import psycopg

from app.config import conninfo

SOURCE = "REPLAY"
COLUMNS = ["offset_seconds", "exchange", "symbol", "price", "volume"]
RUN_ID_PATTERN = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
DISPLAY_TZ = ZoneInfo("Asia/Kolkata")

EXIT_OK = 0
EXIT_BAD_INPUT = 1
EXIT_DB_ERROR = 2


class CsvError(Exception):
    """The replay file is invalid; nothing has been sent to the database."""


@dataclass(frozen=True)
class ReplayRow:
    row_no: int            # 1 = first data row (header not counted)
    offset_seconds: int
    exchange: str
    symbol: str
    price: Decimal
    volume: Decimal | None  # None = unknown -> SQL NULL


# ---------------------------------------------------------------------
# CSV reading and validation (all rows are checked before any ingestion)
# ---------------------------------------------------------------------
def _decimal(text: str) -> Decimal:
    value = Decimal(text)          # raises InvalidOperation on junk
    if not value.is_finite():
        raise InvalidOperation
    return value


def parse_row(row_no: int, record: dict) -> ReplayRow:
    """Validate one CSV record; raise CsvError with a readable message."""
    def field(name: str) -> str:
        value = (record.get(name) or "").strip()
        if name != "volume" and not value:
            raise CsvError(f"row {row_no}: missing {name}")
        return value

    try:
        offset = int(field("offset_seconds"))
    except ValueError:
        raise CsvError(f"row {row_no}: offset_seconds must be a whole number") from None
    if offset < 0:
        raise CsvError(f"row {row_no}: offset_seconds must be >= 0")

    try:
        price = _decimal(field("price"))
    except InvalidOperation:
        raise CsvError(f"row {row_no}: price {record.get('price')!r} is not a number") from None
    if price <= 0:
        raise CsvError(f"row {row_no}: price must be > 0")

    volume_text = field("volume")
    volume = None
    if volume_text:
        try:
            volume = _decimal(volume_text)
        except InvalidOperation:
            raise CsvError(f"row {row_no}: volume {volume_text!r} is not a number") from None
        if volume < 0:
            raise CsvError(f"row {row_no}: volume must be >= 0 or blank")

    return ReplayRow(row_no, offset, field("exchange"), field("symbol"), price, volume)


def load_csv(path: str) -> list[ReplayRow]:
    """Read and validate the whole file. Raises CsvError listing every problem."""
    try:
        with open(path, newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            if reader.fieldnames != COLUMNS:
                raise CsvError(f"header must be exactly: {','.join(COLUMNS)} "
                               f"(found: {','.join(reader.fieldnames or [])})")
            records = list(reader)
    except OSError as e:
        raise CsvError(f"cannot read {path}: {e.strerror}") from None

    rows, problems = [], []
    for row_no, record in enumerate(records, start=1):
        if None in record:     # more values than header columns
            problems.append(f"row {row_no}: too many values")
            continue
        try:
            rows.append(parse_row(row_no, record))
        except CsvError as e:
            problems.append(str(e))

    for prev, cur in zip(rows, rows[1:]):
        if cur.offset_seconds < prev.offset_seconds:
            problems.append(f"row {cur.row_no}: offset_seconds goes backwards "
                            f"({cur.offset_seconds} after {prev.offset_seconds})")
    if not records:
        problems.append("file has no data rows")
    if problems:
        raise CsvError("invalid replay file:\n  " + "\n  ".join(problems))
    return rows


# ---------------------------------------------------------------------
# Run identity and timestamps
# ---------------------------------------------------------------------
def source_event_id(run_id: str, row_no: int) -> str:
    return f"{run_id}:{row_no:06d}"


def observed_at(run_start: datetime, row: ReplayRow) -> datetime:
    return run_start + timedelta(seconds=row.offset_seconds)


def now_whole_second() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


def recover_run_start(cur, run_id: str, first: ReplayRow) -> datetime | None:
    """For a retried run: original run_start = observed_at of its row 1 - offset.

    Exact lookup on the unique tick identity (source, instrument, event id);
    the event id is never parsed.
    """
    cur.execute(
        """SELECT t.observed_at
           FROM price_ticks t
           JOIN instruments i ON i.instrument_id = t.instrument_id
           WHERE t.source = %s AND i.exchange = %s AND i.symbol = %s
             AND t.source_event_id = %s""",
        (SOURCE, first.exchange, first.symbol, source_event_id(run_id, first.row_no)),
    )
    found = cur.fetchone()
    return None if found is None else found[0] - timedelta(seconds=first.offset_seconds)


def latest_existing_tick(cur, rows: list[ReplayRow]) -> datetime | None:
    """Latest observed_at already stored for any instrument in this file."""
    pairs = sorted({(r.exchange, r.symbol) for r in rows})
    cur.execute(
        """SELECT max(t.observed_at)
           FROM price_ticks t
           JOIN instruments i ON i.instrument_id = t.instrument_id
           WHERE (i.exchange, i.symbol) IN
                 (SELECT * FROM unnest(%s::text[], %s::text[]))""",
        ([p[0] for p in pairs], [p[1] for p in pairs]),
    )
    return cur.fetchone()[0]


# ---------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------
def fmt_time(ts: datetime) -> str:
    return ts.astimezone(DISPLAY_TZ).strftime("%Y-%m-%d %H:%M:%S IST")


def describe(row: ReplayRow) -> str:
    volume = "NULL" if row.volume is None else f"{row.volume}"
    return (f"[{row.row_no:03d}] +{row.offset_seconds:>4}s "
            f"{row.exchange:<7} {row.symbol:<9} {row.price:>11} vol={volume:<6}")


# ---------------------------------------------------------------------
# Main replay
# ---------------------------------------------------------------------
def parse_args(argv):
    p = argparse.ArgumentParser(
        prog="python -m app.replay",
        description="Replay a price CSV into PostgreSQL through ingest_tick().")
    p.add_argument("csv_path", help="replay file, e.g. data/replay_prices.csv")
    p.add_argument("--run-id",
                   help="reuse an earlier run id to retry that run (default: new UUID)")
    p.add_argument("--delay-ms", type=int, default=0,
                   help="real pause between events, for demos (default 0)")
    p.add_argument("--dry-run", action="store_true",
                   help="validate and print what would be sent; no database access")
    p.add_argument("--continue-on-error", action="store_true",
                   help="after a failed event, keep going (exit code is still 2)")
    p.add_argument("--start-after-latest", action="store_true",
                   help="for a NEW run: start 1 s after the latest stored tick of these "
                        "instruments instead of refusing when now is earlier")
    args = p.parse_args(argv)
    if args.delay_ms < 0:
        p.error("--delay-ms must be >= 0")
    if args.run_id is not None and not RUN_ID_PATTERN.match(args.run_id):
        p.error("--run-id may contain only letters, digits, '-' and '_' (max 64)")
    return args


def main(argv=None) -> int:
    args = parse_args(argv)

    try:
        rows = load_csv(args.csv_path)
    except CsvError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return EXIT_BAD_INPUT

    run_id = args.run_id or str(uuid.uuid4())

    # ---- dry run: no database connection at all ------------------------
    if args.dry_run:
        run_start = now_whole_second()
        print(f"DRY RUN - nothing is sent to the database")
        print(f"Run ID:    {run_id}")
        print(f"Run start: {fmt_time(run_start)} (a real run recomputes this)")
        for row in rows:
            print(f"{describe(row)} -> would send observed_at="
                  f"{fmt_time(observed_at(run_start, row))} "
                  f"source_event_id={source_event_id(run_id, row.row_no)}")
        print(f"Dry run complete: {len(rows)} rows valid, 0 sent")
        return EXIT_OK

    # ---- real run -------------------------------------------------------
    try:
        conn = psycopg.connect(conninfo(), autocommit=True)
    except psycopg.Error as e:
        print(f"ERROR: cannot connect to the database: {e}", file=sys.stderr)
        return EXIT_DB_ERROR

    with conn:
        with conn.cursor() as cur:
            run_start = recover_run_start(cur, run_id, rows[0]) if args.run_id else None
            if run_start is not None:
                print(f"Retrying run {run_id}: original run start recovered from row 1")
            else:
                run_start = now_whole_second()
                latest = latest_existing_tick(cur, rows)
                if latest is not None and latest >= run_start:
                    if not args.start_after_latest:
                        print(
                            "ERROR: these instruments already have ticks up to "
                            f"{fmt_time(latest)}, which is not before this run's start "
                            f"{fmt_time(run_start)}.\n"
                            "  New ticks would be classified as LATE and no alerts would fire.\n"
                            "  Options: wait until after that time, rerun with "
                            "--start-after-latest, or rebuild the dev database.",
                            file=sys.stderr)
                        return EXIT_DB_ERROR
                    run_start = latest.replace(microsecond=0) + timedelta(seconds=1)
                    print("Starting after the latest stored tick (--start-after-latest)")

        print(f"Run ID:    {run_id}")
        print(f"Run start: {fmt_time(run_start)}")
        print(f"Database:  {conn.info.dbname}")
        return replay_rows(conn, rows, run_id, run_start, args)


def replay_rows(conn, rows, run_id, run_start, args) -> int:
    """One transaction per event: ingest, read resulting alerts, commit."""
    counts = {"INSERTED": 0, "DUPLICATE": 0, "ERROR": 0, "ALERTS": 0}

    for i, row in enumerate(rows):
        if i and args.delay_ms:
            time.sleep(args.delay_ms / 1000)
        line = describe(row)
        try:
            with conn.transaction():
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT status, tick_id FROM ingest_tick(%s, %s, %s, %s, %s, %s, %s)",
                        (row.exchange, row.symbol, observed_at(run_start, row), row.price,
                         row.volume, SOURCE, source_event_id(run_id, row.row_no)))
                    status, tick_id = cur.fetchone()
                    alerts = []
                    if status == "INSERTED":
                        cur.execute(
                            """SELECT e.event_id, u.username, r.direction, r.threshold
                               FROM alert_events e
                               JOIN alert_rules r ON r.rule_id = e.rule_id
                               JOIN users u ON u.user_id = r.user_id
                               WHERE e.tick_id = %s ORDER BY e.event_id""",
                            (tick_id,))
                        alerts = cur.fetchall()
        except psycopg.Error as e:
            counts["ERROR"] += 1
            diag = e.diag
            print(f"{line} -> ERROR [{e.sqlstate}] {diag.message_primary or e} "
                  f"(event rolled back)", file=sys.stderr)
            if not args.continue_on_error:
                break
            continue

        counts[status] += 1
        counts["ALERTS"] += len(alerts)
        result = f"INSERTED tick={tick_id}" if status == "INSERTED" else "DUPLICATE"
        print(f"{line} -> {result}")
        for event_id, username, direction, threshold in alerts:
            print(f"        ALERT event={event_id}: {username} {row.symbol} "
                  f"{direction} {threshold.normalize():f}")

    processed = counts["INSERTED"] + counts["DUPLICATE"] + counts["ERROR"]
    print()
    print("Replay complete" if counts["ERROR"] == 0 else "Replay FAILED")
    print(f"Run ID:     {run_id}")
    print(f"Rows:       {len(rows)} (processed {processed})")
    print(f"Inserted:   {counts['INSERTED']}")
    print(f"Duplicates: {counts['DUPLICATE']}")
    print(f"Errors:     {counts['ERROR']}")
    print(f"Alerts:     {counts['ALERTS']}")
    return EXIT_OK if counts["ERROR"] == 0 else EXIT_DB_ERROR


if __name__ == "__main__":
    sys.exit(main())
