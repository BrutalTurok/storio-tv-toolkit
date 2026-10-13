# Saves the console log to diagnose problems with DOOM.
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
if (-not (Test-Path $adb)) { $adb = 'adb' }
$f = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'StorioTV\doom_log.txt'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $f) | Out-Null
& $adb logcat -d -v time *>&1 | Out-File -Encoding utf8 $f
Write-Host "Saved to $f" -ForegroundColor Green
