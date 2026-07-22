<#
    clipwarp uninstaller. Stops the watcher, removes its login-autostart shortcut,
    deletes the installed scripts, strips the profile function from both PowerShell
    editions, and (optionally) removes the saved-images folder.

    Run:  .\uninstall.ps1  [-PurgeImages]
    If you installed with the one-liner, the uninstaller lives in your scripts
    folder:  & "$HOME\.claude\scripts\uninstall.ps1"
#>
[CmdletBinding()]
param([switch]$PurgeImages)

$scriptsDir  = Join-Path $HOME '.claude\scripts'
$watchScript = Join-Path $scriptsDir 'clipwarp-watch.ps1'

# Stop the watcher and remove its login-autostart shortcut BEFORE deleting the
# watcher script (it owns the shortcut logic). Then delete the shortcut directly
# too, in case the script was already gone.
if (Test-Path -LiteralPath $watchScript) {
    try { & $watchScript -Stop        | Out-Null } catch {}
    try { & $watchScript -NoAutostart | Out-Null } catch {}
}
$startupLnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\clipwarp-watch.lnk'
if (Test-Path -LiteralPath $startupLnk) {
    Remove-Item -LiteralPath $startupLnk -Force -ErrorAction SilentlyContinue
    Write-Host "removed autostart shortcut -> $startupLnk" -ForegroundColor Green
}

foreach ($name in @('clipwarp.ps1', 'clipwarp-watch.ps1', 'clipwarp-watch.pid', 'clipwarp-watch.log', 'uninstall.ps1')) {
    $target = Join-Path $scriptsDir $name
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        Write-Host "removed $target" -ForegroundColor Green
    }
}

# Strip the marked block from BOTH editions' all-hosts profiles (install writes to both).
$cur = $PROFILE.CurrentUserAllHosts
$profilePaths = @($cur)
if     ($cur -match '\\WindowsPowerShell\\profile\.ps1$') { $profilePaths += ($cur -replace '\\WindowsPowerShell\\profile\.ps1$', '\PowerShell\profile.ps1') }
elseif ($cur -match '\\PowerShell\\profile\.ps1$')        { $profilePaths += ($cur -replace '\\PowerShell\\profile\.ps1$', '\WindowsPowerShell\profile.ps1') }
$profilePaths = $profilePaths | Select-Object -Unique

foreach ($profilePath in $profilePaths) {
    if (-not (Test-Path -LiteralPath $profilePath)) { continue }
    $lines = Get-Content -LiteralPath $profilePath
    $kept = @(); $skip = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*# >>> clipwarp') { $skip = $true; continue }
        if ($skip -and $line -match '^\s*# <<< clipwarp') { $skip = $false; continue }
        if (-not $skip) { $kept += $line }
    }
    Set-Content -LiteralPath $profilePath -Value $kept -Encoding UTF8
    Write-Host "removed clipwarp function from $profilePath" -ForegroundColor Green
}

if ($PurgeImages) {
    $imgDir = Join-Path $HOME '.claude\pasted-images'
    if (Test-Path -LiteralPath $imgDir) {
        Remove-Item -LiteralPath $imgDir -Recurse -Force
        Write-Host "purged $imgDir" -ForegroundColor Green
    }
}

Write-Host "clipwarp uninstalled. Open a new terminal to drop the function from your session." -ForegroundColor Cyan
