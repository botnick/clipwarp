<#
    clipwarp installer.

    Works two ways:
      * One-command (remote):  irm https://raw.githubusercontent.com/botnick/clipwarp/main/install.ps1 | iex
      * From a clone:          git clone https://github.com/botnick/clipwarp; .\clipwarp\install.ps1

    It installs clipwarp.ps1 to %USERPROFILE%\.claude\scripts and registers a
    `clipwarp` function in your all-hosts PowerShell profile so you can call it
    from any terminal. Idempotent: safe to re-run to update.
#>

# GitHub's raw host requires TLS 1.2 on Windows PowerShell 5.1.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$RawBaseUrl = if ($env:CLIPWARP_RAW_BASE) { $env:CLIPWARP_RAW_BASE } else { 'https://raw.githubusercontent.com/botnick/clipwarp/main' }

$scriptsDir = Join-Path $HOME '.claude\scripts'

# Stage every script to a temp file FIRST, then replace them together. A failed
# download/copy therefore aborts BEFORE touching the live install, so it can never
# be left half-updated (a mixed-version install).
$files  = @('clipwarp.ps1', 'clipwarp-watch.ps1', 'uninstall.ps1')
$staged = @{}
try {
    New-Item -ItemType Directory -Force -Path $scriptsDir -ErrorAction Stop | Out-Null
    foreach ($name in $files) {
        $tmp = Join-Path $scriptsDir ".$name.download"
        $localSrc = if ($PSScriptRoot) { Join-Path $PSScriptRoot $name } else { $null }
        if ($localSrc -and (Test-Path -LiteralPath $localSrc)) {
            Copy-Item -LiteralPath $localSrc -Destination $tmp -Force -ErrorAction Stop
        }
        else {
            Invoke-WebRequest -Uri "$RawBaseUrl/$name" -OutFile $tmp -UseBasicParsing -ErrorAction Stop
        }
        $staged[$name] = $tmp
    }
    foreach ($name in $files) {
        Move-Item -LiteralPath $staged[$name] -Destination (Join-Path $scriptsDir $name) -Force -ErrorAction Stop
        Write-Host "installed $name" -ForegroundColor Green
    }
}
catch {
    foreach ($t in $staged.Values) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue }
    Write-Host "clipwarp: install failed - $($_.Exception.Message). No files were changed." -ForegroundColor Red
    exit 1
}

# Register the `clipwarp` function in the all-hosts profile of BOTH PowerShell
# editions (Windows PowerShell 5.1 and PowerShell 7), so the command works no
# matter which edition ran the installer or which one you open later. Their
# CurrentUserAllHosts profiles live in sibling folders (WindowsPowerShell vs
# PowerShell) under the same Documents root.
$marker = '# >>> clipwarp (Claude Code image paste helper) >>>'
$block  = @"

$marker
function clipwarp { & "`$HOME\.claude\scripts\clipwarp.ps1" @args }
Set-Alias cw clipwarp
# <<< clipwarp <<<
"@

$cur = $PROFILE.CurrentUserAllHosts
$profilePaths = @($cur)
if     ($cur -match '\\WindowsPowerShell\\profile\.ps1$') { $profilePaths += ($cur -replace '\\WindowsPowerShell\\profile\.ps1$', '\PowerShell\profile.ps1') }
elseif ($cur -match '\\PowerShell\\profile\.ps1$')        { $profilePaths += ($cur -replace '\\PowerShell\\profile\.ps1$', '\WindowsPowerShell\profile.ps1') }
$profilePaths = $profilePaths | Select-Object -Unique

foreach ($profilePath in $profilePaths) {
    try {
        $profileDir = Split-Path $profilePath
        if (-not (Test-Path $profileDir))  { New-Item -ItemType Directory -Force -Path $profileDir -ErrorAction Stop | Out-Null }
        if (-not (Test-Path $profilePath)) { New-Item -ItemType File -Path $profilePath -ErrorAction Stop | Out-Null }
        $content = Get-Content -LiteralPath $profilePath -Raw -ErrorAction SilentlyContinue
        if ($content -and $content.Contains($marker)) {
            Write-Host "profile already registers clipwarp -> $profilePath" -ForegroundColor DarkGray
        }
        else {
            Add-Content -LiteralPath $profilePath -Value $block -Encoding UTF8 -ErrorAction Stop
            Write-Host "registered clipwarp function -> $profilePath" -ForegroundColor Green
        }
    }
    catch { Write-Host "clipwarp: could not update profile $profilePath - $($_.Exception.Message)" -ForegroundColor Yellow }
}

# Load into the current session so it works immediately.
try { . $cur } catch {}

Write-Host ""
Write-Host "clipwarp installed. Usage:" -ForegroundColor Cyan
Write-Host "  1) snip or Ctrl+C an image anywhere (Win+Shift+S, Lightshot, browser...)"
Write-Host "  2) run             clipwarp   (or just: cw)"
Write-Host "  3) in Claude Code  press Ctrl+V"
Write-Host ""
Write-Host "Auto mode (no step 2): run 'clipwarp watch' once - then plain Ctrl+C -> Ctrl+V." -ForegroundColor Cyan
Write-Host ""
Write-Host "Open a NEW terminal (or run '. `$PROFILE') if 'clipwarp' isn't found yet." -ForegroundColor DarkGray
