# Storio TV - backup of the installed games (cartridge games and downloaded games).
# Read-only on the console: nothing is deleted or changed. Output goes to Documents\StorioTV\games\
param([string]$Package = "")
$ErrorActionPreference = 'Continue'
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
if (-not (Test-Path $adb)) { $adb = 'adb' }
$base = Join-Path ([Environment]::GetFolderPath('MyDocuments')) ('StorioTV\games\backup_{0:yyyyMMdd_HHmm}' -f (Get-Date))
function Say($t, $c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Sh([string]$cmd) { (& $adb shell $cmd 2>&1) | ForEach-Object { "$_".TrimEnd("`r") } }
function Pull([string]$src, [string]$dst) {
    # adb writes its progress to stderr: convert it to text so PowerShell does not treat it as an error
    $r = (& $adb pull $src $dst 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return ($LASTEXITCODE -eq 0 -and $r -notmatch 'does not exist|failed to|Permission denied')
}

if (-not ((& $adb devices) -match "`tdevice")) { Say 'Console not detected over ADB.' Red; Read-Host 'Press Enter to exit'; return }
for ($i = 0; $i -lt 60; $i++) {
    if ((Sh 'getprop sys.boot_completed') -eq '1') { break }
    if ($i -eq 0) { Say 'Waiting for the console to finish booting (it needs HDMI connected)...' Yellow }
    Start-Sleep 3
}
if ((Sh 'id') -notmatch 'uid=0') { Say 'ADB is not root: the protected games cannot be copied.' Red; Read-Host 'Press Enter to exit'; return }

# Packages to copy: cartridge games and downloaded InnoTV games
$pkgs = Sh 'pm list packages' | ForEach-Object { $_ -replace '^package:', '' } |
        Where-Object { $_ -match '^com\.vtech\.innotab\.cart\.' -or $_ -match '^com\.vtech\.innotv\.' } |
        Where-Object { $_ -ne 'com.vtech.innotv.homefilter' }
if ($Package) { $pkgs = $pkgs | Where-Object { $_ -eq $Package } }
if (-not $pkgs) { Say 'No installed games to copy.' Yellow; Read-Host 'Press Enter to exit'; return }
New-Item -ItemType Directory -Force -Path $base | Out-Null
$report = Join-Path $base 'report.txt'
"Storio TV game backup - $(Get-Date)" | Out-File -Encoding utf8 $report
Say "Games found: $(@($pkgs).Count). Saving to $base" Cyan

foreach ($p in $pkgs) {
    Say ''
    Say "== $p" Cyan
    $d = Join-Path $base $p
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    $info = Sh "dumpsys package $p"
    $info | Out-File -Encoding utf8 (Join-Path $d 'dumpsys.txt')
    $code = ($info | Where-Object { $_ -match '^\s*codePath=' } | Select-Object -First 1) -replace '^\s*codePath=', ''
    $res  = ($info | Where-Object { $_ -match '^\s*resourcePath=' } | Select-Object -First 1) -replace '^\s*resourcePath=', ''
    $lib  = ($info | Where-Object { $_ -match '^\s*nativeLibraryPath=' } | Select-Object -First 1) -replace '^\s*nativeLibraryPath=', ''
    $ver  = ($info | Where-Object { $_ -match '^\s*versionName=' } | Select-Object -First 1) -replace '^\s*versionName=', ''
    $lines = @("[$p]", "  version: $ver", "  codePath: $code", "  resourcePath: $res", "  nativeLibraryPath: $lib")

    # 1. The APK (for cartridge games it lives in /data/app-private, already decrypted by the console)
    $apk = Join-Path $d 'game.apk'
    if ($code -and (Pull $code $apk) -and (Test-Path $apk)) {
        $fs = [IO.File]::OpenRead($apk); $b = New-Object byte[] 2; [void]$fs.Read($b, 0, 2); $fs.Close()
        $ok = ($b[0] -eq 0x50 -and $b[1] -eq 0x4B)
        $mb = [math]::Round((Get-Item $apk).Length / 1MB, 1)
        if ($ok) { Say "   APK: $mb MB (decrypted, valid)" Green } else { Say "   APK: $mb MB, but it does NOT look like a normal APK" Yellow }
        $lines += "  APK: $mb MB, valid ZIP: $ok, SHA256 $((Get-FileHash $apk -Algorithm SHA256).Hash)"
    } else { Say '   Could not copy the APK.' Red; $lines += '  APK: NOT COPIED' }

    # 2. Public resources (protected apps only: a separate .zip)
    if ($res -and $res -ne $code) {
        if (Pull $res (Join-Path $d 'resources.zip')) { Say '   Public resources copied.'; $lines += '  resources.zip: yes' }
    }
    # 3. Native libraries
    if ($lib) {
        $ls = Sh "ls $lib"
        if ($ls -and ($ls -notmatch 'No such file')) {
            New-Item -ItemType Directory -Force -Path (Join-Path $d 'lib') | Out-Null
            if (Pull "$lib" (Join-Path $d 'lib')) { Say '   Native libraries copied.'; $lines += '  lib: yes' }
        }
    }
    # 4. Saved games and settings (private data)
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'data') | Out-Null
    if (Pull "/data/data/$p" (Join-Path $d 'data')) { Say '   Saved games copied.'; $lines += '  data: yes' }
    # 5. Data in internal storage (downloads, OBB)
    foreach ($s in @("/sdcard/Android/data/$p", "/sdcard/Android/obb/$p")) {
        if ((Sh "ls -d $s") -notmatch 'No such file') {
            $n = Split-Path $s -Parent | Split-Path -Leaf
            New-Item -ItemType Directory -Force -Path (Join-Path $d "sdcard_$n") | Out-Null
            if (Pull $s (Join-Path $d "sdcard_$n")) { Say "   /sdcard/Android/$n copied."; $lines += "  sdcard_${n}: yes" }
        }
    }
    $lines | Out-File -Append -Encoding utf8 $report
}

# 6. If a cartridge is inserted, copy its contents as-is (including the encrypted MAIN.ITA) and check its MD5
$cart = Sh 'ls /mnt/cart0'
if ($cart -and ($cart -notmatch 'No such file') -and ($cart -match '\S')) {
    Say ''
    Say '== Cartridge inserted: copying its original contents...' Cyan
    $cd = Join-Path $base 'cartridge_original'
    New-Item -ItemType Directory -Force -Path $cd | Out-Null
    Pull '/mnt/cart0' $cd | Out-Null
    Get-ChildItem -Path $cd -Recurse -Filter 'main.ita.md5' | ForEach-Object {
        $ita = Join-Path $_.DirectoryName 'MAIN.ITA'
        if (Test-Path $ita) {
            $expected = (Get-Content $_.FullName -Raw).Trim().ToUpper()
            $actual = (Get-FileHash $ita -Algorithm MD5).Hash
            if ($expected -eq $actual) { Say "   MAIN.ITA OK (MD5 $actual)" Green; "cartridge $($_.Directory.Parent.Name): MD5 OK" | Out-File -Append -Encoding utf8 $report }
            else { Say "   MAIN.ITA does NOT match its MD5 (damaged copy or faulty cartridge)" Red; "cartridge $($_.Directory.Parent.Name): MD5 BAD" | Out-File -Append -Encoding utf8 $report }
        }
    }
}
Say ''
Say "Done. Report: $report" Green
Read-Host 'Press Enter to exit'
