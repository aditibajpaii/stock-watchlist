# take_screenshots.ps1 - real psql console screenshots for the Review 2 report.
#
# For every file in sql/screenshots/ (in number order) this opens a real
# console window (conhost + cmd), runs psql on that file, captures the
# window as a PNG in docs/screenshots/, and closes it. Step 024 runs the
# replay feed instead of a SQL file. Nothing is rendered or edited: each
# image is exactly what the console showed.
#
# WARNING: step 000 REBUILDS the dev database stock_watchlist (drops the
# 7 tables, then 002-012 recreate them, load the seed, functions, index and
# Review 2 objects). Every write demo afterwards is either rolled back or
# undone again (M01-M03), so it ends as: seed + replay (30 ticks, 8 alerts).
# Steps 111-113 need the benchmark DB: python tests/benchmark_indexes.py
#
# Run (Windows PowerShell, project root):
#   powershell -ExecutionPolicy Bypass -File scripts/take_screenshots.ps1
#   ... -Only "0[4-6]*"       # retake some (skips the rebuild unless 0* included)
# Connection: PGHOST/PGPORT/PGUSER below; password from the libpq pgpass file
# (%APPDATA%\postgresql\pgpass.conf). No password in this file.
param(
    [string]$Only = "*",
    [int]$Cols = 200,
    [int]$Lines = 62
)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$SqlDir = Join-Path $Root "sql\screenshots"
$OutDir = Join-Path $Root "docs\screenshots"
$PgBin = if ($env:PG_BIN_WIN) { $env:PG_BIN_WIN } else { "C:\Program Files\PostgreSQL\18\bin" }
$Psql = Join-Path $PgBin "psql.exe"
if (-not $env:PGHOST) { $env:PGHOST = "localhost" }
if (-not $env:PGPORT) { $env:PGPORT = "5432" }
if (-not $env:PGUSER) { $env:PGUSER = "postgres" }
$env:PGCLIENTENCODING = "UTF8"
New-Item -ItemType Directory -Force $OutDir | Out-Null

Add-Type -ReferencedAssemblies System.Drawing @"
using System; using System.Drawing; using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class Snap {
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  struct RECT { public int L, T, R, B; }
  struct POINT { public int X, Y; }

  // Captures the console's client area (the text, no title bar) and crops the
  // empty background below / to the right of the last character.
  public static string Save(IntPtr h, string path) {
    RECT w; GetWindowRect(h, out w);
    RECT c; GetClientRect(h, out c);
    POINT o = new POINT(); ClientToScreen(h, ref o);
    int ox = o.X - w.L, oy = o.Y - w.T;
    using (Bitmap full = new Bitmap(w.R - w.L, w.B - w.T, PixelFormat.Format32bppArgb)) {
      using (Graphics g = Graphics.FromImage(full)) {
        IntPtr dc = g.GetHdc(); PrintWindow(h, dc, 2); g.ReleaseHdc(dc);
      }
      Rectangle client = new Rectangle(ox, oy, c.R, c.B);
      int lastY = 0, lastX = 0;
      for (int y = client.Top; y < client.Bottom; y++)
        for (int x = client.Left; x < client.Right; x++) {
          Color p = full.GetPixel(x, y);
          if (p.R + p.G + p.B < 360) { if (y > lastY) lastY = y; if (x > lastX) lastX = x; }
        }
      int width  = Math.Min(client.Width,  Math.Max(lastX - client.Left + 28, 640));
      int height = Math.Min(client.Height, lastY - client.Top + 16);
      bool full_height = (lastY - client.Top) > client.Height - 40;
      using (Bitmap crop = full.Clone(new Rectangle(client.Left, client.Top, width, height), full.PixelFormat))
        crop.Save(path, ImageFormat.Png);
      return width + "x" + height + (full_height ? "  WARNING: window full, top may be scrolled off" : "");
    }
  }
}
"@
[Snap]::SetProcessDPIAware() | Out-Null

function Invoke-Capture([string]$Name, [string]$Shown, [string]$Run) {
    $title = "psql - $Name"
    $marker = Join-Path $env:TEMP ("sscap_" + [guid]::NewGuid().ToString("N") + ".done")
    $cmd = "chcp 65001 >nul & title $title& mode con cols=$Cols lines=$Lines & color F0 & cls & " +
           "echo %CD%^> $Shown& echo.& $Run & type nul > `"$marker`""
    $p = Start-Process conhost.exe -ArgumentList "cmd.exe /k $cmd" -WorkingDirectory $Root -PassThru
    for ($i = 0; $i -lt 600 -and -not (Test-Path $marker); $i++) { Start-Sleep -Milliseconds 100 }
    Start-Sleep -Milliseconds 800
    $wp = Get-Process cmd -ErrorAction SilentlyContinue |
          Where-Object { $_.MainWindowTitle -like "$title*" } | Select-Object -First 1
    if (-not $wp) { Write-Warning "$Name : window not found"; return }
    $png = Join-Path $OutDir "$Name.png"
    $info = [Snap]::Save($wp.MainWindowHandle, $png)
    "{0,-48} {1}" -f "$Name.png", $info
    Stop-Process -Id $wp.Id -ErrorAction SilentlyContinue
    Stop-Process -Id $p.Id -ErrorAction SilentlyContinue
    Remove-Item $marker -ErrorAction SilentlyContinue
}

$steps = Get-ChildItem $SqlDir -Filter "*.sql" | Sort-Object Name | ForEach-Object { $_.BaseName }
$steps = @($steps) + @("024_R01_replay_run") | Sort-Object
$selected = $steps | Where-Object { $_ -like $Only }

if ($selected | Where-Object { $_ -like "002_*" }) {
    "Rebuilding stock_watchlist: dropping the 7 tables and schema reporting ..."
    & $Psql -X -q -d stock_watchlist -v ON_ERROR_STOP=1 -c "SET client_min_messages=warning; DROP SCHEMA IF EXISTS reporting CASCADE; DROP TABLE IF EXISTS alert_events, alert_rules, price_ticks, watchlist_items, watchlists, instruments, users CASCADE;"
    if ($LASTEXITCODE -ne 0) { throw "drop failed" }
}

foreach ($s in $selected) {
    if ($s -eq "024_R01_replay_run") {
        $line = ".venv\Scripts\python -m app.replay data\replay_prices.csv --run-id demo1"
        Invoke-Capture $s $line $line
        continue
    }
    $db = if ($s -match "^11[1-3]_") { "stock_watchlist_benchmark" } else { "stock_watchlist" }
    $shown = "psql -X -e -P pager=off -d $db -f sql\screenshots\$s.sql"
    $run = "`"$Psql`" -X -e -P pager=off -d $db -f sql\screenshots\$s.sql"
    Invoke-Capture $s $shown $run
}
"Done: $OutDir"
