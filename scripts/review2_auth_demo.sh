#!/usr/bin/env bash
# Password-authenticated restricted login, proven on a THROWAWAY PostgreSQL
# server: its own data directory, its own port on 127.0.0.1, its own
# pg_hba.conf that demands a SCRAM-SHA-256 password for every connection.
# The classroom server, its pg_hba.conf, its roles and its databases are
# never touched.
#
#   source .venv/bin/activate
#   bash scripts/review2_auth_demo.sh          # writes docs/review2/sql_output/93_auth_demo.out
#   bash scripts/review2_auth_demo.sh --show   # same, and prints that output (for a screenshot)
#
# Passwords are random for each run, kept only in shell variables and in the
# environment of the processes that need them, never printed and never
# written into the repository. The temporary server is stopped and its data
# directory deleted when the script ends, also on failure.
#
# What the output shows:
#   1. the temporary server's authentication rules (pg_hba.conf)
#   2. no password            -> connection refused
#   3. wrong password         -> FATAL: password authentication failed
#   4. NOLOGIN role, correct password -> FATAL: role is not permitted to log in
#   5. correct password       -> session as r2_analyst (system_user shows
#      scram-sha-256), then the forbidden operations of 18_login_probe.sql fail
#      with "permission denied"

set -euo pipefail

PG_BIN="${PG_BIN:-/opt/homebrew/opt/postgresql@18/bin}"
export PATH="$PG_BIN:$PATH"
cd "$(dirname "$0")/.."

OUT="docs/review2/sql_output/93_auth_demo.out"
DB="stock_watchlist_review2_sandbox"      # same name, but on the temporary server
WORK="$(mktemp -d "${TMPDIR:-/tmp}/r2auth.XXXXXX")"
PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"

cleanup() {
    pg_ctl -D "$WORK/data" -m fast stop >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT
umask 077

if ! python -c "import psycopg" 2>/dev/null; then
    echo "ERROR: activate the virtual environment first: source .venv/bin/activate" >&2
    exit 2
fi

newpw() { python3 -c 'import secrets; print(secrets.token_urlsafe(24))'; }
ADMIN_PW="$(newpw)"; ANALYST_PW="$(newpw)"; SUPPORT_PW="$(newpw)"

echo "== temporary server in $WORK (port $PORT, 127.0.0.1 only)"
printf '%s\n' "$ADMIN_PW" > "$WORK/admin.pw"
initdb -D "$WORK/data" -U r2_admin --pwfile="$WORK/admin.pw" \
       --auth-local=scram-sha-256 --auth-host=scram-sha-256 \
       --encoding=UTF8 --locale=C >/dev/null
rm -f "$WORK/admin.pw"
pg_ctl -D "$WORK/data" -l "$WORK/server.log" -w \
       -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" start >/dev/null
export PGHOST=127.0.0.1 PGPORT="$PORT"
export PGPASSFILE="$WORK/no-pgpass"     # ignore any ~/.pgpass: only the passwords below count

admin() { PGPASSWORD="$ADMIN_PW" psql -X -q -w -v ON_ERROR_STOP=1 -P pager=off -U r2_admin "$@"; }

echo "== build the same schema, data and security objects there"
admin -d postgres -c "CREATE DATABASE $DB" >/dev/null
PGOPTIONS="-c client_min_messages=warning" admin -d "$DB" \
    -f sql/00_schema.sql -f sql/01_seed.sql -f sql/03_functions_triggers.sql -f sql/06_indexes.sql >/dev/null
DB_NAME="$DB" DB_HOST=127.0.0.1 DB_PORT="$PORT" DB_USER=r2_admin PGPASSWORD="$ADMIN_PW" \
    python -m app.replay data/replay_prices.csv --run-id r2auth >/dev/null
for f in 01_setup 12_views 13_procedures_functions 17_security; do
    admin -d "$DB" -f "sql/review2/$f.sql" >/dev/null 2>&1
done

# Passwords are read from the environment INSIDE psql (\getenv), so they
# never appear on a command line, in echoed SQL or in the output file.
set_password() {   # set_password <role> <password> <LOGIN|NOLOGIN>
    R2_PW="$2" PGPASSWORD="$ADMIN_PW" psql -X -q -w -v ON_ERROR_STOP=1 -U r2_admin -d "$DB" >/dev/null <<SQL
\getenv pw R2_PW
ALTER ROLE $1 $3 PASSWORD :'pw';
SQL
}
set_password r2_analyst "$ANALYST_PW" LOGIN
set_password r2_support "$SUPPORT_PW" NOLOGIN

attempt() {        # attempt <label> <expected psql exit> -- command...
    local label="$1" want="$2"; shift 3
    echo ">>> EXPECTED CONNECTION RESULT [$want]: $label"
    set +e; "$@" 2>&1; local got=$?; set -e
    echo "<<< psql exit code: $got"
    [ "$got" -eq "$want" ] || { echo "UNEXPECTED: exit $got, wanted $want"; FAILED=1; }
}
FAILED=0

{
    echo "===== 1. Authentication rules of the temporary server (pg_hba.conf, comments removed) ====="
    grep -vE '^[[:space:]]*(#|$)' "$WORK/data/pg_hba.conf"
    echo
    echo "===== Roles: r2_analyst may log in; r2_support has a password but NOLOGIN; passwords stored as SCRAM verifiers ====="
    admin -d "$DB" -c "SELECT rolname, rolcanlogin, rolsuper, split_part(rolpassword, '\$', 1) AS stored_password_format FROM pg_authid WHERE rolname IN ('r2_analyst', 'r2_support') ORDER BY rolname"
    echo
    echo "===== 2. No password ====="
    attempt "no password supplied -> refused" 2 -- env -u PGPASSWORD psql -X -w -U r2_analyst -d "$DB" -c "SELECT 1"
    echo
    echo "===== 3. Wrong password ====="
    attempt "wrong password -> FATAL password authentication failed" 2 -- \
        env PGPASSWORD="not-the-password" psql -X -w -U r2_analyst -d "$DB" -c "SELECT 1"
    echo
    echo "===== 4. Correct password, but the role is NOLOGIN ====="
    attempt "r2_support (NOLOGIN) -> FATAL role is not permitted to log in" 2 -- \
        env PGPASSWORD="$SUPPORT_PW" psql -X -w -U r2_support -d "$DB" -c "SELECT 1"
    echo
    echo "===== 5. Correct password: authenticated restricted session, then forbidden operations ====="
    attempt "r2_analyst with the correct password -> session opens; probe runs" 0 -- \
        env PGPASSWORD="$ANALYST_PW" psql -X -q -w -v ON_ERROR_STOP=1 -P pager=off -e \
            -U r2_analyst -d "$DB" -f sql/review2/18_login_probe.sql
} > "$OUT" 2>&1

# The output must not contain any of this run's passwords.
for pw in "$ADMIN_PW" "$ANALYST_PW" "$SUPPORT_PW"; do
    if grep -qF -- "$pw" "$OUT"; then echo "SECURITY CHECK FAILED: a password reached $OUT" >&2; rm -f "$OUT"; exit 1; fi
done
grep -q "scram-sha-256:r2_analyst" "$OUT" || { echo "authenticated identity not shown" >&2; FAILED=1; }

if [ "$FAILED" -ne 0 ]; then
    echo "AUTH DEMO FAILED - see $OUT" >&2
    exit 1
fi
echo "== wrote $OUT (no password inside); temporary server stopped and deleted"
if [ "${1:-}" = "--show" ]; then
    echo; cat "$OUT"
fi
