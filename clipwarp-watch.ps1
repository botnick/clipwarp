<#
.SYNOPSIS
    clipwarp-watch - background clipboard watcher for clipwarp.

.DESCRIPTION
    Listens for clipboard changes (WM_CLIPBOARDUPDATE). Whenever an image lands
    on the clipboard - from ANY app: Snipping Tool, Lightshot, a browser's
    "copy image", Ctrl+C on an image file - it runs clipwarp.ps1 -KeepImage, which
    rewrites the clipboard as DUAL format:

        text  = the saved PNG's path   -> Ctrl+V in Claude Code attaches the image
        image = the original bitmap    -> Ctrl+V in Photoshop/Word still pastes the image

    So with the watcher running the flow is just: Ctrl+C anywhere -> Ctrl+V in
    Claude Code. No manual clipwarp step.

    Clipboards that carry meaningful TEXT alongside an image (e.g. copying a
    paragraph in Word) are left untouched - only pure image copies convert.

.USAGE
    clipwarp watch      # start (detached, hidden)
    clipwarp status     # is it running?
    clipwarp stop       # stop
#>
[CmdletBinding()]
param(
    [switch]$Stop,
    [switch]$Status,
    [switch]$Autostart,    # register a login shortcut so the watcher starts at sign-in
    [switch]$NoAutostart,  # remove that login shortcut
    [switch]$Daemon        # internal: run the listener loop in THIS process
)

$scriptsDir = Join-Path $env:USERPROFILE '.claude\scripts'
$pidFile    = Join-Path $scriptsDir 'clipwarp-watch.pid'
$logFile    = Join-Path $scriptsDir 'clipwarp-watch.log'
$clipwarpPath  = Join-Path $PSScriptRoot 'clipwarp.ps1'
$startupLnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\clipwarp-watch.lnk'

function Get-WatchProcess {
    if (-not (Test-Path -LiteralPath $pidFile)) { return $null }
    $watchPid = 0
    if (-not [int]::TryParse((Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1), [ref]$watchPid)) { return $null }
    $proc = Get-Process -Id $watchPid -ErrorAction SilentlyContinue
    if ($proc -and $proc.ProcessName -match 'powershell|pwsh') { return $proc }
    return $null
}

if ($Autostart) {
    try {
        $sh = New-Object -ComObject WScript.Shell
        $s  = $sh.CreateShortcut($startupLnk)
        $s.TargetPath  = 'powershell.exe'
        $s.Arguments   = "-NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" -Daemon"
        $s.WindowStyle = 7                                   # minimized/hidden
        $s.Description  = 'clipwarp clipboard-image watcher for Claude Code'
        $s.Save()
        Write-Host "clipwarp watch: autostart enabled -> $startupLnk" -ForegroundColor Green
        exit 0
    } catch {
        Write-Host "clipwarp watch: failed to enable autostart - $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

if ($NoAutostart) {
    Remove-Item -LiteralPath $startupLnk -Force -ErrorAction SilentlyContinue
    Write-Host 'clipwarp watch: autostart disabled' -ForegroundColor Green
    exit 0
}

if ($Status) {
    $proc = Get-WatchProcess
    $auto = if (Test-Path -LiteralPath $startupLnk) { 'on' } else { 'off' }
    if ($proc) { Write-Host "clipwarp watch: running (pid $($proc.Id)) - autostart $auto" -ForegroundColor Green; exit 0 }
    Write-Host "clipwarp watch: not running - autostart $auto" -ForegroundColor Yellow
    exit 1
}

if ($Stop) {
    $proc = Get-WatchProcess
    if ($proc) {
        Stop-Process -Id $proc.Id -Force
        Write-Host "clipwarp watch: stopped (pid $($proc.Id))" -ForegroundColor Green
    }
    else { Write-Host 'clipwarp watch: not running' -ForegroundColor Yellow }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    exit 0
}

if (-not $Daemon) {
    # Start mode: spawn a hidden daemon and return.
    $proc = Get-WatchProcess
    if ($proc) { Write-Host "clipwarp watch: already running (pid $($proc.Id))" -ForegroundColor DarkGray; exit 0 }
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-Sta', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$($MyInvocation.MyCommand.Path)`"", '-Daemon'
    ) | Out-Null
    foreach ($i in 1..20) {
        Start-Sleep -Milliseconds 250
        $proc = Get-WatchProcess
        if ($proc) { break }
    }
    if ($proc) {
        Write-Host "clipwarp watch: started (pid $($proc.Id))" -ForegroundColor Green
        Write-Host 'copy an image anywhere (Ctrl+C / snip), then Ctrl+V in Claude Code.' -ForegroundColor Cyan
        Write-Host "stop with: clipwarp stop" -ForegroundColor DarkGray
        exit 0
    }
    Write-Host "clipwarp watch: failed to start (see $logFile)" -ForegroundColor Red
    exit 1
}

# ---------------- daemon mode ----------------

$mutex = New-Object System.Threading.Mutex($false, 'clipwarp-watch-singleton')
if (-not $mutex.WaitOne(0)) { exit 1 }   # another daemon already owns the clipboard watch

New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null
Set-Content -LiteralPath $pidFile -Value $PID

Add-Type -AssemblyName System.Windows.Forms

$src = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace ClipwarpWatch
{
    public class Watcher : NativeWindow
    {
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool AddClipboardFormatListener(IntPtr hwnd);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RemoveClipboardFormatListener(IntPtr hwnd);

        private const int WM_CLIPBOARDUPDATE = 0x031D;
        private static readonly Regex ImgExt = new Regex(@"\.(png|jpe?g|gif|webp|bmp)$", RegexOptions.IgnoreCase);

        private readonly string scriptPath;
        private readonly string logPath;
        private readonly Timer debounce;
        private System.Diagnostics.Process child;
        private DateTime childStarted;
        private const int ChildTimeoutSec = 15;   // a conversion that runs longer is treated as hung
        private int busyRetries;                  // consecutive "clipboard busy" re-arms in this burst

        // Re-check soon instead of dropping the event (clipboard was busy, or a
        // conversion is still running). Bounded so a permanently-locked clipboard
        // can't spin forever - a genuinely new copy will re-fire the listener.
        private void Rearm()
        {
            if (++busyRetries > 20) { busyRetries = 0; debounce.Interval = 300; return; }
            debounce.Interval = Math.Min(300 + busyRetries * 150, 2000);
            debounce.Start();
        }

        public Watcher(string script, string log)
        {
            scriptPath = script;
            logPath = log;
            CreateParams cp = new CreateParams();
            cp.Parent = (IntPtr)(-3);              // HWND_MESSAGE: message-only window
            CreateHandle(cp);
            AddClipboardFormatListener(this.Handle);
            debounce = new Timer();
            debounce.Interval = 300;               // coalesce the bursts some apps fire per copy
            debounce.Tick += OnTick;
            Log("watch started, pid " + System.Diagnostics.Process.GetCurrentProcess().Id);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_CLIPBOARDUPDATE)
            {
                // A genuinely new clipboard change: give it a full, fresh retry
                // budget (don't inherit a previous burst's exhausted counter).
                busyRetries = 0;
                debounce.Interval = 300;
                debounce.Stop();
                debounce.Start();
            }
            base.WndProc(ref m);
        }

        private void OnTick(object sender, EventArgs e)
        {
            debounce.Stop();
            try { Inspect(); }
            catch (Exception ex) { Log("error: " + ex.Message); }
        }

        private void Inspect()
        {
            // A conversion is already in flight - unless it has hung past the
            // timeout, in which case reap it so the watcher never wedges.
            if (child != null && !child.HasExited)
            {
                if ((DateTime.Now - childStarted).TotalSeconds < ChildTimeoutSec)
                {
                    // Waiting on the in-flight conversion is NOT the clipboard-busy
                    // budget: poll on the base interval until the child finishes
                    // (bounded by ChildTimeoutSec, after which it is killed above).
                    debounce.Interval = 300;
                    debounce.Start();
                    return;
                }
                try { child.Kill(); } catch { }
                Log("previous conversion hung -> killed");
            }

            string txt = null;
            try { if (Clipboard.ContainsText()) txt = Clipboard.GetText(); }
            catch { Rearm(); return; }                         // clipboard busy -> retry soon, don't drop it
            if (!string.IsNullOrEmpty(txt))
            {
                string p = txt.Trim().Trim('"');
                if (ImgExt.IsMatch(p) && File.Exists(p)) { busyRetries = 0; debounce.Interval = 300; return; }  // our own write / usable path
                if (txt.Trim().Length > 0) { busyRetries = 0; debounce.Interval = 300; return; }                // rich text+image copy: leave it alone
            }

            int payload = HasImagePayload();
            if (payload < 0) { Rearm(); return; }              // clipboard busy -> retry soon
            if (payload == 0) { busyRetries = 0; debounce.Interval = 300; return; }

            busyRetries = 0; debounce.Interval = 300;
            var psi = new System.Diagnostics.ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = "-NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + scriptPath + "\" -Quiet -KeepImage";
            psi.CreateNoWindow = true;
            psi.UseShellExecute = false;
            child = System.Diagnostics.Process.Start(psi);
            childStarted = DateTime.Now;
            Log("image on clipboard -> converting");
        }

        // Tri-state: 1 = an image payload is present, 0 = none, -1 = clipboard
        // was busy (couldn't tell) so the caller should retry rather than drop.
        private int HasImagePayload()
        {
            IDataObject d = null;
            try { d = Clipboard.GetDataObject(); }
            catch { return -1; }
            if (d == null) return -1;
            try
            {
                if (d.GetDataPresent(DataFormats.Bitmap, true)) return 1;
                if (d.GetDataPresent("PNG") || d.GetDataPresent("image/png") || d.GetDataPresent("Format17")) return 1;
                if (d.GetDataPresent(DataFormats.FileDrop))
                {
                    string[] files = d.GetData(DataFormats.FileDrop) as string[];
                    if (files != null)
                        foreach (string f in files)
                            if (ImgExt.IsMatch(f)) return 1;
                }
                if (d.GetDataPresent(DataFormats.Html))
                {
                    string html = d.GetData(DataFormats.Html) as string;
                    if (html != null && html.IndexOf("data:image/", StringComparison.OrdinalIgnoreCase) >= 0) return 1;
                }
            }
            catch { return -1; }   // read raced with another writer; retry
            return 0;
        }

        public void Shutdown()
        {
            try { RemoveClipboardFormatListener(this.Handle); } catch { }
            Log("watch stopped");
        }

        private void Log(string msg)
        {
            try
            {
                if (File.Exists(logPath) && new FileInfo(logPath).Length > 200000) File.WriteAllText(logPath, "");
                File.AppendAllText(logPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + msg + Environment.NewLine);
            }
            catch { }
        }
    }
}
'@
Add-Type -TypeDefinition $src -ReferencedAssemblies @('System', 'System.Windows.Forms')

$watcher = New-Object ClipwarpWatch.Watcher($clipwarpPath, $logFile)
try {
    [System.Windows.Forms.Application]::Run()   # message pump; blocks until the process is killed
}
finally {
    $watcher.Shutdown()
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    $mutex.ReleaseMutex()
}
