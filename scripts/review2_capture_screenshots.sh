#!/usr/bin/env bash
# Take one REAL Terminal screenshot per Review 2 query: the query label, the
# SQL exactly as psql echoes it, and psql's own output, in one window.
# Run it yourself in Terminal.app (it captures the window it runs in):
#
#   cd "/Users/aditi/dbms project" && source .venv/bin/activate
#   bash scripts/review2_sandbox.sh                         # sandbox must exist
#   bash scripts/review2_capture_screenshots.sh             # all 61 queries
#   bash scripts/review2_capture_screenshots.sh B01 CQ03    # only these
#   bash scripts/review2_capture_screenshots.sh --from J01  # J01 to the end
#   bash scripts/review2_capture_screenshots.sh --click     # click the window for every shot
#                                                           # (other terminals, or if detection fails)
#
# Images: docs/review2/screenshots/<ID>.png (an existing image is replaced).
# Afterwards it runs the OCR check (review2_evidence.py verify-shots) and
# regenerates SCREENSHOT_MATRIX.md. A query is VERIFIED only after a person
# has also looked at the image:
#   python scripts/review2_evidence.py visual-ok B01 B02 --by "<name>"
#
# macOS asks once for Screen Recording permission for Terminal
# (System Settings > Privacy & Security > Screen & System Audio Recording).
# Nothing is written to the database: the 61 queries are SELECTs on the
# sandbox stock_watchlist_review2_sandbox.

set -euo pipefail

DB="stock_watchlist_review2_sandbox"
COLS=150 ROWS=42                    # fits every query (largest display: 36 lines x 143 columns)
PG_BIN="${PG_BIN:-/opt/homebrew/opt/postgresql@18/bin}"
export PATH="$PG_BIN:$PATH"
cd "$(dirname "$0")/.."
SHOTS="docs/review2/screenshots"
BIN="${TMPDIR:-/tmp}/review2_bin"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CLICK=0 FROM="" ONLY=()
for arg in "$@"; do
    case "$arg" in
        --click) CLICK=1 ;;
        --from)  FROM="__next__" ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) if [ "$FROM" = "__next__" ]; then FROM="$arg"; else ONLY+=("$arg"); fi ;;
    esac
done

if ! python -c "import psycopg" 2>/dev/null; then
    echo "Activate the virtual environment first: source .venv/bin/activate" >&2; exit 2
fi
if ! psql -X -q -At -d "$DB" -c "SELECT 1" >/dev/null 2>&1; then
    echo "Sandbox $DB not found: run  bash scripts/review2_sandbox.sh  first." >&2; exit 2
fi
if [ "$CLICK" -eq 0 ] && [ "${TERM_PROGRAM:-}" != "Apple_Terminal" ]; then
    echo "Run this in Terminal.app, or add --click to choose the window by clicking it." >&2; exit 2
fi

mkdir -p "$SHOTS" "$BIN"
if [ ! -x "$BIN/review2_window_id" ] || [ scripts/review2_window_id.swift -nt "$BIN/review2_window_id" ]; then
    echo "Compiling the window finder (once)..."
    swiftc -O scripts/review2_window_id.swift -o "$BIN/review2_window_id"
fi

ALL_IDS=$(python scripts/review2_evidence.py ids)
IDS=()
if [ "${#ONLY[@]}" -gt 0 ]; then
    for id in "${ONLY[@]}"; do
        grep -qx "$id" <<< "$ALL_IDS" || { echo "unknown query id: $id" >&2; exit 2; }
        IDS+=("$id")
    done
else
    started=$([ -z "$FROM" ] && echo 1 || echo 0)
    for id in $ALL_IDS; do
        [ "$id" = "$FROM" ] && started=1
        [ "$started" -eq 1 ] && IDS+=("$id")
    done
    [ "${#IDS[@]}" -gt 0 ] || { echo "unknown query id after --from: $FROM" >&2; exit 2; }
fi

printf '\033[8;%d;%dt' "$ROWS" "$COLS"      # ask Terminal for a COLS x ROWS window
sleep 0.6
if [ "$(tput cols)" -lt 144 ] || [ "$(tput lines)" -lt 38 ]; then
    echo "The window is $(tput cols) x $(tput lines); at least 144 x 38 is needed." >&2
    echo "Make the font smaller (Cmd -) or the window larger, then run again." >&2
    exit 2
fi

capture() {                                   # capture <file>
    if [ "$CLICK" -eq 1 ]; then
        screencapture -o -w "$1"              # click this terminal window
    else
        screencapture -x -o -l "$WID" "$1"
    fi
}

if [ "$CLICK" -eq 0 ]; then
    WID=$("$BIN/review2_window_id" Terminal) || {
        echo "Could not find the Terminal window; run again with --click." >&2; exit 2; }
fi

# Permission check: the first capture must contain this window's text.
clear
echo "Review 2 screenshot capture: checking Screen Recording permission (CAPTURECHECK)"
sleep 0.5
capture "$WORK/probe.png" || true
if [ ! -s "$WORK/probe.png" ] || ! python - "$WORK/probe.png" <<'EOF'
import sys
sys.path.insert(0, "scripts")
import review2_evidence as ev
text = " ".join(ev.ocr_images([sys.argv[1]]).get(sys.argv[1], []))
sys.exit(0 if "CAPTURECHECK" in text else 1)
EOF
then
    echo
    echo "The test capture does not show this window's text. Allow Terminal under"
    echo "System Settings > Privacy & Security > Screen & System Audio Recording,"
    echo "quit and reopen Terminal, then run this script again."
    exit 1
fi

n=0
for id in "${IDS[@]}"; do
    n=$((n + 1))
    sql="$WORK/$id.sql"
    src=$(python scripts/review2_evidence.py block "$id" --out "$sql")
    clear
    printf 'Review 2 | query %s | %s | database %s | %s\n' "$id" "$src" "$DB" "$(date '+%Y-%m-%d %H:%M')"
    printf 'command: psql -X -q -e -P pager=off -d %s -f %s.sql\n\n' "$DB" "$id"
    (cd "$WORK" && psql -X -q -e -P pager=off -d "$DB" -f "$id.sql")
    sleep 0.6
    capture "$SHOTS/$id.png"
    [ -s "$SHOTS/$id.png" ] || { echo "capture failed for $id" >&2; exit 1; }
done

clear
echo "Captured ${#IDS[@]} screenshot(s) in $SHOTS. Running the OCR check..."
python scripts/review2_evidence.py verify-shots --db "$DB"
echo
echo "Next: open each image, and record what you checked, for example"
echo "  python scripts/review2_evidence.py visual-ok ${IDS[0]} --by \"<your name>\""
echo "  python scripts/review2_evidence.py visual-ok ${IDS[0]} --by \"<your name>\" --result REDO --note \"cut off\""
