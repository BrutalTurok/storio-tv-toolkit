#requires -Version 5.1
<#
  Storio TV / InnoTV - Tool for the internal microSD card
  - Full verified backup (SHA-256)
  - Analysis: Rockchip partition table, firmware version, ADB status
  - Partition extraction
  - Creation of a system partition with ADB enabled (never touches the backup)
  - Writing a partition or a full restore, with checks and verification
  Use at your own risk. Always make the backup first (option 1).
#>
param([switch]$NoMenu)

$ErrorActionPreference = 'Stop'
$Script:ToolVersion = '1.2'
$docs = [Environment]::GetFolderPath('MyDocuments')
if (-not $docs) { $docs = $HOME }
$Script:WorkDir = Join-Path $docs 'StorioTV'

$CoreSource = @'
#__CORE__
'@

if (-not ('StorioTool.Core' -as [type])) {
    Add-Type -TypeDefinition $CoreSource -Language CSharp
}

# ------------------------------------------------------------------ utilities

function Say([string]$t, [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Fmt([long]$b) { if ($b -ge 1GB) { '{0:N2} GB' -f ($b / 1GB) } else { '{0:N1} MB' -f ($b / 1MB) } }
function Pause-Tool { [void](Read-Host "`n  Press Enter to return to the menu") }

function Confirm-Danger([string]$what) {
    Say ''
    Say "  WARNING: $what" Yellow
    Say '  Type WRITE (in capitals) to continue, or press Enter to cancel.' Yellow
    $a = Read-Host '  '
    return ($a -ceq 'WRITE')
}

function Confirm-Yes([string]$q) {
    $a = Read-Host "  $q (y/n)"
    return ($a -match '^(y|yes)$')
}

function Get-FreeSpace([string]$path) {
    try {
        $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($path))
        return (New-Object System.IO.DriveInfo($root)).AvailableFreeSpace
    } catch { return [long]::MaxValue }
}

function Read-Sidecar([string]$img) {
    $f = "$img.sha256"
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    $line = (Get-Content -LiteralPath $f -TotalCount 1)
    if ($line -match '^([0-9a-fA-F]{64})') { return $Matches[1].ToLower() }
    return $null
}

function Write-Sidecar([string]$file, [string]$hash) {
    Set-Content -LiteralPath "$file.sha256" -Value ("{0} *{1}" -f $hash, (Split-Path -Leaf $file)) -Encoding ASCII
}

function Get-Props([string]$text) {
    $h = [ordered]@{}
    if (-not $text) { return $h }
    foreach ($l in ($text -split "`r?`n")) {
        $t = $l.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -gt 0) { $h[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim() }
    }
    return $h
}

function Select-File([string]$title, [string]$initialDir) {
    if ($IsLinux -or $IsMacOS) { return (Read-Host "  $title (path)").Trim('"') }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $owner = New-Object System.Windows.Forms.Form
        $owner.TopMost = $true
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = $title
        $dlg.Filter = 'Card / partition images (*.img)|*.img|All files (*.*)|*.*'
        if ($initialDir -and (Test-Path -LiteralPath $initialDir)) { $dlg.InitialDirectory = $initialDir }
        $r = $dlg.ShowDialog($owner)
        $owner.Dispose()
        if ($r -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
        return $null
    } catch {
        $p = Read-Host "  $title (type the full path)"
        if ($p) { return $p.Trim('"') }
        return $null
    }
}

function Get-LatestBackup {
    if (-not (Test-Path -LiteralPath $Script:WorkDir)) { return $null }
    Get-ChildItem -LiteralPath $Script:WorkDir -Filter '*.img' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'backup_*' -and (Test-Path -LiteralPath ($_.FullName + '.sha256')) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Select-Backup([string]$title) {
    $last = Get-LatestBackup
    if ($last) {
        Say "  Latest verified backup: $($last.Name)  ($(Fmt $last.Length))" Cyan
        if (Confirm-Yes 'Use this backup?') { return $last.FullName }
    }
    $p = Select-File $title $Script:WorkDir
    if ($p -and (Test-Path -LiteralPath $p)) { return (Resolve-Path -LiteralPath $p).Path }
    Say '  No file was selected.' Yellow
    return $null
}

# ------------------------------------------------------------------ card

function Get-CardVolumes([int]$n) {
    $paths = @()
    foreach ($p in @(Get-Partition -DiskNumber $n -ErrorAction SilentlyContinue)) {
        foreach ($a in @($p.AccessPaths)) { if ($a -like '\\?\Volume*') { $paths += $a } }
    }
    return $paths
}

function Select-Card {
    Say '  Looking for cards...' Cyan
    $all = @(Get-Disk -ErrorAction SilentlyContinue)
    $cands = @($all | Where-Object { -not $_.IsBoot -and -not $_.IsSystem -and $_.Size -gt 0 -and $_.Size -le 64GB })
    if ($cands.Count -eq 0) {
        Say '  No card was found. Check that it is inserted in the reader and wait a few seconds.' Red
        Say '  (For safety, the system disk and disks larger than 64 GB are never shown.)' DarkGray
        return $null
    }
    Say ''
    Say '   No.  Size        Bus       Name' White
    foreach ($d in $cands) {
        Say ('   {0,-4} {1,-11} {2,-9} {3}' -f $d.Number, (Fmt $d.Size), $d.BusType, $d.FriendlyName)
    }
    Say ''
    $sel = Read-Host '  Type the No. of the disk that is the Storio card (Enter to cancel)'
    if (-not $sel) { return $null }
    $d = $cands | Where-Object { "$($_.Number)" -eq $sel.Trim() } | Select-Object -First 1
    if (-not $d) { Say '  Invalid number.' Red; return $null }
    if (@('SD', 'USB', 'MMC') -notcontains "$($d.BusType)") {
        Say "  Warning: disk $($d.Number) is connected via '$($d.BusType)', not SD/USB." Yellow
        if (-not (Confirm-Yes 'Are you sure it is the card?')) { return $null }
    }
    if ($d.Size -lt 3.5GB -or $d.Size -gt 16GB) {
        Say "  Warning: the Storio TV card is about 8 GB and this one is $(Fmt $d.Size)." Yellow
        if (-not (Confirm-Yes 'Are you sure it is the right card?')) { return $null }
    }
    return [pscustomobject]@{
        Number = [int]$d.Number
        Path   = "\\.\PhysicalDrive$($d.Number)"
        Size   = [long]$d.Size
        Name   = "$($d.FriendlyName)"
    }
}

# ------------------------------------------------------------------ operations (no prompts)

function Invoke-Backup {
    param([string]$CardPath, [long]$CardSize, [string]$OutFile)
    if (Test-Path -LiteralPath $OutFile) { throw "$OutFile already exists" }
    $free = Get-FreeSpace $OutFile
    if ($free -lt ($CardSize + 200MB)) { throw "Not enough disk space: $(Fmt ($CardSize + 200MB)) needed and $(Fmt $free) available." }

    $src = [StorioTool.Dev]::Open($CardPath, $false, $CardSize, $null)
    try {
        try {
            $h1 = [StorioTool.Core]::CopyToNewFile($src, 0, $src.Length, $OutFile, 'Copying card     ')
        } catch {
            if (Test-Path -LiteralPath $OutFile) { Move-Item -LiteralPath $OutFile -Destination "$OutFile.INCOMPLETE" -Force }
            throw
        }
        Say '  Verification 1/2: re-reading the card...' Cyan
        $h2 = [StorioTool.Core]::CopyHash($src, 0, $null, 0, $src.Length, 'Re-reading card  ')
    } finally { $src.Dispose() }
    if ($h1 -ne $h2) {
        Move-Item -LiteralPath $OutFile -Destination "$OutFile.UNRELIABLE" -Force
        throw 'The two reads of the card do NOT match: the reader or the card is failing. Try another reader/adapter.'
    }
    Say '  Verification 2/2: reading the saved file...' Cyan
    $h3 = [StorioTool.Core]::HashFile($OutFile, 'Checking file')
    if ($h3 -ne $h1) {
        Move-Item -LiteralPath $OutFile -Destination "$OutFile.UNRELIABLE" -Force
        throw 'The saved file does not match the card (PC disk failure).'
    }
    Write-Sidecar $OutFile $h1
    return $h1
}

function Get-Analysis {
    param([string]$Path, [long]$Length = 0)
    $out = New-Object System.Collections.Generic.List[string]
    $res = [ordered]@{ Layout = $null; BuildProp = $null; DefaultProp = $null; Report = $out; AdbReady = $false; PersistFix = @() }
    $d = [StorioTool.Dev]::Open($Path, $false, $Length, $null)
    try {
        $L = [StorioTool.Core]::Resolve($d)
        $res.Layout = $L
        $out.Add("Source:  $Path")
        $out.Add("Size:    $(Fmt $d.Length)  ($($d.Length) bytes)")
        $out.Add("Partitions: $($L.Method)")
        if ($L.ParmText) {
            $cmd = ($L.ParmText -split "`r?`n" | Where-Object { $_ -match 'CMDLINE|MACHINE|MAGIC|FIRMWARE' }) -join "`n         "
            if ($cmd) { $out.Add("PARM:    $cmd") }
        }
        $out.Add('')
        $out.Add('  Partition     Start (sector)    Size          Contents')
        foreach ($p in $L.Parts) {
            $sz = if ($p.SizeSec -lt 0) { "(rest) $(Fmt $p.Len)" } else { Fmt $p.Len }
            $out.Add(('  {0,-13} 0x{1,-14:X} {2,-13} {3}' -f $p.Name, ($p.Start / 512), $sz, $p.Check))
        }
        $out.Add('')

        $sys = $L.Get('system')
        if ($sys -and $sys.Check -eq 'ext4') {
            $fs = New-Object StorioTool.Ext4($d, $sys.Start)
            $out.Add("system: ext4, block $($fs.BlockSize) bytes, $($fs.Features())")
            $ino = $fs.Lookup('/build.prop')
            if ($ino -ne 0) {
                $bytes = $fs.ReadFile($ino)
                $res.BuildProp = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
                $bp = Get-Props $res.BuildProp
                $out.Add('')
                $out.Add('== Firmware version (build.prop) ==')
                $keys = @('ro.build.display.id', 'ro.build.version.incremental', 'ro.build.version.release', 'ro.build.date',
                    'ro.product.model', 'ro.product.brand', 'ro.product.manufacturer', 'ro.product.device', 'ro.build.fingerprint')
                foreach ($k in $keys) { if ($bp.Contains($k)) { $out.Add(('  {0,-32} {1}' -f $k, $bp[$k])) } }
                $extra = 0
                foreach ($k in $bp.Keys) {
                    if ($keys -contains $k) { continue }
                    if ($k -match 'vtech|firmware|fw[._]|sw[._]ver|version' -and $extra -lt 20) {
                        $out.Add(('  {0,-32} {1}' -f $k, $bp[$k])); $extra++
                    }
                }
                $out.Add('')
                $out.Add('== USB / ADB (build.prop) ==')
                foreach ($k in @('persist.sys.usb.config', 'persist.service.adb.enable', 'persist.service.debuggable', 'ro.adb.secure', 'ro.secure', 'ro.debuggable')) {
                    $v = if ($bp.Contains($k)) { $bp[$k] } else { '(not present)' }
                    $out.Add(('  {0,-32} {1}' -f $k, $v))
                }
                $usb = if ($bp.Contains('persist.sys.usb.config')) { $bp['persist.sys.usb.config'] } else { '' }
                $res.AdbReady = ($usb -match '(^|,)adb(,|$)') -and ($bp['persist.service.adb.enable'] -eq '1')
            } else { $out.Add('  build.prop was not found in system.') }
        } else {
            $out.Add('Could not locate the system partition (ext4). Send me this report.')
        }

        $res.PersistFix = @()
        foreach ($pn in @('data', 'userdata')) {
            $dp0 = $L.Get($pn)
            if (-not $dp0 -or $dp0.Check -ne 'ext4') { continue }
            try { $pp = [StorioTool.Core]::ReadPersist($d, $dp0.Start) } catch { $out.Add(''); $out.Add("Could not read '$pn': $($_.Exception.Message)"); continue }
            if ($null -eq $pp) { continue }
            $out.Add('')
            $out.Add("== Settings saved in '$pn' (/property) ==")
            if ($pp.Count -eq 0) { $out.Add('  (empty)') }
            foreach ($k in ($pp.Keys | Sort-Object)) { $out.Add(('  {0,-40} {1}' -f $k, $pp[$k].Trim())) }
            $fix = [StorioTool.Core]::PersistNeedsFix($pp)
            if ($fix) { $res.PersistFix += $pn; $out.Add("  -> This saved setting OVERRIDES build.prop: $fix") }
        }

        $boot = $L.Get('boot')
        if ($boot -and $boot.Check) {
            try { $res.DefaultProp = [StorioTool.Core]::BootDefaultProp($d, $boot) } catch { $res.DefaultProp = $null }
            $out.Add('')
            $out.Add("== boot partition ($($boot.Check)) - default.prop ==")
            if ($res.DefaultProp) {
                $dp = Get-Props $res.DefaultProp
                foreach ($k in @('ro.secure', 'ro.debuggable', 'ro.adb.secure', 'persist.sys.usb.config', 'ro.allow.mock.location')) {
                    $v = if ($dp.Contains($k)) { $dp[$k] } else { '(not present)' }
                    $out.Add(('  {0,-32} {1}' -f $k, $v))
                }
            } else { $out.Add('  Could not read the ramdisk (unrecognised format).') }
        }

        $out.Add('')
        $out.Add('== Conclusion ==')
        if ($res.PersistFix.Count -gt 0) { $out.Add("  There is a saved USB setting in '$($res.PersistFix -join ', ')' that disables ADB: use option 8 as well.") }
        if ($res.AdbReady) { $out.Add('  ADB is already enabled in build.prop.') }
        elseif ($res.BuildProp) { $out.Add('  ADB is DISABLED. Option 6 can create a system partition with ADB enabled.') }
        if ($res.DefaultProp) {
            $dp = Get-Props $res.DefaultProp
            if ($dp['ro.secure'] -eq '1') { $out.Add('  ro.secure=1: with ADB you will get a shell WITHOUT root (enough to install APKs).') }
            if ($dp['ro.adb.secure'] -eq '1') { $out.Add('  ro.adb.secure=1: ADB will ask you to authorise the PC on screen; if the console does not show the prompt, ADB will not work.') }
        }
    } finally { $d.Dispose() }
    return $res
}

function Save-Analysis($res, [string]$basePath) {
    $res.Report | Set-Content -LiteralPath "$basePath.analysis.txt" -Encoding UTF8
    if ($res.BuildProp) { [System.IO.File]::WriteAllText("$basePath.build.prop.txt", $res.BuildProp) }
    if ($res.DefaultProp) { [System.IO.File]::WriteAllText("$basePath.default.prop.txt", $res.DefaultProp) }
}

function Invoke-Extract {
    param([string]$ImagePath, [string]$OutDir, [string[]]$Names)
    $d = [StorioTool.Dev]::Open($ImagePath, $false, 0, $null)
    $done = @()
    try {
        $L = [StorioTool.Core]::Resolve($d)
        if (-not $L.Verified) { throw 'Could not verify the partition table of this image.' }
        if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
        foreach ($p in $L.Parts) {
            if ($Names -and ($Names -notcontains $p.Name)) { continue }
            if (-not $Names -and $p.SizeSec -lt 0) { continue }
            $f = Join-Path $OutDir "$($p.Name).img"
            if (Test-Path -LiteralPath $f) { Say "  $f already exists, skipping." Yellow; continue }
            $h = [StorioTool.Core]::CopyToNewFile($d, $p.Start, $p.Len, $f, ('Extracting {0,-8}' -f $p.Name))
            Write-Sidecar $f $h
            $done += $f
        }
    } finally { $d.Dispose() }
    return $done
}

function New-AdbSystem {
    param([string]$ImagePath, [string]$OutFile)
    if (Test-Path -LiteralPath $OutFile) { throw "$OutFile already exists" }
    $d = [StorioTool.Dev]::Open($ImagePath, $false, 0, $null)
    try {
        $L = [StorioTool.Core]::Resolve($d)
        if (-not $L.Verified) { throw 'Could not verify the partition table of the backup.' }
        $sys = $L.Get('system')
        if (-not $sys -or $sys.Check -ne 'ext4') { throw 'The system partition (ext4) was not found in the backup.' }
        $free = Get-FreeSpace $OutFile
        if ($free -lt ($sys.Len + 100MB)) { throw "Not enough disk space ($(Fmt $sys.Len) needed)." }
        [void][StorioTool.Core]::CopyToNewFile($d, $sys.Start, $sys.Len, $OutFile, 'Copying system   ')
        $parm = $L.ParmText
        $info = [ordered]@{ Partition = 'system'; StartSector = $sys.Start / 512; Bytes = $sys.Len; Source = $ImagePath }
    } finally { $d.Dispose() }

    $w = [StorioTool.Dev]::Open($OutFile, $true, 0, $null)
    try {
        $old = $null; $new = $null
        $changes = [StorioTool.Core]::PatchSystemImage($w, 0, [ref]$old, [ref]$new)
    } catch {
        $w.Dispose(); $w = $null
        Remove-Item -LiteralPath $OutFile -Force
        throw
    } finally { if ($w) { $w.Dispose() } }

    [System.IO.File]::WriteAllText("$OutFile.build.prop.original.txt", $old)
    [System.IO.File]::WriteAllText("$OutFile.build.prop.new.txt", $new)
    $h = [StorioTool.Core]::HashFile($OutFile, 'Computing SHA-256')
    Write-Sidecar $OutFile $h
    ($info.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) | Set-Content -LiteralPath "$OutFile.info.txt" -Encoding UTF8
    return $changes
}

function Test-SameCard {
    # Checks that the card has the same partition table and the same size as the backup
    param($CardLayout, [long]$CardSize, [string]$BackupPath)
    $b = [StorioTool.Dev]::Open($BackupPath, $false, 0, $null)
    try {
        if ($b.Length -ne $CardSize) { throw "The backup ($(Fmt $b.Length)) is not the same size as the card ($(Fmt $CardSize)). Is it the backup of THIS card?" }
        $Lb = [StorioTool.Core]::Resolve($b)
        if (-not $Lb.Verified) { throw 'The partition table of the backup is not verified.' }
        if ($Lb.ParmText -ne $CardLayout.ParmText -or $Lb.BaseSec -ne $CardLayout.BaseSec) {
            throw 'The partition table of the card and that of the backup are different.'
        }
    } finally { $b.Dispose() }
}

function Invoke-FlashPartition {
    param([string]$CardPath, [long]$CardSize, [string[]]$Volumes, [string]$PartFile, [string]$PartName, [string]$BackupPath, [switch]$CheckOnly)
    if (-not (Test-Path -LiteralPath $BackupPath)) { throw 'The backup of this card is required.' }
    if (-not (Read-Sidecar $BackupPath)) { throw 'The backup has no .sha256 file (it is not verified). Make the backup with option 1.' }
    $expected = Read-Sidecar $PartFile

    $c = [StorioTool.Dev]::Open($CardPath, $false, $CardSize, $null)
    try {
        $Lc = [StorioTool.Core]::Resolve($c)
        if (-not $Lc.Verified) { throw 'Could not verify the partition table of the CARD.' }
        $p = $Lc.Get($PartName)
        if (-not $p) { throw "The card has no '$PartName' partition." }
        if ($p.SizeSec -lt 0) { throw "Partition '$PartName' has no fixed size; it is not written, for safety." }
        $cardLen = $c.Length
    } finally { $c.Dispose() }

    Test-SameCard $Lc $cardLen $BackupPath

    $f = [StorioTool.Dev]::Open($PartFile, $false, 0, $null)
    try {
        if ($f.Length -ne $p.Len) { throw "The file is $($f.Length) bytes and partition '$PartName' is $($p.Len). They do not match." }
        if ($PartName -eq 'system' -and -not [StorioTool.Core]::IsExt4At($f, 0)) { throw 'The file does not contain a valid ext4 file system.' }
        if ($PartName -eq 'boot' -and -not [StorioTool.Core]::BootMagic($f, 0)) { throw 'The file does not look like a valid boot partition.' }
        if ($CheckOnly) { return $p }
        if ($expected) {
            Say '  Checking the integrity of the file...' Cyan
            $h0 = [StorioTool.Core]::CopyHash($f, 0, $null, 0, $f.Length, 'Checking file')
            if ($h0 -ne $expected) { throw 'The file does not match its .sha256: it is corrupted.' }
        }
        $w = [StorioTool.Dev]::Open($CardPath, $true, $CardSize, $Volumes)
        try {
            $hw = [StorioTool.Core]::CopyHash($f, 0, $w, $p.Start, $p.Len, ('Writing  {0,-8}' -f $PartName))
        } finally { $w.Dispose() }
    } finally { $f.Dispose() }

    Say '  Verifying what was written...' Cyan
    $r = [StorioTool.Dev]::Open($CardPath, $false, $CardSize, $null)
    try { $hr = [StorioTool.Core]::CopyHash($r, $p.Start, $null, 0, $p.Len, 'Verifying        ') } finally { $r.Dispose() }
    if ($hr -ne $hw) { throw 'Verification FAILED: what was read back from the card does not match what was written. Restore the backup (option 9).' }
    return $p
}

function Invoke-Restore {
    param([string]$CardPath, [long]$CardSize, [string[]]$Volumes, [string]$ImagePath)
    $img = [StorioTool.Dev]::Open($ImagePath, $false, 0, $null)
    try {
        if ($img.Length % 512 -ne 0) { throw 'The file does not have the size of a card image.' }
        if ($img.Length -gt $CardSize) { throw "The image ($(Fmt $img.Length)) is LARGER than the card ($(Fmt $CardSize)). Use a bigger card." }
        $expected = Read-Sidecar $ImagePath
        if ($expected) {
            Say '  Checking the integrity of the backup...' Cyan
            $h0 = [StorioTool.Core]::CopyHash($img, 0, $null, 0, $img.Length, 'Checking backup')
            if ($h0 -ne $expected) { throw 'The backup does NOT match its .sha256: it is corrupted. Nothing has been written.' }
        }
        $w = [StorioTool.Dev]::Open($CardPath, $true, $CardSize, $Volumes)
        try {
            $hw = [StorioTool.Core]::CopyHash($img, 0, $w, 0, $img.Length, 'Restoring        ')
        } finally { $w.Dispose() }
        $len = $img.Length
    } finally { $img.Dispose() }

    Say '  Verifying what was written...' Cyan
    $r = [StorioTool.Dev]::Open($CardPath, $false, $CardSize, $null)
    try { $hr = [StorioTool.Core]::CopyHash($r, 0, $null, 0, $len, 'Verifying        ') } finally { $r.Dispose() }
    if ($hr -ne $hw) { throw 'Verification FAILED: the card did not end up identical to the backup.' }
    return $hr
}

function Test-CardVsImage {
    param([string]$CardPath, [long]$CardSize, [string]$ImagePath)
    $expected = Read-Sidecar $ImagePath
    if (-not $expected) { $expected = [StorioTool.Core]::HashFile($ImagePath, 'Hashing backup') }
    $len = (Get-Item -LiteralPath $ImagePath).Length
    if ($len -gt $CardSize) { return $false }
    $r = [StorioTool.Dev]::Open($CardPath, $false, $CardSize, $null)
    try { $h = [StorioTool.Core]::CopyHash($r, 0, $null, 0, $len, 'Reading card     ') } finally { $r.Dispose() }
    return ($h -eq $expected)
}

function Invoke-FixPersist {
    param([string]$CardPath, [long]$CardSize, [string[]]$Volumes, [string]$BackupPath, [switch]$CheckOnly)
    if (-not (Read-Sidecar $BackupPath)) { throw 'A verified backup of this card is required (option 1).' }
    $c = [StorioTool.Dev]::Open($CardPath, $false, $CardSize, $null)
    $targets = @()
    try {
        $Lc = [StorioTool.Core]::Resolve($c)
        if (-not $Lc.Verified) { throw 'Could not verify the partition table of the CARD.' }
        $cardLen = $c.Length
        foreach ($pn in @('data', 'userdata')) {
            $p = $Lc.Get($pn)
            if (-not $p -or $p.Check -ne 'ext4') { continue }
            $pp = [StorioTool.Core]::ReadPersist($c, $p.Start)
            if ([StorioTool.Core]::PersistNeedsFix($pp)) { $targets += $p }
        }
    } finally { $c.Dispose() }
    Test-SameCard $Lc $cardLen $BackupPath
    if ($CheckOnly -or $targets.Count -eq 0) { return ,$targets }
    $w = [StorioTool.Dev]::Open($CardPath, $true, $CardSize, $Volumes)
    $changes = ''
    try {
        foreach ($p in $targets) { $changes += [StorioTool.Core]::PatchPersist($w, $p.Start) }
    } finally { $w.Dispose() }
    $r = [StorioTool.Dev]::Open($CardPath, $false, $CardSize, $null)
    try {
        foreach ($p in $targets) {
            $left = [StorioTool.Core]::PersistNeedsFix([StorioTool.Core]::ReadPersist($r, $p.Start))
            if ($left) { throw "Verification failed on '$($p.Name)': $left" }
        }
    } finally { $r.Dispose() }
    return $changes
}

function Get-Contents {
    param([string]$ImagePath, [string]$OutFile)
    $d = [StorioTool.Dev]::Open($ImagePath, $false, 0, $null)
    $lines = New-Object System.Collections.Generic.List[string]
    $apks = New-Object System.Collections.Generic.List[string]
    try {
        $L = [StorioTool.Core]::Resolve($d)
        if (-not $L.Verified) { throw 'Could not verify the partition table.' }
        foreach ($pn in @('system', 'data', 'userdata')) {
            $p = $L.Get($pn)
            if (-not $p -or $p.Check -ne 'ext4') { continue }
            $fs = New-Object StorioTool.Ext4($d, $p.Start)
            $root = if ($pn -eq 'system') { '/app' } else { '/' }
            $t = $fs.Tree($root, 50000)
            $lines.Add("===== $pn ($root) - $($t.Count) entries =====")
            $total = [long]0
            foreach ($entry in $t) {
                $parts = $entry.Split("`t", 2)
                $sz = 0L; [void][long]::TryParse($parts[0], [ref]$sz); $total += $sz
                $lines.Add(('{0,12}  {1}' -f $parts[0], $parts[1]))
                if ($parts[1] -match '\.(apk|obb|zip|dat|pak|bin|vt\w*)$' -and $sz -gt 1MB) { $apks.Add(('{0,-6} {1,10}  {2}' -f $pn, (Fmt $sz), $parts[1])) }
            }
            $lines.Add("  Total files: $(Fmt $total)")
            $lines.Add('')
        }
    } finally { $d.Dispose() }
    $head = New-Object System.Collections.Generic.List[string]
    $head.Add("Contents of $ImagePath")
    $head.Add('')
    $head.Add('== Large files (apk, obb, data packages > 1 MB) ==')
    foreach ($a in $apks) { $head.Add("  $a") }
    $head.Add('')
    ($head + $lines) | Set-Content -LiteralPath $OutFile -Encoding UTF8
    return $apks
}

function Find-Chdman {
    $cands = @()
    $here = Split-Path -Parent $PSCommandPath
    if ($here) { $cands += (Join-Path $here 'chdman.exe') }
    $cmd = Get-Command chdman -ErrorAction SilentlyContinue
    if ($cmd) { $cands += $cmd.Source }
    $cands += @('C:\mame\chdman.exe', "$env:ProgramFiles\MAME\chdman.exe", "$env:USERPROFILE\Downloads\mame\chdman.exe")
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return $null
}

# ------------------------------------------------------------------ menu

function Show-Header {
    Clear-Host
    Say '  ==============================================================' DarkCyan
    Say "   STORIO TV / INNOTV  -  Card tool   v$Script:ToolVersion" White
    Say '  ==============================================================' DarkCyan
    Say "   Working folder: $Script:WorkDir" DarkGray
    $last = Get-LatestBackup
    if ($last) { Say "   Latest backup: $($last.Name)" DarkGray } else { Say '   There is no backup yet. Start with option 1.' Yellow }
    Say ''
}

function Menu-Backup {
    Say '  FULL BACKUP OF THE CARD' White
    Say '  If Windows asks you to "format the disk", ALWAYS click Cancel.' Yellow
    $card = Select-Card; if (-not $card) { return }
    $name = 'backup_{0:yyyyMMdd_HHmm}.img' -f (Get-Date)
    $out = Join-Path $Script:WorkDir $name
    Say "  It will be saved to: $out" Cyan
    Say "  Size: $(Fmt $card.Size). It will take several minutes (read + verification)." Cyan
    if (-not (Confirm-Yes 'Start?')) { return }
    $h = Invoke-Backup -CardPath $card.Path -CardSize $card.Size -OutFile $out
    Say "  Backup completed and verified." Green
    Say "  SHA-256: $h" DarkGray
    Say '  Analysing the backup...' Cyan
    $res = Get-Analysis -Path $out
    Save-Analysis $res $out
    $res.Report | ForEach-Object { Say "  $_" }
    Say "`n  Report saved to $out.analysis.txt" Green
    Say '  Also copy the backup somewhere else (external drive, cloud) just in case.' Yellow
}

function Menu-Analyze([bool]$fromCard) {
    if ($fromCard) {
        $card = Select-Card; if (-not $card) { return }
        $res = Get-Analysis -Path $card.Path -Length $card.Size
        $base = Join-Path $Script:WorkDir ('card_{0:yyyyMMdd_HHmm}' -f (Get-Date))
    } else {
        $img = Select-Backup 'Choose the backup (.img) to analyse'; if (-not $img) { return }
        $res = Get-Analysis -Path $img
        $base = $img
    }
    Save-Analysis $res $base
    $res.Report | ForEach-Object { Say "  $_" }
    Say "`n  Report saved to $base.analysis.txt" Green
    if ($res.BuildProp) { Say "  Full build.prop in $base.build.prop.txt" Green }
}

function Menu-Verify {
    $img = Select-Backup 'Choose the backup (.img) to compare with'; if (-not $img) { return }
    $card = Select-Card; if (-not $card) { return }
    if (Test-CardVsImage -CardPath $card.Path -CardSize $card.Size -ImagePath $img) {
        Say '  The card is IDENTICAL to the backup.' Green
    } else {
        Say '  The card is DIFFERENT from the backup (normal if the console has been used since the backup, or if you have written something).' Yellow
    }
}

function Menu-Extract {
    $img = Select-Backup 'Choose the backup (.img)'; if (-not $img) { return }
    $leaf = ((Split-Path -Leaf $img) -replace '\.img$', '') + '_partitions'
    $dir = Join-Path (Split-Path -Parent $img) $leaf
    Say '  1) Only boot and system (recommended)   2) All fixed-size partitions'
    $o = Read-Host '  Option'
    $names = if ($o -eq '2') { $null } else { @('boot', 'system') }
    $files = Invoke-Extract -ImagePath $img -OutDir $dir -Names $names
    Say "  Extracted $($files.Count) partitions to $dir" Green
}

function Menu-Adb {
    Say '  CREATE SYSTEM WITH ADB ENABLED' White
    Say '  A NEW file is created from the backup; the backup is not modified.' DarkGray
    $img = Select-Backup 'Choose the backup (.img)'; if (-not $img) { return }
    $out = Join-Path (Split-Path -Parent $img) ('system_adb_{0:yyyyMMdd_HHmm}.img' -f (Get-Date))
    $changes = New-AdbSystem -ImagePath $img -OutFile $out
    if (-not $changes) {
        Say '  build.prop already had ADB enabled; nothing needed to be changed.' Yellow
        return
    }
    Say '  Changes in build.prop:' Cyan
    Say $changes
    Say "  Created and verified: $out" Green
    Say '  To use it, write this file to the card with option 7 (system partition).' Cyan
}

function Menu-Flash {
    Say '  WRITE A PARTITION TO THE CARD' White
    $file = Select-File 'Choose the partition image to write (e.g. system_adb_....img)' $Script:WorkDir
    if (-not $file) { return }
    $guess = if ((Split-Path -Leaf $file) -match '^(system|boot)') { $Matches[1] } else { '' }
    $name = Read-Host "  Which partition should it be written to? (system/boot) [$guess]"
    if (-not $name) { $name = $guess }
    if (@('system', 'boot') -notcontains $name) { Say '  Only system or boot can be written.' Red; return }
    Say '  Now choose the BACKUP of this same card (to check that it is the right card).' Cyan
    $bk = Select-Backup 'Choose the backup of the card'; if (-not $bk) { return }
    $card = Select-Card; if (-not $card) { return }
    $p = Invoke-FlashPartition -CardPath $card.Path -CardSize $card.Size -Volumes @() -PartFile $file -PartName $name -BackupPath $bk -CheckOnly
    Say "  Checks passed: card = backup, '$name' at sector 0x$('{0:X}' -f ($p.Start/512)), $(Fmt $p.Len)." Green
    if (-not (Confirm-Danger "partition '$name' of disk $($card.Number) ($($card.Name)) is about to be overwritten")) { Say '  Cancelled.'; return }
    $vols = Get-CardVolumes $card.Number
    [void](Invoke-FlashPartition -CardPath $card.Path -CardSize $card.Size -Volumes $vols -PartFile $file -PartName $name -BackupPath $bk)
    try { Update-Disk -Number $card.Number -ErrorAction SilentlyContinue } catch { }
    Say "  Partition '$name' written and verified." Green
    Say '  Put the card back in the console, switch it on and connect it via USB.' Cyan
}

function Menu-Restore {
    Say '  RESTORE A FULL BACKUP' White
    $img = Select-Backup 'Choose the backup (.img) to restore'; if (-not $img) { return }
    if (-not (Read-Sidecar $img)) {
        Say '  This file has no .sha256: it cannot be checked for integrity.' Yellow
        if (-not (Confirm-Yes 'Continue anyway?')) { return }
    }
    $res = Get-Analysis -Path $img
    if (-not $res.Layout.Verified) {
        Say '  Warning: this file does not look like a Storio TV card.' Yellow
        if (-not (Confirm-Yes 'Continue anyway?')) { return }
    }
    $card = Select-Card; if (-not $card) { return }
    $imgLen = (Get-Item -LiteralPath $img).Length
    if ($imgLen -gt $card.Size) { Say "  The card ($(Fmt $card.Size)) is smaller than the backup ($(Fmt $imgLen)). Use a bigger card." Red; return }
    if ($imgLen -lt $card.Size) { Say "  The card is larger than the backup; the extra space will not be used (this is fine)." DarkGray }
    if (-not (Confirm-Danger "ALL of disk $($card.Number) ($($card.Name), $(Fmt $card.Size)) is about to be ERASED and replaced with the backup")) { Say '  Cancelled.'; return }
    $vols = Get-CardVolumes $card.Number
    [void](Invoke-Restore -CardPath $card.Path -CardSize $card.Size -Volumes $vols -ImagePath $img)
    try { Update-Disk -Number $card.Number -ErrorAction SilentlyContinue } catch { }
    Say '  Backup restored and verified.' Green
}

function Menu-FixPersist {
    Say '  FIX THE USB SETTING SAVED ON THE CARD' White
    Say '  Android saves a USB setting in /data/property that takes precedence over build.prop.' DarkGray
    Say '  If it says "mtp" (without adb), ADB will not start even if you have written the system with ADB.' DarkGray
    $bk = Select-Backup 'Choose the backup of this card'; if (-not $bk) { return }
    $card = Select-Card; if (-not $card) { return }
    $t = Invoke-FixPersist -CardPath $card.Path -CardSize $card.Size -Volumes @() -BackupPath $bk -CheckOnly
    if ($t.Count -eq 0) { Say '  There is no saved setting that disables ADB. Nothing needs to be done.' Green; return }
    Say "  The setting needs to be fixed in: $(($t | ForEach-Object { $_.Name }) -join ', ')" Cyan
    if (-not (Confirm-Danger "a small file on the card in disk $($card.Number) ($($card.Name)) is about to be modified")) { Say '  Cancelled.'; return }
    $vols = Get-CardVolumes $card.Number
    $ch = Invoke-FixPersist -CardPath $card.Path -CardSize $card.Size -Volumes $vols -BackupPath $bk
    try { Update-Disk -Number $card.Number -ErrorAction SilentlyContinue } catch { }
    Say $ch
    Say '  Setting fixed and verified.' Green
}

function Menu-Chd {
    Say '  CONVERT A .CHD FILE TO .IMG AND ANALYSE IT' White
    $chd = Select-File 'Choose the .chd file' $Script:WorkDir
    if (-not $chd) { return }
    $chdman = Find-Chdman
    if (-not $chdman) {
        Say '  chdman.exe not found. It is included with MAME (https://www.mamedev.org/release.html).' Yellow
        Say '  Download MAME for Windows, unzip it and copy chdman.exe to the folder of this tool.' Yellow
        return
    }
    Say '  CHD information:' Cyan
    & $chdman info -i $chd | ForEach-Object { Say "    $_" }
    $out = Join-Path $Script:WorkDir (([System.IO.Path]::GetFileNameWithoutExtension($chd)) + '_chd.img')
    if (Test-Path -LiteralPath $out) { Say "  $out already exists; analysing that one." Yellow }
    else {
        if ((Get-FreeSpace $out) -lt 9GB) { throw 'About 9 GB of free space is needed to decompress the CHD.' }
        if (-not (Confirm-Yes "Decompress to $out ?")) { return }
        & $chdman extracthd -i $chd -o $out
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $out)) { throw 'chdman could not decompress the file (is it not a hard disk/card image?).' }
        $h = [StorioTool.Core]::HashFile($out, 'Computing SHA-256')
        Write-Sidecar $out $h
    }
    $res = Get-Analysis -Path $out
    Save-Analysis $res $out
    $res.Report | ForEach-Object { Say "  $_" }
    Say "`n  Report saved to $out.analysis.txt" Green
}

function Menu-Contents {
    Say '  VIEW APPS AND GAMES INSIDE AN IMAGE' White
    $img = Select-File 'Choose the image (.img) to inspect' $Script:WorkDir
    if (-not $img) { return }
    $out = "$img.contents.txt"
    $apks = Get-Contents -ImagePath $img -OutFile $out
    Say '  Large files found:' Cyan
    foreach ($a in $apks) { Say "    $a" }
    Say "`n  Full listing in $out" Green
}

function Start-Menu {
    if (-not ($IsLinux -or $IsMacOS)) {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Say '  This must be run as administrator. Reopening...' Yellow
            Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
            return
        }
    }
    if (-not (Test-Path -LiteralPath $Script:WorkDir)) { New-Item -ItemType Directory -Path $Script:WorkDir | Out-Null }
    try { Start-Transcript -Path (Join-Path $Script:WorkDir 'log.txt') -Append | Out-Null } catch { }
    while ($true) {
        Show-Header
        Say '   1) Make a full backup of the card (with verification)'
        Say '   2) Analyse a backup (partitions, firmware version, ADB)'
        Say '   3) Analyse the card directly (read-only)'
        Say '   4) Check whether the card is identical to a backup'
        Say '   5) Extract partitions from a backup'
        Say '   6) Create a system partition with ADB enabled'
        Say '   7) Write a partition to the card (system or boot)' Yellow
        Say '   8) Fix the USB setting saved on the card (data)' Yellow
        Say '   9) Restore a full backup to the card' Yellow
        Say '  10) Convert a .chd file to .img and analyse it'
        Say '  11) View apps and games inside an image'
        Say '  12) Open the working folder'
        Say '   0) Exit'
        Say ''
        $o = Read-Host '  Choose an option'
        Say ''
        if ($o -eq '0') { try { Stop-Transcript | Out-Null } catch { }; return }
        if ($o -eq '12') { Start-Process explorer.exe $Script:WorkDir; continue }
        if ('1','2','3','4','5','6','7','8','9','10','11' -notcontains $o) { continue }
        try {
            switch ($o) {
                '1' { Menu-Backup }
                '2' { Menu-Analyze $false }
                '3' { Menu-Analyze $true }
                '4' { Menu-Verify }
                '5' { Menu-Extract }
                '6' { Menu-Adb }
                '7' { Menu-Flash }
                '8' { Menu-FixPersist }
                '9' { Menu-Restore }
                '10' { Menu-Chd }
                '11' { Menu-Contents }
            }
        } catch {
            Say ''
            $e = $_.Exception
            while ($e.InnerException) { $e = $e.InnerException }
            Say "  ERROR: $($e.Message)" Red
            Say '  The operation was not completed.' Red
        }
        Pause-Tool
    }
}

if (-not $NoMenu) { Start-Menu }
