"""Turn PostgreSQL errors into readable HTTP responses.

PostgreSQL stays the final authority: the API does not pre-check what a
constraint already guarantees. When a constraint, foreign key or
ingest_tick() rejects something, the SQLSTATE and constraint name are
mapped here to an HTTP status and a short message. Unknown database errors
become a generic 500 - no traceback, SQL text or connection details are
ever returned to the client.
"""

import logging

import psycopg
from fastapi import Request
from fastapi.responses import JSONResponse

log = logging.getLogger("app")

# (SQLSTATE, constraint name) -> (HTTP status, message)
CONSTRAINT_MESSAGES = {
    # UNIQUE / PRIMARY KEY violations
    ("23505", "uq_watchlists_user_name"): (409, "This user already has a watchlist with that name."),
    ("23505", "pk_watchlist_items"): (409, "That instrument is already in this watchlist."),
    ("23505", "uq_alert_rules_definition"): (409, "This user already has an identical alert rule "
                                                  "(same instrument, direction and threshold)."),
    # FOREIGN KEY violations on insert: the referenced row does not exist
    ("23503", "fk_watchlists_user"): (404, "User not found."),
    ("23503", "fk_alert_rules_user"): (404, "User not found."),
    ("23503", "fk_alert_rules_instrument"): (404, "Instrument not found."),
    ("23503", "fk_watchlist_items_watchlist"): (404, "Watchlist not found."),
    ("23503", "fk_watchlist_items_instrument"): (404, "Instrument not found."),
}

# SQLSTATE -> (HTTP status, message) when no constraint-specific entry applies
SQLSTATE_MESSAGES = {
    "SW001": (404, "Unknown instrument (no such exchange + symbol)."),
    "SW002": (409, "Instrument is inactive; ticks are not accepted."),
    "23505": (409, "Duplicate value."),
    "23503": (409, "Referenced row does not exist or is still referenced."),
    "23001": (409, "Row is still referenced by other data (ON DELETE RESTRICT)."),
    "23514": (422, "Value rejected by a database CHECK constraint."),
    "23502": (422, "A required value is missing."),
    "22003": (422, "Numeric value out of range for the database column."),
    "22P02": (422, "Invalid value format."),
}


async def database_error_handler(request: Request, exc: psycopg.Error) -> JSONResponse:
    if isinstance(exc, psycopg.OperationalError):
        log.error("database unavailable: %s", exc)
        return JSONResponse(status_code=503, content={"detail": "Database unavailable."})

    sqlstate = exc.sqlstate
    constraint = exc.diag.constraint_name if exc.diag else None
    status, message = CONSTRAINT_MESSAGES.get((sqlstate, constraint)) or SQLSTATE_MESSAGES.get(
        sqlstate, (500, "Internal database error."))
    if status == 500:
        log.error("unexpected database error [%s]", sqlstate, exc_info=exc)
    body = {"detail": message, "sqlstate": sqlstate}
    if constraint:
        body["constraint"] = constraint
    return JSONResponse(status_code=status, content=body)
