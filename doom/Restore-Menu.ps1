# Puts the desktop back the way it was before Add-To-Menu.ps1, by restoring the database backup.
param([string]$Backup = "")
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
if (-not (Test-Path $adb)) { $adb = 'adb' }
$work = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'StorioTV\menu'
if (-not $Backup) {
    $f = Get-ChildItem -Path $work -Filter 'fakeapp_*.db' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1
    if (-not $f) { Write-Host 'No backup found in Documents\StorioTV\menu.' -ForegroundColor Red; return }
    $Backup = $f.FullName
}
Write-Host "This will restore: $Backup (the oldest backup, from before the first change)" -ForegroundColor Yellow
if ((Read-Host 'Type YES to continue') -cne 'YES') { return }
$db = '/data/data/com.vtech.innotab.vpm/databases/fakeapp.db'
$owner = (& $adb shell "ls -ln $db") -split '\s+'
& $adb shell am force-stop com.vtech.innotab.TVDesktop
& $adb shell am force-stop com.vtech.innotab.vpm
& $adb push $Backup /data/local/tmp/fakeapp.db | Out-Null
& $adb shell "cat /data/local/tmp/fakeapp.db > $db && rm /data/local/tmp/fakeapp.db && rm -f $db-journal"
if ($owner.Count -gt 2) { & $adb shell "chown $($owner[1]):$($owner[2]) $db" }
& $adb shell "chmod 660 $db"
Write-Host 'Restored. Reboot the console.' -ForegroundColor Green
