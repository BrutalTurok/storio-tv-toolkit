# Raw-reads the cartridge inserted in the Storio TV / InnoTV (in the layout MAME uses), without opening anything.
# Read-only: nothing is written to the cartridge. Output goes to Documents\StorioTV\cartridges\
$ErrorActionPreference = 'Continue'
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
if (-not (Test-Path $adb)) { $adb = 'adb' }
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$reader = Join-Path $here 'cart_reader'
function Say($t, $c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Sh([string]$cmd) { (& $adb shell $cmd 2>&1) | ForEach-Object { "$_".TrimEnd("`r") } }

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
using System.Security.Cryptography;
public static class CartTools {
    static uint[] T;
    public static string Crc32(string path) {
        if (T == null) { T = new uint[256]; for (uint i = 0; i < 256; i++) { uint c = i; for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1; T[i] = c; } }
        uint crc = 0xFFFFFFFFu; byte[] b = new byte[1 << 20]; int n;
        using (FileStream f = File.OpenRead(path)) while ((n = f.Read(b, 0, b.Length)) > 0) for (int i = 0; i < n; i++) crc = T[(crc ^ b[i]) & 0xFF] ^ (crc >> 8);
        return (crc ^ 0xFFFFFFFFu).ToString("x8");
    }
    // Walks the FAT in cart_data.bin: computes the MD5 of every .ITA and reads every .MD5 (8.3 short names)
    public static List<string> CheckFat(string path) {
        List<string> res = new List<string>();
        using (FileStream f = File.OpenRead(path)) {
            byte[] bs = new byte[512]; f.Read(bs, 0, 512);
            int bps = BitConverter.ToUInt16(bs, 11), spc = bs[13], rsv = BitConverter.ToUInt16(bs, 14), nf = bs[16];
            int rootEnt = BitConverter.ToUInt16(bs, 17);
            long tot = BitConverter.ToUInt16(bs, 19); if (tot == 0) tot = BitConverter.ToUInt32(bs, 32);
            long fsz = BitConverter.ToUInt16(bs, 22); bool fat32 = fsz == 0; if (fat32) fsz = BitConverter.ToUInt32(bs, 36);
            if (bps != 512 && bps != 1024 && bps != 2048 && bps != 4096 || spc == 0) { res.Add("ERROR: no FAT file system at the start of the image"); return res; }
            long fatOff = (long)rsv * bps, rootOff = fatOff + nf * fsz * bps, rootSize = (long)rootEnt * 32;
            long dataOff = rootOff + ((rootSize + bps - 1) / bps) * bps; long cl = (long)spc * bps;
            long nclus = (tot - (dataOff / bps)) / spc;
            bool fat12 = !fat32 && nclus < 4085;
            if (fat12) { res.Add("ERROR: FAT12 not supported"); return res; }
            byte[] fat = new byte[fsz * bps]; f.Seek(fatOff, SeekOrigin.Begin); f.Read(fat, 0, fat.Length);
            Func<long, long> next = c => fat32 ? (BitConverter.ToUInt32(fat, (int)(c * 4)) & 0x0FFFFFFF) : BitConverter.ToUInt16(fat, (int)(c * 2));
            long eoc = fat32 ? 0x0FFFFFF8 : 0xFFF8;
            Func<long, long, byte[]> readChain = (start, size) => {
                MemoryStream ms = new MemoryStream(); long c = start; byte[] buf = new byte[cl]; int guard = 0;
                while (c >= 2 && c < eoc && guard++ < 10000000) { f.Seek(dataOff + (c - 2) * cl, SeekOrigin.Begin); f.Read(buf, 0, (int)cl); ms.Write(buf, 0, (int)cl); if (size >= 0 && ms.Length >= size) break; c = next(c); }
                byte[] r = ms.ToArray(); if (size >= 0 && r.Length > size) Array.Resize(ref r, (int)size); return r;
            };
            Action<byte[], string, int> walk = null;
            walk = (dir, p, depth) => {
                for (int o = 0; o + 32 <= dir.Length; o += 32) {
                    if (dir[o] == 0) break; if (dir[o] == 0xE5 || dir[o + 11] == 0x0F) continue;
                    string nm = System.Text.Encoding.ASCII.GetString(dir, o, 8).Trim(), ex = System.Text.Encoding.ASCII.GetString(dir, o + 8, 3).Trim();
                    if (nm == "." || nm == "..") continue;
                    long c = BitConverter.ToUInt16(dir, o + 26) | ((long)BitConverter.ToUInt16(dir, o + 20) << 16);
                    long size = BitConverter.ToUInt32(dir, o + 28);
                    string full = p + "/" + nm + (ex.Length > 0 ? "." + ex : "");
                    if ((dir[o + 11] & 0x10) != 0) { if (depth < 6) walk(readChain(c, -1), full, depth + 1); }
                    else if (ex == "ITA") {
                        MD5 md = MD5.Create(); long left = size, cc = c; byte[] buf = new byte[cl];
                        while (left > 0 && cc >= 2 && cc < eoc) { f.Seek(dataOff + (cc - 2) * cl, SeekOrigin.Begin); f.Read(buf, 0, (int)cl); int take = (int)Math.Min(cl, left); md.TransformBlock(buf, 0, take, null, 0); left -= take; cc = next(cc); }
                        md.TransformFinalBlock(new byte[0], 0, 0);
                        res.Add("ITA|" + full + "|" + size + "|" + BitConverter.ToString(md.Hash).Replace("-", ""));
                    } else if (ex == "MD5" && size < 256) {
                        res.Add("MD5|" + full + "|" + System.Text.Encoding.ASCII.GetString(readChain(c, size)).Trim().ToUpper());
                    }
                }
            };
            byte[] root;
            if (fat32) root = readChain(BitConverter.ToUInt32(bs, 44), -1);
            else { root = new byte[rootSize]; f.Seek(rootOff, SeekOrigin.Begin); f.Read(root, 0, root.Length); }
            res.Add("FAT|" + (fat32 ? "FAT32" : "FAT16") + "|cluster " + cl + " bytes");
            walk(root, "", 0);
        }
        return res;
    }
}
'@

if (-not (Test-Path $reader)) { Say "The file cart_reader is missing next to this script." Red; Read-Host 'Press Enter to exit'; return }
if (-not ((& $adb devices) -match "`tdevice")) { Say 'Console not detected over ADB.' Red; Read-Host 'Press Enter to exit'; return }
for ($i = 0; $i -lt 60; $i++) {
    if ((Sh 'getprop sys.boot_completed') -eq '1') { break }
    if ($i -eq 0) { Say 'Waiting for the console to finish booting (it needs HDMI connected)...' Yellow }
    Start-Sleep 3
}
if ((Sh 'id') -notmatch 'uid=0') { Say 'ADB is not root: the cartridge cannot be read.' Red; Read-Host 'Press Enter to exit'; return }
while (-not ((Sh 'cat /proc/mtd') -match 'Inno|VFAT|Cart')) {
    Say 'No cartridge found. Insert it into the console and press Enter (or close the window to quit).' Yellow
    Read-Host | Out-Null
    Start-Sleep 3
}
$part = (Sh 'ls /mnt/cart0' | Where-Object { $_ -match '^\d\d-\d{6}' } | Select-Object -First 1)
$pn = if ($part) { ($part -split '\.')[0] } else { 'unknown' }
Say "Cartridge: $pn" Cyan
$dest = Join-Path ([Environment]::GetFolderPath('MyDocuments')) ('StorioTV\cartridges\{0}_{1:yyyyMMdd_HHmm}' -f $pn, (Get-Date))
New-Item -ItemType Directory -Force -Path $dest | Out-Null

Say '1/4 Reading the cartridge on the console (a few minutes; do not remove it)...' Cyan
& $adb push $reader /data/local/tmp/cart_reader 2>&1 | Out-Null
Sh 'chmod 755 /data/local/tmp/cart_reader' | Out-Null
Sh 'rm -r /sdcard/cart_dump' | Out-Null
$output = & $adb shell /data/local/tmp/cart_reader /sdcard/cart_dump 2>&1 | ForEach-Object { $l = "$_".TrimEnd("`r"); Write-Host "   $l"; $l }
if (-not ($output -match 'RESULT: OK')) {
    Say 'The read did not finish correctly. Please share the report:' Red
    & $adb pull /sdcard/cart_dump/report.txt $dest 2>&1 | Out-Null
    Say "   $dest\report.txt"; Read-Host 'Press Enter to exit'; return
}

Say '2/4 Copying to the PC...' Cyan
foreach ($f in 'cart_raw.bin', 'cart_data.bin', 'report.txt') { & $adb pull "/sdcard/cart_dump/$f" (Join-Path $dest $f) 2>&1 | Out-Null }
$raw = Join-Path $dest 'cart_raw.bin'; $data = Join-Path $dest 'cart_data.bin'
if (-not (Test-Path $raw) -or -not (Test-Path $data)) { Say 'The files were not copied.' Red; Read-Host 'Press Enter to exit'; return }
Sh 'rm -r /sdcard/cart_dump' | Out-Null
Sh 'rm /data/local/tmp/cart_reader /data/local/tmp/mtd_reader' | Out-Null

Say '3/4 Verifying the dump (the game inside must match its MD5)...' Cyan
$chk = [CartTools]::CheckFat($data)
$md5s = @{}; $itas = @()
foreach ($l in $chk) {
    $p = $l -split '\|'
    if ($p[0] -eq 'MD5') { $md5s[(Split-Path $p[1] -Parent)] = $p[2] }
    if ($p[0] -eq 'ITA') { $itas += , $p }
    if ($p[0] -eq 'ERROR') { Say "   $($p[1])" Red }
    if ($p[0] -eq 'FAT') { Say "   File system: $($p[1]), $($p[2])" }
}
$verif = @()
foreach ($p in $itas) {
    $expected = $md5s[(Split-Path $p[1] -Parent)]
    if ($expected -and $expected -eq $p[3]) { Say "   $($p[1]): MD5 OK ($($p[3]))" Green; $verif += "$($p[1]): MD5 OK $($p[3])" }
    elseif ($expected) { Say "   $($p[1]): MD5 MISMATCH (expected $expected, read $($p[3]))" Red; $verif += "$($p[1]): MD5 BAD" }
    else { Say "   $($p[1]): MD5 $($p[3]) (no .md5 file to compare against)" Yellow; $verif += "$($p[1]): MD5 $($p[3])" }
}
if (-not $itas) { Say '   The game was not found inside the dump.' Red }

Say '4/4 Computing hashes for MAME / No-Intro...' Cyan
$h = @("Cartridge $pn - read on the console with cart_reader - $(Get-Date -Format 'yyyy-MM-dd')", '')
foreach ($f in $raw, $data) {
    $h += (Split-Path $f -Leaf)
    $h += "  size:   $((Get-Item $f).Length) bytes"
    $h += "  CRC32:  $([CartTools]::Crc32($f))"
    foreach ($a in 'MD5', 'SHA1', 'SHA256') { $h += ("  {0,-7} {1}" -f ($a + ':'), (Get-FileHash $f -Algorithm $a).Hash.ToLower()) }
    $h += ''
}
$h += 'Internal check:'; $h += $verif; $h += ''
$h += (Get-Content -Encoding UTF8 (Join-Path $dest 'report.txt') | Where-Object { $_ -match '^Type |spare|bad blocks|read errors|RESULT' })
$h | Out-File -Encoding utf8 (Join-Path $dest 'hashes.txt')
$h | ForEach-Object { Write-Host "   $_" }
Say ''
Say "Done. Everything is in: $dest" Green
Read-Host 'Press Enter to exit'
