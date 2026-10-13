# Captures what the controller's wheel sends (read-only). Writes the result to Documents\StorioTV\wheel.txt
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
if (-not (Test-Path $adb)) { $adb = 'adb' }
$out = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'StorioTV\wheel.txt'
if (-not ((& $adb devices) -match "`tdevice")) { Write-Host 'Console not detected over ADB.' -ForegroundColor Red; Read-Host 'Press Enter to exit'; return }
"== WHEEL $(Get-Date)" | Out-File -Encoding utf8 $out
& $adb shell "getevent -lp" 2>&1 | Out-File -Append -Encoding utf8 $out
Write-Host 'Open DOOM on the console and start a game. Press Enter once you are in.' -ForegroundColor Yellow
Read-Host
& $adb logcat -c
foreach ($s in @('CLOCKWISE', 'COUNTERCLOCKWISE')) {
    Write-Host ''
    Write-Host "Press Enter, then for 6 seconds turn the wheel ONLY $s, slowly, about 5 clicks." -ForegroundColor Yellow
    Read-Host
    Write-Host '   Turn it now...' -ForegroundColor Cyan
    "== GETEVENT $s" | Out-File -Append -Encoding utf8 $out
    & $adb shell 'getevent -lt > /data/local/tmp/wheel_capture.txt & P=$!; sleep 6; kill $P' 2>&1 | Out-Null
    & $adb shell 'cat /data/local/tmp/wheel_capture.txt' 2>&1 | Where-Object { $_ -notmatch 'SYN_REPORT' } | Out-File -Append -Encoding utf8 $out
    "== DOOM $s" | Out-File -Append -Encoding utf8 $out
    & $adb logcat -d -s DOOM:I 2>&1 | Out-File -Append -Encoding utf8 $out
    & $adb logcat -c
    Write-Host '   Done.' -ForegroundColor Green
}
& $adb shell 'rm /data/local/tmp/wheel_capture.txt'
Write-Host ''
Write-Host "Finished: $out" -ForegroundColor Green
Read-Host 'Press Enter to exit'
