<#
    clipwarp installer.

    Works two ways:
      * One-command (remote):  irm https://raw.githubusercontent.com/botnick/clipwarp/main/install.ps1 | iex
      * From a clone:          git clone https://github.com/botnick/clipwarp; .\clipwarp\install.ps1

    Installs clipwarp.ps1, clipwarp-watch.ps1 and uninstall.ps1 to
    %USERPROFILE%\.claude\scripts and registers a `clipwarp` function (+ `cw`
    alias) in the all-hosts profile of BOTH PowerShell editions. Idempotent, and
    failure-atomic: a mid-way failure rolls back so you never get a half-updated
    (mixed-version) install.
#>

# GitHub's raw host requires TLS 1.2 on Windows PowerShell 5.1.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$RawBaseUrl = if ($env:CLIPWARP_RAW_BASE) { $env:CLIPWARP_RAW_BASE } else { 'https://raw.githubusercontent.com/botnick/clipwarp/main' }
$scriptsDir = Join-Path $HOME '.claude\scripts'

# Detect a file's encoding from its BOM so an existing profile is rewritten
# unchanged (never flatten a UTF-16/BOM profile to UTF-8). Defaults to UTF-8 no BOM.
function Get-FileEncoding([string]$Path) {
    try { $b = [System.IO.File]::ReadAllBytes($Path) } catch { return (New-Object System.Text.UTF8Encoding($false)) }
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { return (New-Object System.Text.UTF8Encoding($true)) }
    if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { return [System.Text.Encoding]::Unicode }
    if ($b.Length -ge 2 -and $b[0] -eq 0xFE -and $b[1] -eq 0xFF) { return [System.Text.Encoding]::BigEndianUnicode }
    return (New-Object System.Text.UTF8Encoding($false))
}

# --- 1. Install the scripts: stage all to temp, then swap in with backup+rollback. ---
$files   = @('clipwarp.ps1', 'clipwarp-watch.ps1', 'uninstall.ps1')
$staged  = @{}
$backups = @{}
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
        $target = Join-Path $scriptsDir $name
        if (Test-Path -LiteralPath $target) {
            Copy-Item -LiteralPath $target -Destination "$target.bak" -Force -ErrorAction Stop
            $backups[$name] = "$target.bak"
        }
        Move-Item -LiteralPath $staged[$name] -Destination $target -Force -ErrorAction Stop
        Write-Host "installed $name" -ForegroundColor Green
    }
    foreach ($b in $backups.Values) { Remove-Item -LiteralPath $b -Force -ErrorAction SilentlyContinue }
}
catch {
    $err = $_.Exception.Message
    foreach ($name in $backups.Keys) {
        Move-Item -LiteralPath $backups[$name] -Destination (Join-Path $scriptsDir $name) -Force -ErrorAction SilentlyContinue
    }
    foreach ($t in $staged.Values) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue }
    Write-Host "clipwarp: install failed - $err. Rolled back; no files were changed." -ForegroundColor Red
    exit 1
}

# --- 2. Register the `clipwarp` function in BOTH editions' all-hosts profiles. ---
$startMark = '# >>> clipwarp (Claude Code image paste helper) >>>'
$block = @"

$startMark
function clipwarp { & "`$HOME\.claude\scripts\clipwarp.ps1" @args }
Set-Alias cw clipwarp
# <<< clipwarp <<<
"@

$cur = $PROFILE.CurrentUserAllHosts
$profilePaths = @($cur)
if     ($cur -match '\\WindowsPowerShell\\profile\.ps1$') { $profilePaths += ($cur -replace '\\WindowsPowerShell\\profile\.ps1$', '\PowerShell\profile.ps1') }
elseif ($cur -match '\\PowerShell\\profile\.ps1$')        { $profilePaths += ($cur -replace '\\PowerShell\\profile\.ps1$', '\WindowsPowerShell\profile.ps1') }
$profilePaths = $profilePaths | Select-Object -Unique

$profileFailures = @()
foreach ($profilePath in $profilePaths) {
    try {
        $profileDir = Split-Path $profilePath
        if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Force -Path $profileDir -ErrorAction Stop | Out-Null }
        $existed = Test-Path -LiteralPath $profilePath
        $content = if ($existed) { [System.IO.File]::ReadAllText($profilePath) } else { '' }
        if ($content.Contains($startMark)) {
            Write-Host "profile already registers clipwarp -> $profilePath" -ForegroundColor DarkGray
            continue
        }
        $enc = if ($existed -and $content.Length -gt 0) { Get-FileEncoding $profilePath } else { New-Object System.Text.UTF8Encoding($false) }
        [System.IO.File]::WriteAllText($profilePath, ($content + $block), $enc)
        Write-Host "registered clipwarp function -> $profilePath" -ForegroundColor Green
    }
    catch { $profileFailures += "${profilePath}: $($_.Exception.Message)" }
}

# --- 3. Load into the current session so it works immediately. ---
try { . $cur } catch {}

# --- 4. If a watcher was already running (an update), restart it on the new script. ---
$installedWatch = Join-Path $scriptsDir 'clipwarp-watch.ps1'
& $installedWatch -Status *> $null
if ($LASTEXITCODE -eq 0) {
    & $installedWatch -Stop *> $null
    & $installedWatch     *> $null
    Write-Host "restarted the running watcher on the updated version" -ForegroundColor Green
}

Write-Host ""
if ($profileFailures.Count -gt 0) {
    Write-Host "clipwarp: some profiles could not be updated:" -ForegroundColor Yellow
    $profileFailures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    if ($profileFailures -match [regex]::Escape($cur)) {
        Write-Host "The 'clipwarp' command may be unavailable in this edition until that profile is fixed." -ForegroundColor Yellow
        exit 1
    }
}

Write-Host "clipwarp installed. Usage:" -ForegroundColor Cyan
Write-Host "  1) snip or Ctrl+C an image anywhere (Win+Shift+S, Lightshot, browser...)"
Write-Host "  2) run             clipwarp   (or just: cw)"
Write-Host "  3) in Claude Code  press Ctrl+V"
Write-Host ""
Write-Host "Auto mode (no step 2): run 'clipwarp watch' once - then plain Ctrl+C -> Ctrl+V." -ForegroundColor Cyan
Write-Host ""
Write-Host "Open a NEW terminal (or run '. `$PROFILE') if 'clipwarp' isn't found yet." -ForegroundColor DarkGray
