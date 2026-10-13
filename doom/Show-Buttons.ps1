# Shows the code of each controller button while DOOM is running (Ctrl+C to quit).
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
if (-not (Test-Path $adb)) { $adb = 'adb' }
Write-Host 'Press the controller buttons with DOOM running. Ctrl+C to stop.' -ForegroundColor Cyan
& $adb logcat -c
& $adb logcat -s DOOM:I
