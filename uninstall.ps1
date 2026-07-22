<#
    clipwarp uninstaller. Removes the script, the profile function, and (optionally)
    the saved-images folder. Run:  .\uninstall.ps1  [-PurgeImages]
#>
[CmdletBinding()]
param([switch]$PurgeImages)

# Stop the watcher daemon if it is running.
$watchScript = Join-Path $HOME '.claude\scripts\clipwarp-watch.ps1'
if (Test-Path -LiteralPath $watchScript) {
    try { & $watchScript -Stop | Out-Null } catch {}
}

foreach ($name in @('clipwarp.ps1', 'clipwarp-watch.ps1', 'clipwarp-watch.pid', 'clipwarp-watch.log')) {
    $target = Join-Path $HOME ".claude\scripts\$name"
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Force
        Write-Host "removed $target" -ForegroundColor Green
    }
}

$profilePath = $PROFILE.CurrentUserAllHosts
if (Test-Path -LiteralPath $profilePath) {
    $lines = Get-Content -LiteralPath $profilePath
    # Strip the marked block (from the >>> marker line to the <<< closer, inclusive).
    $kept = @()
    $skip = $false
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
