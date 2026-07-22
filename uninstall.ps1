<#
    clipwarp uninstaller. Stops the watcher, removes its login-autostart shortcut,
    strips the profile function from both PowerShell editions, then deletes the
    installed scripts. Reports honestly if any step fails and keeps the scripts in
    place (so you can re-run) when profile cleanup didn't complete.

    Run:  .\uninstall.ps1  [-PurgeImages]
    If you installed with the one-liner, the uninstaller lives in your scripts
    folder:  & "$HOME\.claude\scripts\uninstall.ps1"
#>
[CmdletBinding()]
param([switch]$PurgeImages)

$scriptsDir  = Join-Path $HOME '.claude\scripts'
$watchScript = Join-Path $scriptsDir 'clipwarp-watch.ps1'
$pidFile     = Join-Path $scriptsDir 'clipwarp-watch.pid'
$startupLnk  = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\clipwarp-watch.lnk'
$problems    = @()

function Test-WatcherRunning {
    if (-not (Test-Path -LiteralPath $pidFile)) { return $false }
    $wp = 0
    if (-not [int]::TryParse((Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1), [ref]$wp)) { return $false }
    $p = Get-Process -Id $wp -ErrorAction SilentlyContinue
    return [bool]($p -and $p.ProcessName -match 'powershell|pwsh')
}

# 1. Stop the watcher and disable autostart (needs the watcher script present).
if (Test-Path -LiteralPath $watchScript) {
    try { & $watchScript -Stop        | Out-Null } catch { $problems += "stop watcher: $($_.Exception.Message)" }
    try { & $watchScript -NoAutostart | Out-Null } catch { $problems += "disable autostart: $($_.Exception.Message)" }
}
# Verify it actually stopped; force-kill by pid as a fallback.
if (Test-WatcherRunning) {
    $wp = 0
    if ([int]::TryParse((Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1), [ref]$wp)) {
        try { Stop-Process -Id $wp -Force -ErrorAction Stop } catch {}
    }
    if (Test-WatcherRunning) { $problems += "watcher is still running (pid file: $pidFile)" }
}

# 2. Remove the login-autostart shortcut directly (in case the script was gone).
if (Test-Path -LiteralPath $startupLnk) {
    try { Remove-Item -LiteralPath $startupLnk -Force -ErrorAction Stop; Write-Host "removed autostart shortcut -> $startupLnk" -ForegroundColor Green }
    catch { $problems += "remove autostart shortcut: $($_.Exception.Message)" }
}

# 3. Strip the marked block from BOTH editions' all-hosts profiles (install writes to both).
$cur = $PROFILE.CurrentUserAllHosts
$profilePaths = @($cur)
if     ($cur -match '\\WindowsPowerShell\\profile\.ps1$') { $profilePaths += ($cur -replace '\\WindowsPowerShell\\profile\.ps1$', '\PowerShell\profile.ps1') }
elseif ($cur -match '\\PowerShell\\profile\.ps1$')        { $profilePaths += ($cur -replace '\\PowerShell\\profile\.ps1$', '\WindowsPowerShell\profile.ps1') }
$profilePaths = $profilePaths | Select-Object -Unique

$profileClean = $true
foreach ($profilePath in $profilePaths) {
    if (-not (Test-Path -LiteralPath $profilePath)) { continue }
    try {
        $lines = Get-Content -LiteralPath $profilePath -ErrorAction Stop
        $kept = @(); $skip = $false
        foreach ($line in $lines) {
            if ($line -match '^\s*# >>> clipwarp') { $skip = $true; continue }
            if ($skip -and $line -match '^\s*# <<< clipwarp') { $skip = $false; continue }
            if (-not $skip) { $kept += $line }
        }
        Set-Content -LiteralPath $profilePath -Value $kept -Encoding UTF8 -ErrorAction Stop
        Write-Host "removed clipwarp function from $profilePath" -ForegroundColor Green
    }
    catch { $problems += "edit profile ${profilePath}: $($_.Exception.Message)"; $profileClean = $false }
}

# 4. Optionally purge saved images.
if ($PurgeImages) {
    $imgDir = Join-Path $HOME '.claude\pasted-images'
    if (Test-Path -LiteralPath $imgDir) {
        try { Remove-Item -LiteralPath $imgDir -Recurse -Force -ErrorAction Stop; Write-Host "purged $imgDir" -ForegroundColor Green }
        catch { $problems += "purge images: $($_.Exception.Message)" }
    }
}

# 5. Delete the installed scripts LAST — but only if the profile was cleaned, so a
#    failed profile edit still has a working `clipwarp` + an uninstaller to retry.
if ($profileClean) {
    foreach ($name in @('clipwarp.ps1', 'clipwarp-watch.ps1', 'clipwarp-watch.pid', 'clipwarp-watch.log')) {
        $t = Join-Path $scriptsDir $name
        if (Test-Path -LiteralPath $t) {
            try { Remove-Item -LiteralPath $t -Force -ErrorAction Stop; Write-Host "removed $t" -ForegroundColor Green }
            catch { $problems += "remove ${t}: $($_.Exception.Message)" }
        }
    }
    # Delete this uninstaller itself, absolutely last (best effort).
    $self = Join-Path $scriptsDir 'uninstall.ps1'
    if (Test-Path -LiteralPath $self) { Remove-Item -LiteralPath $self -Force -ErrorAction SilentlyContinue }
}
else {
    $problems += "profile cleanup failed - kept the installed scripts so you can re-run the uninstaller"
}

# 6. Honest final report.
if ($problems.Count -gt 0) {
    Write-Host ""
    Write-Host "clipwarp uninstall finished with problems:" -ForegroundColor Yellow
    $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    exit 1
}
Write-Host "clipwarp uninstalled cleanly. Open a new terminal to drop the function from your session." -ForegroundColor Cyan
