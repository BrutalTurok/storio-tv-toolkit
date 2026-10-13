# Starts DOOM on the console (and gives it access to the VTech controller buttons).
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
if (-not (Test-Path $adb)) { $adb = 'adb' }
& $adb shell chmod 666 /dev/input/eventvj1 /dev/input/eventvj2 /dev/input/eventvj3 /dev/input/eventvj4 /dev/input/event2
& $adb shell am force-stop org.storio.doom
& $adb push (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'doom_buttons.txt') /sdcard/doom_buttons.txt | Out-Null
& $adb shell am start -n org.storio.doom/android.app.NativeActivity
