"""FastAPI backend for the Stock Watchlist & Alert System.

Run (project root, venv active):
    uvicorn app.main:app --reload
Interactive docs: http://127.0.0.1:8000/docs

PostgreSQL remains the source of truth. This layer only:
  * runs parameterized SQL (no ORM, no string-built SQL),
  * wraps writes in explicit transactions,
  * maps database errors to HTTP responses (app/errors.py).
Constraints, ingest_tick(), the alert trigger, cooldowns and duplicate
protection all stay inside PostgreSQL.
"""

from typing import Annotated

import psycopg
from fastapi import Depends, FastAPI, HTTPException, Path, Query, Response, status
from fastapi.responses import JSONResponse
from psycopg import sql
from pydantic import AwareDatetime

from app import schemas
from app.db import connect, get_conn
from app.errors import database_error_handler

app = FastAPI(
    title="Stock Watchlist & Alert API",
    description="BCSE302P project backend. All data rules are enforced by PostgreSQL.",
    version="1.0.0",
)
app.add_exception_handler(psycopg.Error, database_error_handler)

Conn = Annotated[psycopg.Connection, Depends(get_conn)]
Id = Annotated[int, Path(gt=0, le=2**63 - 1)]
# timezone REQUIRED, e.g. 2026-01-05T09:15:00Z or 2026-01-05T09:15:00%2B05:30
AwareDatetimeQuery = Annotated[AwareDatetime | None, Query()]

HISTORY_DEFAULT, HISTORY_MAX = 100, 1000
ALERTS_DEFAULT, ALERTS_MAX = 50, 500

RULE_SELECT = """
    SELECT r.rule_id, r.user_id, r.instrument_id, i.exchange, i.symbol,
           r.direction, r.threshold, r.cooldown_seconds, r.is_active, r.created_at
    FROM alert_rules r
    JOIN instruments i ON i.instrument_id = r.instrument_id"""

INSTRUMENT_COLUMNS = "instrument_id, exchange, symbol, name, quote_currency, is_active"
TICK_COLUMNS = "tick_id, instrument_id, observed_at, price, volume, source, source_event_id"


# ---------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------
def require(conn, table: str, key: str, value: int, label: str) -> None:
    """404 unless the row exists. Table/column names are fixed literals."""
    query = sql.SQL("SELECT 1 FROM {} WHERE {} = %s").format(sql.Identifier(table), sql.Identifier(key))
    if conn.execute(query, (value,)).fetchone() is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"{label} not found.")


def require_user(conn, user_id):
    require(conn, "users", "user_id", user_id, "User")


def require_instrument(conn, instrument_id):
    require(conn, "instruments", "instrument_id", instrument_id, "Instrument")


# ---------------------------------------------------------------------
# health
# ---------------------------------------------------------------------
@app.get("/health", response_model=schemas.Health, tags=["health"],
         responses={503: {"description": "Database unreachable"}})
def health():
    """FastAPI is up AND PostgreSQL answers a query."""
    try:
        with connect(connect_timeout=3) as conn:
            conn.execute("SELECT 1")
    except psycopg.Error:
        return JSONResponse(status_code=503, content={"status": "error", "database": "unavailable"})
    return {"status": "ok", "database": "connected"}


# ---------------------------------------------------------------------
# users (demo users; no authentication in this project)
# ---------------------------------------------------------------------
@app.get("/users", response_model=list[schemas.User], tags=["users"])
def list_users(conn: Conn):
    return conn.execute("SELECT user_id, username, email, created_at FROM users "
                        "ORDER BY user_id").fetchall()


@app.get("/users/{user_id}", response_model=schemas.User, tags=["users"])
def get_user(user_id: Id, conn: Conn):
    row = conn.execute("SELECT user_id, username, email, created_at FROM users "
                       "WHERE user_id = %s", (user_id,)).fetchone()
    if row is None:
        raise HTTPException(404, "User not found.")
    return row


# ---------------------------------------------------------------------
# instruments and prices
# ---------------------------------------------------------------------
@app.get("/instruments", response_model=list[schemas.Instrument], tags=["instruments"])
def list_instruments(conn: Conn,
                     exchange: Annotated[str | None, Query(max_length=20)] = None,
                     active_only: bool = False):
    conditions, params = [], []
    if exchange is not None:
        conditions.append(sql.SQL("exchange = %s"))
        params.append(exchange)
    if active_only:
        conditions.append(sql.SQL("is_active"))
    query = sql.SQL("SELECT {} FROM instruments").format(sql.SQL(INSTRUMENT_COLUMNS))
    if conditions:
        query += sql.SQL(" WHERE ") + sql.SQL(" AND ").join(conditions)
    query += sql.SQL(" ORDER BY exchange, symbol")
    return conn.execute(query, params).fetchall()


@app.get("/instruments/{instrument_id}", response_model=schemas.Instrument, tags=["instruments"])
def get_instrument(instrument_id: Id, conn: Conn):
    row = conn.execute(f"SELECT {INSTRUMENT_COLUMNS} FROM instruments WHERE instrument_id = %s",
                       (instrument_id,)).fetchone()
    if row is None:
        raise HTTPException(404, "Instrument not found.")
    return row


@app.get("/instruments/{instrument_id}/latest", response_model=schemas.Tick, tags=["instruments"],
         responses={404: {"description": "Instrument not found, or it has no ticks yet"}})
def latest_tick(instrument_id: Id, conn: Conn):
    """Latest tick by (observed_at DESC, tick_id DESC) - served by
    ix_price_ticks_instrument_time. No latest-price table exists."""
    with conn.transaction():
        require_instrument(conn, instrument_id)
        row = conn.execute(
            f"""SELECT {TICK_COLUMNS} FROM price_ticks
                WHERE instrument_id = %s
                ORDER BY observed_at DESC, tick_id DESC LIMIT 1""", (instrument_id,)).fetchone()
    if row is None:
        raise HTTPException(404, "Instrument has no price ticks yet.")
    return row


@app.get("/instruments/{instrument_id}/history", response_model=list[schemas.Tick],
         tags=["instruments"])
def price_history(instrument_id: Id, conn: Conn,
                  limit: Annotated[int, Query(ge=1, le=HISTORY_MAX)] = HISTORY_DEFAULT,
                  from_time: AwareDatetimeQuery = None,
                  to_time: AwareDatetimeQuery = None):
    """The most recent `limit` ticks (optionally within [from_time, to_time)),
    returned in CHRONOLOGICAL order: oldest first, ordered by
    (observed_at, tick_id)."""
    if from_time and to_time and from_time >= to_time:
        raise HTTPException(422, "from_time must be earlier than to_time.")
    conditions = [sql.SQL("instrument_id = %(iid)s")]
    if from_time:
        conditions.append(sql.SQL("observed_at >= %(from_time)s"))
    if to_time:
        conditions.append(sql.SQL("observed_at < %(to_time)s"))
    query = sql.SQL("""
        SELECT * FROM (
            SELECT {cols} FROM price_ticks
            WHERE {where}
            ORDER BY observed_at DESC, tick_id DESC
            LIMIT %(limit)s) recent
        ORDER BY observed_at, tick_id""").format(
        cols=sql.SQL(TICK_COLUMNS), where=sql.SQL(" AND ").join(conditions))
    with conn.transaction():
        require_instrument(conn, instrument_id)
        return conn.execute(query, {"iid": instrument_id, "from_time": from_time,
                                    "to_time": to_time, "limit": limit}).fetchall()


# ---------------------------------------------------------------------
# watchlists
# ---------------------------------------------------------------------
WATCHLIST_ITEMS_QUERY = sql.SQL("""
    SELECT w.watchlist_id, w.user_id, w.name, w.created_at,
           i.instrument_id, i.exchange, i.symbol, i.name AS instrument_name,
           wi.added_at, lt.price AS latest_price, lt.observed_at AS latest_observed_at
    FROM watchlists w
    LEFT JOIN watchlist_items wi ON wi.watchlist_id = w.watchlist_id
    LEFT JOIN instruments i      ON i.instrument_id = wi.instrument_id
    LEFT JOIN LATERAL (                       -- latest tick, via the Phase 6 index
        SELECT t.price, t.observed_at
        FROM price_ticks t
        WHERE t.instrument_id = wi.instrument_id
        ORDER BY t.observed_at DESC, t.tick_id DESC
        LIMIT 1) lt ON true
    WHERE {where}
    ORDER BY w.name, w.watchlist_id, i.exchange, i.symbol""")


def group_watchlists(rows) -> list[dict]:
    """One SQL result (watchlist x item rows) -> nested watchlists."""
    lists: dict[int, dict] = {}
    for r in rows:
        wl = lists.setdefault(r["watchlist_id"], {
            "watchlist_id": r["watchlist_id"], "user_id": r["user_id"],
            "name": r["name"], "created_at": r["created_at"], "items": []})
        if r["instrument_id"] is not None:          # LEFT JOIN: empty list -> no item
            wl["items"].append({
                "instrument_id": r["instrument_id"], "exchange": r["exchange"],
                "symbol": r["symbol"], "name": r["instrument_name"], "added_at": r["added_at"],
                "latest_price": r["latest_price"], "latest_observed_at": r["latest_observed_at"]})
    return list(lists.values())


@app.get("/users/{user_id}/watchlists", response_model=list[schemas.Watchlist], tags=["watchlists"])
def list_watchlists(user_id: Id, conn: Conn):
    """All watchlists of a user with their items and each item's latest price,
    in ONE query (LEFT JOIN + LATERAL), not one query per item."""
    with conn.transaction():
        require_user(conn, user_id)
        rows = conn.execute(WATCHLIST_ITEMS_QUERY.format(where=sql.SQL("w.user_id = %s")),
                            (user_id,)).fetchall()
    return group_watchlists(rows)


@app.post("/users/{user_id}/watchlists", response_model=schemas.Watchlist,
          status_code=status.HTTP_201_CREATED, tags=["watchlists"])
def create_watchlist(user_id: Id, body: schemas.WatchlistCreate, conn: Conn):
    """UNIQUE (user_id, name) and fk_watchlists_user are enforced by PostgreSQL."""
    with conn.transaction():
        row = conn.execute(
            """INSERT INTO watchlists (user_id, name) VALUES (%s, %s)
               RETURNING watchlist_id, user_id, name, created_at""",
            (user_id, body.name)).fetchone()
    return {**row, "items": []}


@app.delete("/watchlists/{watchlist_id}", status_code=status.HTTP_204_NO_CONTENT,
            tags=["watchlists"])
def delete_watchlist(watchlist_id: Id, conn: Conn):
    """Its watchlist_items go too (ON DELETE CASCADE). Instruments and price
    history are untouched."""
    with conn.transaction():
        deleted = conn.execute("DELETE FROM watchlists WHERE watchlist_id = %s RETURNING 1",
                               (watchlist_id,)).fetchone()
    if deleted is None:
        raise HTTPException(404, "Watchlist not found.")


@app.post("/watchlists/{watchlist_id}/items", response_model=schemas.WatchlistItem,
          status_code=status.HTTP_201_CREATED, tags=["watchlists"])
def add_watchlist_item(watchlist_id: Id, body: schemas.WatchlistItemCreate, conn: Conn):
    """PK (watchlist_id, instrument_id) rejects duplicates (409); the two FKs
    reject a missing watchlist or instrument (404)."""
    with conn.transaction():
        conn.execute("INSERT INTO watchlist_items (watchlist_id, instrument_id) VALUES (%s, %s)",
                     (watchlist_id, body.instrument_id))
        rows = conn.execute(
            WATCHLIST_ITEMS_QUERY.format(
                where=sql.SQL("w.watchlist_id = %s AND wi.instrument_id = %s")),
            (watchlist_id, body.instrument_id)).fetchall()
    return group_watchlists(rows)[0]["items"][0]


@app.delete("/watchlists/{watchlist_id}/items/{instrument_id}",
            status_code=status.HTTP_204_NO_CONTENT, tags=["watchlists"])
def remove_watchlist_item(watchlist_id: Id, instrument_id: Id, conn: Conn):
    """Removes only the (watchlist, instrument) pair, never the instrument."""
    with conn.transaction():
        deleted = conn.execute(
            """DELETE FROM watchlist_items WHERE watchlist_id = %s AND instrument_id = %s
               RETURNING 1""", (watchlist_id, instrument_id)).fetchone()
    if deleted is None:
        raise HTTPException(404, "That instrument is not in this watchlist.")


# ---------------------------------------------------------------------
# alert rules
# ---------------------------------------------------------------------
@app.get("/users/{user_id}/alert-rules", response_model=list[schemas.AlertRule],
         tags=["alert rules"])
def list_alert_rules(user_id: Id, conn: Conn):
    with conn.transaction():
        require_user(conn, user_id)
        return conn.execute(RULE_SELECT + " WHERE r.user_id = %s ORDER BY r.rule_id",
                            (user_id,)).fetchall()


@app.post("/users/{user_id}/alert-rules", response_model=schemas.AlertRule,
          status_code=status.HTTP_201_CREATED, tags=["alert rules"])
def create_alert_rule(user_id: Id, body: schemas.AlertRuleCreate, conn: Conn):
    """CHECKs (direction, threshold > 0, cooldown >= 0), both FKs and
    UNIQUE (user_id, instrument_id, direction, threshold) are PostgreSQL's."""
    with conn.transaction():
        rule_id = conn.execute(
            """INSERT INTO alert_rules (user_id, instrument_id, direction, threshold, cooldown_seconds)
               VALUES (%s, %s, %s, %s, %s) RETURNING rule_id""",
            (user_id, body.instrument_id, body.direction, body.threshold,
             body.cooldown_seconds)).fetchone()["rule_id"]
        return conn.execute(RULE_SELECT + " WHERE r.rule_id = %s", (rule_id,)).fetchone()


@app.patch("/alert-rules/{rule_id}", response_model=schemas.AlertRule, tags=["alert rules"])
def update_alert_rule(rule_id: Id, body: schemas.AlertRulePatch, conn: Conn):
    """Changes ONLY is_active and/or cooldown_seconds. The rule definition
    (user, instrument, direction, threshold) is immutable by design: those
    fields are rejected with 422 and never appear in this UPDATE."""
    with conn.transaction():
        updated = conn.execute(
            """UPDATE alert_rules
               SET is_active        = coalesce(%s, is_active),
                   cooldown_seconds = coalesce(%s, cooldown_seconds)
               WHERE rule_id = %s RETURNING rule_id""",
            (body.is_active, body.cooldown_seconds, rule_id)).fetchone()
        if updated is None:
            raise HTTPException(404, "Alert rule not found.")
        return conn.execute(RULE_SELECT + " WHERE r.rule_id = %s", (rule_id,)).fetchone()


@app.delete("/alert-rules/{rule_id}", status_code=status.HTTP_204_NO_CONTENT,
            tags=["alert rules"])
def delete_alert_rule(rule_id: Id, conn: Conn):
    """Deletes the rule AND its alert history: alert_events.rule_id is
    ON DELETE CASCADE (approved ownership policy). Price ticks are kept.
    To keep history, disable the rule instead (PATCH is_active=false)."""
    with conn.transaction():
        deleted = conn.execute("DELETE FROM alert_rules WHERE rule_id = %s RETURNING 1",
                               (rule_id,)).fetchone()
    if deleted is None:
        raise HTTPException(404, "Alert rule not found.")


# ---------------------------------------------------------------------
# alert history
# ---------------------------------------------------------------------
@app.get("/users/{user_id}/alerts", response_model=list[schemas.AlertEvent], tags=["alerts"])
def list_alerts(user_id: Id, conn: Conn,
                limit: Annotated[int, Query(ge=1, le=ALERTS_MAX)] = ALERTS_DEFAULT,
                instrument_id: Annotated[int | None, Query(gt=0, le=2**63 - 1)] = None):
    """Newest first (fired_at DESC, event_id DESC). alert_events stores only
    (event_id, rule_id, tick_id, fired_at); instrument, price and time come
    from joins - the normalized design at work."""
    conditions = [sql.SQL("r.user_id = %(user_id)s")]
    if instrument_id is not None:
        conditions.append(sql.SQL("r.instrument_id = %(instrument_id)s"))
    query = sql.SQL("""
        SELECT e.event_id, e.rule_id, r.instrument_id, i.exchange, i.symbol,
               r.direction, r.threshold, e.tick_id, t.price, t.observed_at, e.fired_at
        FROM alert_events e
        JOIN alert_rules  r ON r.rule_id = e.rule_id
        JOIN price_ticks  t ON t.tick_id = e.tick_id
        JOIN instruments  i ON i.instrument_id = t.instrument_id
        WHERE {where}
        ORDER BY e.fired_at DESC, e.event_id DESC
        LIMIT %(limit)s""").format(where=sql.SQL(" AND ").join(conditions))
    with conn.transaction():
        require_user(conn, user_id)
        return conn.execute(query, {"user_id": user_id, "instrument_id": instrument_id,
                                    "limit": limit}).fetchall()


# ---------------------------------------------------------------------
# manual ingestion (development / demo)
# ---------------------------------------------------------------------
@app.post("/ticks/ingest", response_model=schemas.IngestResult, tags=["ingestion (dev/demo)"],
          responses={201: {"description": "INSERTED"}, 200: {"description": "DUPLICATE"}})
def ingest(body: schemas.TickIngest, response: Response, conn: Conn):
    """Development/demo only. Sends ONE tick through the same PostgreSQL
    function as the replay: ingest_tick(..., source='MANUAL', ...). Never a
    direct INSERT. The instrument lock, duplicate check and alert trigger
    all run inside PostgreSQL within this transaction.
    201 + INSERTED, or 200 + DUPLICATE (same source_event_id again)."""
    with conn.transaction():
        row = conn.execute(
            "SELECT status, tick_id FROM ingest_tick(%s, %s, %s, %s, %s, 'MANUAL', %s)",
            (body.exchange, body.symbol, body.observed_at, body.price, body.volume,
             body.source_event_id)).fetchone()
    response.status_code = 201 if row["status"] == "INSERTED" else 200
    return row
