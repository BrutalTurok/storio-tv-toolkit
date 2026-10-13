# Installs DOOM on the Storio TV / InnoTV and starts it.
# Usage:  powershell -ExecutionPolicy Bypass -File Install-DOOM.ps1  [-Wad C:\path\doom1.wad]
param([string]$Wad = "")
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
if (-not (Test-Path $adb)) { $adb = 'adb' }
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not ((& $adb devices) -match "`tdevice")) { Write-Host 'Console not detected over ADB.' -ForegroundColor Red; return }
Write-Host 'Installing doom.apk...' -ForegroundColor Cyan
& $adb install -r (Join-Path $here 'doom.apk')
if ($Wad -and (Test-Path $Wad)) {
    Write-Host "Copying $Wad to the console..." -ForegroundColor Cyan
    & $adb push $Wad /sdcard/doom1.wad
}
# If DOOM is already in the VTech menu, update the APK path: every reinstall changes it
# (org.storio.doom-1.apk <-> -2.apk) and, on reboot, the VTech manager hides the game if the saved path does not exist.
$URI = 'content://com.vtech.innotab.vpm.provider'
$row = (& $adb shell "content query --uri $URI/full --projection PartNo:FileLocation --where PartNo=\'STORIODOOM\'" 2>&1) | Where-Object { $_ -match 'PartNo=' }
if ($row) {
    $apk = ((& $adb shell pm path org.storio.doom) -replace 'package:', '').Trim()
    if ($apk) {
        $where = "'(Version IS NULL OR Version IS NOT NULL) AND (FileLocation IS NULL OR FileLocation IS NOT NULL)'"
        & $adb shell "content update --uri $URI/verified/STORIODOOM --bind 'ConsoleType:s:|Game|' --bind VerifiedState:i:2 --bind InstallState:i:0 --bind ErrorState:i:0 --bind PackageName:s:org.storio.doom --bind FileLocation:s:$apk --bind Version:i:1 --where $where" | Out-Null
        Write-Host "VTech menu updated ($apk)." -ForegroundColor Green
    }
}
if (Test-Path (Join-Path $here 'doom_buttons.txt')) { & $adb push (Join-Path $here 'doom_buttons.txt') /sdcard/doom_buttons.txt | Out-Null }
Write-Host 'Starting DOOM...' -ForegroundColor Cyan
& $adb shell chmod 666 /dev/input/eventvj1 /dev/input/eventvj2 /dev/input/eventvj3 /dev/input/eventvj4 /dev/input/event2
& $adb shell am start -n org.storio.doom/android.app.NativeActivity
Write-Host ''
Write-Host 'If the screen stays RED: the WAD is missing. If it stays BLACK for a long time: run Show-Log.ps1.' -ForegroundColor Yellow
