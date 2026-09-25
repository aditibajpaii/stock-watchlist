"""Database access for the API: one short-lived connection per request.

Connections are opened in AUTOCOMMIT mode, so a single SELECT is its own
transaction. Anything that must be atomic (every write, and reads that run
several queries) is wrapped explicitly:

    with conn.transaction():
        ...            # COMMIT on success, ROLLBACK if an exception escapes

No connection is shared between requests.
"""

from collections.abc import Iterator

import psycopg
from psycopg.rows import dict_row

from app.config import conninfo


def connect(**kwargs) -> psycopg.Connection:
    return psycopg.connect(conninfo(), autocommit=True, row_factory=dict_row, **kwargs)


def get_conn() -> Iterator[psycopg.Connection]:
    """FastAPI dependency: open a connection for this request, close it after."""
    with connect() as conn:
        yield conn
