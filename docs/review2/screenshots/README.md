# Query screenshots (one per query ID)

**Current status: none captured.** All 61 queries are PENDING (see `../SCREENSHOT_MATRIX.md`).

Only real screenshots of a terminal running psql go in this folder: images taken by
`scripts/review2_capture_screenshots.sh`, or taken by hand with the macOS screenshot tool. Never put an
image here that was produced any other way (for example, text rendered into a picture), and never edit
an image after capture.

## Take them

In **Terminal.app** (not the VS Code terminal):

```sh
cd "/Users/aditi/dbms project"
source .venv/bin/activate
bash scripts/review2_sandbox.sh                       # fresh sandbox (if it is not there)
bash scripts/review2_capture_screenshots.sh           # all 61, about 2 minutes
```

- The first run makes macOS ask for **Screen Recording** permission for Terminal. Allow it, quit and
  reopen Terminal, and run the script again. A test capture checks this before any real capture.
- The script resizes the window to 150 × 42 characters. The largest query needs 36 lines × 143
  columns, so every query fits one image with its label, its SQL and its full output, including the
  `(N rows)` line.
- For every query it clears the window and prints one header line (ID, source file and lines, database,
  time) and the exact psql command. It then runs psql live: psql echoes the SQL (`-e`) and prints the
  result. The window itself is then captured to `<ID>.png`. Nothing is typed or formatted by hand.
- Options: `B01 CQ03` (only these IDs), `--from J01` (resume), `--click` (click the window to capture,
  for another terminal app or if the window is not found).

## Check them

1. The script ends with the OCR check (`python scripts/review2_evidence.py verify-shots`). It reads
   every image with macOS text recognition and checks for the query label, the first SQL line, the
   column headings and the first result row. Results go to `ocr_check.json`, and
   `SCREENSHOT_MATRIX.md` is regenerated.
2. **Look at each image yourself.** Is the text sharp? Is anything cut off? Is it the right query?
   Then record it:

   ```sh
   python scripts/review2_evidence.py visual-ok B01 B02 B03 --by "Aditi"
   python scripts/review2_evidence.py visual-ok CQ07 --by "Aditi" --result REDO --note "label wrapped"
   python scripts/review2_evidence.py verify-shots      # refresh the matrix
   ```

   `VISUAL_CHECK.csv` stores the image's SHA-256. A re-captured image therefore needs a new check.
3. A query is **VERIFIED** only when the OCR check passed and a visual check of that exact file is
   recorded as OK.

## Naming

`<ID>.png`, for example `B01.png`, `AG04.png`, `CQ12.png`. If one query ever needs two images:
`<ID>_1.png`, `<ID>_2.png`. They are checked together.

IDs: B01–B07, AG01–AG06, J01–J07, S01–S11, SET01–SET05, F01–F08, W01–W05, CQ01–CQ12 (61).
