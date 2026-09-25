"""Database connection settings, read from environment variables.

No passwords live in code. Unset variables fall back to libpq defaults
(local Unix socket, port 5432, current OS user), which is how the local
Homebrew PostgreSQL server is reached. libpq itself still honours
PGPASSWORD / ~/.pgpass if a password is ever needed.
"""

import os

from psycopg.conninfo import make_conninfo

DEFAULT_DB_NAME = "stock_watchlist"


def conninfo() -> str:
    """Build a libpq connection string from DB_NAME/DB_HOST/DB_PORT/DB_USER."""
    settings = {
        "dbname": os.environ.get("DB_NAME", DEFAULT_DB_NAME),
        "host": os.environ.get("DB_HOST"),
        "port": os.environ.get("DB_PORT"),
        "user": os.environ.get("DB_USER"),
    }
    return make_conninfo(**{k: v for k, v in settings.items() if v})
