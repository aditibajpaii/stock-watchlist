# review3_capture.ps1 - capture ONE real console window as a PNG (Review 3 evidence).
#
# Opens a console (conhost + cmd), prints the command line, runs it, saves the
# console's text area as <OutDir>\<Name>.png and closes the window. Same capture
# method as scripts/take_screenshots.ps1; nothing is edited or rendered.
#
#   powershell -ExecutionPolicy Bypass -File scripts/review3_capture.ps1 `
#       -Name R3_04_all_tests -Shown "bash scripts/run_all_tests.sh" `
#       -Run "bash scripts/run_all_tests.sh" -WorkDir . -OutDir docs\review3\screenshots
#
# Environment (PGHOST, PGPORT, PGUSER, PATH, DB_NAME ...) is inherited from the caller.
param(
    [Parameter(Mandatory)] [string]$Name,
    [Parameter(Mandatory)] [string]$Shown,
    [Parameter(Mandatory)] [string]$Run,
    [string]$WorkDir = (Get-Location).Path,
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) "docs\review3\screenshots"),
    [int]$Cols = 160,
    [int]$Lines = 50,
    [string]$Prompt = "stock-watchlist"
)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force $OutDir | Out-Null

Add-Type -ReferencedAssemblies System.Drawing @"
using System; using System.Drawing; using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class Snap3 {
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  struct RECT { public int L, T, R, B; }
  struct POINT { public int X, Y; }
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
      using (Bitmap crop = full.Clone(new Rectangle(client.Left, client.Top, width, height), full.PixelFormat))
        crop.Save(path, ImageFormat.Png);
      return width + "x" + height;
    }
  }
}
"@
[Snap3]::SetProcessDPIAware() | Out-Null

$title = "capture - $Name"
$marker = Join-Path $env:TEMP ("r3cap_" + [guid]::NewGuid().ToString("N") + ".done")
$env:PROMPT = "$Prompt`$G "
$cmd = "chcp 65001 >nul & title $title& mode con cols=$Cols lines=$Lines & color F0 & cls & " +
       "echo $Prompt^> $Shown& echo.& $Run & type nul > `"$marker`""
$p = Start-Process conhost.exe -ArgumentList "cmd.exe /k $cmd" -WorkingDirectory $WorkDir -PassThru
for ($i = 0; $i -lt 1800 -and -not (Test-Path $marker); $i++) { Start-Sleep -Milliseconds 100 }
Start-Sleep -Milliseconds 800
$wp = Get-Process cmd -ErrorAction SilentlyContinue |
      Where-Object { $_.MainWindowTitle -like "$title*" } | Select-Object -First 1
if (-not $wp) { throw "$Name : window not found" }
$png = Join-Path $OutDir "$Name.png"
"{0,-40} {1}" -f "$Name.png", ([Snap3]::Save($wp.MainWindowHandle, $png))
Stop-Process -Id $wp.Id -ErrorAction SilentlyContinue
Stop-Process -Id $p.Id -ErrorAction SilentlyContinue
Remove-Item $marker -ErrorAction SilentlyContinue
