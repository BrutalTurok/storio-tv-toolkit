# Storio TV - information gathering over ADB (read-only: nothing on the console is modified)
$ErrorActionPreference = 'Continue'
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
if (-not (Test-Path $adb)) { $adb = 'adb' }
$out = Join-Path ([Environment]::GetFolderPath('MyDocuments')) ('StorioTV\diagnostics_{0:yyyyMMdd_HHmm}' -f (Get-Date))
New-Item -ItemType Directory -Force -Path $out, "$out\apks", "$out\cartridge" | Out-Null

function A { & $adb @args 2>&1 }
function Save($name, $lines) { $lines | Out-File -Encoding utf8 (Join-Path $out $name) }

Write-Host "Saving to $out" -ForegroundColor Cyan
if (-not ((A devices) -match "`tdevice")) { Write-Host 'Console not detected over ADB.' -ForegroundColor Red; Read-Host 'Press Enter to exit'; return }

Write-Host '1/3 System information...' -ForegroundColor Cyan
Save 'getprop.txt'   (A shell getprop)
Save 'mounts.txt'    (A shell cat /proc/mounts)
Save 'packages.txt'  (A shell pm list packages -f)
Save 'storage.txt'   (A shell ls -l /mnt /storage /mnt/sdcard /mnt/external_sd /mnt/usb_storage)
Save 'property.txt'  (A shell 'for f in /data/property/*; do echo "$f=$(cat $f)"; done')
A pull /data/system/packages.xml "$out\packages.xml" | Out-Null

Write-Host '2/3 Copying VTech apps to check their languages...' -ForegroundColor Cyan
foreach ($p in '/system/app/TVDesktop.apk','/system/app/ProfileTV.apk','/system/app/CartReceiver.apk','/system/app/VPM.apk','/system/app/VDM.apk','/system/app/Settings.apk','/data/app/com.vtech.innotv.quizgame-1.apk') {
    A pull $p "$out\apks\" | Out-Null
}

Write-Host ''
Write-Host '3/3 CARTRIDGE' -ForegroundColor Yellow
Write-Host '  1) Remove any cartridge from the console and press Enter.' -ForegroundColor Yellow
Read-Host '  '
Save 'mounts_without_cart.txt' (A shell cat /proc/mounts)
A logcat -c | Out-Null
A shell dmesg -c | Out-Null
Write-Host '  2) Insert ONE of the cartridges that ask for an update and try to open it on the console' -ForegroundColor Yellow
Write-Host '     until the update message appears. Then press Enter here.' -ForegroundColor Yellow
Read-Host '  '
Save 'logcat_cart.txt' (A logcat -d -v time)
Save 'dmesg_cart.txt'  (A shell dmesg)
$m = A shell cat /proc/mounts
Save 'mounts_with_cart.txt' $m
$before = Get-Content (Join-Path $out 'mounts_without_cart.txt')
$new = $m | Where-Object { $before -notcontains $_ }
Save 'mounts_new.txt' $new
foreach ($line in $new) {
    $mp = ($line -split ' ')[1]
    if ($mp -and $mp -notmatch '^/(proc|sys|dev)') {
        Write-Host "  Cartridge mounted at $mp, copying..." -ForegroundColor Cyan
        Save 'cart_listing.txt' (A shell ls -lR $mp)
        A pull $mp "$out\cartridge" | Out-Null
    }
}
Save 'cart_data_listing.txt' (A shell ls -lR /data/data/com.vtech.innotab.cartreceiver /mnt/sdcard/Android/data /data/local/vtech)
Write-Host ''
Write-Host "Done. Everything is in: $out" -ForegroundColor Green
Read-Host 'Press Enter to exit'
