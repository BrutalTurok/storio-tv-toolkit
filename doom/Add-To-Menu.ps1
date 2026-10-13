# Adds DOOM to the Storio TV desktop using the developer route of the VTech package manager (VPM).
# It does not modify the database directly: it asks the manager itself to do it. It makes a backup first.
$ErrorActionPreference = 'Continue'
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
if (-not (Test-Path $adb)) { $adb = 'adb' }
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$work = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'StorioTV\menu'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$log = Join-Path $work ('add_{0:yyyyMMdd_HHmm}.txt' -f (Get-Date))
$URI = 'content://com.vtech.innotab.vpm.provider'
$PART = 'STORIODOOM'
$PROJ = 'PartNo:DisplayName:Category:ConsoleType:VerifiedState:InstallState:ErrorState:PackageName:FileLocation:Version'

function Sh([string]$cmd) { $r = & $adb shell $cmd 2>&1; $r | Out-File -Append -Encoding utf8 $log; return $r }
function Say($t, $c = 'Gray') { Write-Host $t -ForegroundColor $c; $t | Out-File -Append -Encoding utf8 $log }
function DoomRow { (Sh "content query --uri $URI/full --projection $PROJ --where PartNo=\'$PART\'") | Where-Object { $_ -match 'PartNo=' } }

if (-not ((& $adb devices) -match "`tdevice")) { Say 'Console not detected over ADB.' Red; return }
# Wait until Android has fully booted (otherwise the package manager does not respond)
for ($i = 0; $i -lt 60; $i++) {
    $boot = (& $adb shell getprop sys.boot_completed 2>$null | Out-String).Trim()
    $pm = (& $adb shell pm path android 2>&1 | Out-String)
    if ($boot -eq '1' -and $pm -match 'package:') { break }
    if ($i -eq 0) { Say 'Waiting for the console to finish booting...' Yellow }
    Start-Sleep 3
}
Say '0/7 Installing/updating DOOM...' Cyan
$inst = (& $adb install -r (Join-Path $here 'doom.apk') 2>&1 | Out-String)
$inst | Out-File -Append -Encoding utf8 $log
if ($inst -notmatch 'Success') { Say "   The installation did not finish cleanly: $(($inst -split "`n" | Where-Object { $_ -match 'Failure|Error' }) -join ' ')" Yellow }
if (-not ((& $adb shell pm path org.storio.doom) -match 'package:')) { Say 'DOOM is not installed and could not be installed.' Red; return }

Say '1/7 Backing up the desktop database...' Cyan
$bk = Join-Path $work ('fakeapp_{0:yyyyMMdd_HHmm}.db' -f (Get-Date))
& $adb pull /data/data/com.vtech.innotab.vpm/databases/fakeapp.db $bk | Out-Null
if (-not (Test-Path $bk) -or (Get-Item $bk).Length -lt 1024) { Say 'Could not copy the database. Nothing was changed.' Red; return }
Say "   Saved to $bk"
"== BEFORE" | Out-File -Append -Encoding utf8 $log
Sh "content query --uri $URI/full --projection $PROJ" | Out-Null

Say '2/7 Copying the APK for the VTech manager...' Cyan
& $adb push (Join-Path $here 'doom.apk') /sdcard/doom.apk | Out-Null

$row = DoomRow
if ($row) { Say '3/7 DOOM was already registered in the manager.' Cyan } else {
Say '3/7 Registering DOOM in the manager (developer route)...' Cyan
& $adb logcat -c
Sh "content insert --uri $URI/for_dev --bind FilePath:s:/sdcard/doom.apk --bind PartNO:s:$PART --bind Ver:s:1 --bind Category:s:game --bind DisplayName:s:DOOM --bind Description:s:DOOM --bind ForceUpdate:s:true" | Out-Null

Say '   Waiting for the manager to finish (up to 90 s)...'
$row = $null
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep 3
    $row = DoomRow
    if ($row -match 'InstallState=0' -or $row -match 'ErrorState=-?[1-9]') { break }
}
Say "   Status: $row"
"== LOGCAT" | Out-File -Append -Encoding utf8 $log
& $adb logcat -d -v time 2>&1 | Select-String -Pattern 'VPM|VDM|vpm|vdm|Install|STORIODOOM|doom' | Out-File -Append -Encoding utf8 $log

}
if (-not $row) { Say 'The manager did not create the entry. See the log file:' Red; Say "   $log"; return }

Say '4/7 Marking it as a game...' Cyan
$apk = ((& $adb shell pm path org.storio.doom) -replace 'package:', '').Trim()
$where = "'(Version IS NULL OR Version IS NOT NULL) AND (FileLocation IS NULL OR FileLocation IS NOT NULL)'"
Sh "content update --uri $URI/verified/$PART --bind 'ConsoleType:s:|Game|' --bind VerifiedState:i:2 --bind InstallState:i:0 --bind ErrorState:i:0 --bind PackageName:s:org.storio.doom --bind FileLocation:s:$apk --bind Version:i:1 --where $where" | Out-Null
$row = DoomRow
Say "   Final status: $row"
"== AFTER" | Out-File -Append -Encoding utf8 $log
Sh "content query --uri $URI/full --projection $PROJ" | Out-Null

Say '5/7 Preparing the icon...' Cyan
$idLine = (Sh "content query --uri $URI/full --projection _id:PartNo --where PartNo=\'$PART\'") | Where-Object { $_ -match '_id=(\d+)' } | Select-Object -First 1
if ($idLine -match '_id=(\d+)') { $fid = $Matches[1] } else { $fid = $null }
$icNow = if ($fid) { Sh "content query --uri $URI/icon --projection _id:IconSupState:IconSupPath --where ExtrId=$fid" } else { $null }
if ($fid -and ($icNow -match 'IconSupState=1') -and ($icNow -match '127\.0\.0\.1:8737')) {
    Say '   The icon was already generated.' Green
    $ok = $true
} elseif ($fid) {
    Sh "content update --uri $URI/icon --bind IconSup:s:x --bind IconSupPath:s:http://127.0.0.1:8737/doom.png --bind IconSupState:i:0 --bind 'IconDisplayColor:s:#8B0000' --where '_id IN (SELECT _id FROM icon WHERE ExtrId=$fid AND IsGroup=0) AND IconSupPath IS NOT NULL'" | Out-Null
    Say '6/7 Generating the icon with the VTech service (DOOM will open; this takes 1-2 minutes, do not touch anything)...' Cyan
    & $adb logcat -c
    & $adb shell am start -n org.storio.doom/android.app.NativeActivity | Out-Null
    Start-Sleep 5
    # Android 4.2 has no "am stopservice": the VTech manager is killed and reopened by querying it,
    # which recreates the icon service from scratch (it starts working after 60 s).
    Sh "am force-stop com.vtech.innotab.vpm" | Out-Null
    Start-Sleep 2
    Sh "content query --uri $URI/full --projection _id --where _id=$fid" | Out-Null
    Sh "am startservice -n com.vtech.innotab.vpm/.Service4CheckingNullIcon" | Out-Null
    $ok = $false
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep 3
        if ($i % 5 -eq 0) { Write-Host ("   ... {0} s" -f (($i + 1) * 3)) }
        $ic = Sh "content query --uri $URI/icon --projection _id:ExtrId:IconSupState:IconSupPath:IconDisplayColor --where ExtrId=$fid"
        if ($ic -match 'IconSupState=1') { $ok = $true; break }
    }
    "== LOGCAT ICON" | Out-File -Append -Encoding utf8 $log
    & $adb logcat -d -v time 2>&1 | Select-String -Pattern 'NullIcon|IconEffect|DOOM|Icon served' | Out-File -Append -Encoding utf8 $log
    & $adb shell am force-stop org.storio.doom
    if ($ok) { Say '   Icon generated.' Green } else { Say '   The icon was not generated (check the log).' Yellow }
} else { Say '   Could not find the DOOM id in the manager.' Yellow }

Say '7/7 Restarting the desktop...' Cyan
& $adb shell am force-stop com.vtech.innotab.TVDesktop
& $adb shell input keyevent 3
Say ''
if ($row -match 'ConsoleType=\|Game\|' -and $row -match 'VerifiedState=2' -and $row -match 'InstallState=0' -and $ok) {
    Say 'Done: DOOM should now appear in the games section of the desktop.' Green
} else {
    Say 'It did not end up as expected. See the log file:' Yellow
}
Say "Log: $log"
