# Storio TV / InnoTV - SD card tool (v1.2)

A Windows tool for backing up, analysing, restoring and patching the internal
microSD card of a VTech Storio TV (InnoTV) console. It works with the raw disk,
understands the Rockchip partition table (PARM block), and has a small ext4
reader/writer to inspect and patch `build.prop` and `/data/property`. This is how
it enables ADB.

**Use at your own risk.** Always make a backup first (option 1) and keep a copy
of it somewhere safe.

## Requirements

- Windows with Windows PowerShell 5.1 (included with Windows 10/11)
- Administrator rights (needed for raw disk access)
- A microSD card reader
- Optional: `chdman.exe` from [MAME](https://www.mamedev.org/release.html) for option 10

## Usage

1. Extract the folder somewhere convenient, for example to the desktop.
2. Put the console's microSD card into the PC.
   If Windows says **"You need to format the disk"**, ALWAYS click **Cancel**.
3. Double-click **`Start.bat`** and accept the administrator prompt.
   `Start.bat` requests admin rights and runs `StorioTV-Tool.ps1`.
4. The FIRST thing to do is option 1 (backup). Then copy that backup somewhere else,
   such as an external drive or cloud storage.

Everything is saved to **`Documents\StorioTV`**. A session log is written to
`Documents\StorioTV\log.txt`.

## Menu options

| # | Option | What it does |
|---|--------|--------------|
| 1 | Full backup of the card | Reads the card twice and checks the saved file (SHA-256). Saves `backup_YYYYMMDD_HHMM.img` plus a `.sha256` file, then analyses it (`.analysis.txt`). If the two reads do not match, or the saved file does not match the card, it warns you and renames the file with an `.UNRELIABLE` suffix. If the copy is interrupted, the partial file gets an `.INCOMPLETE` suffix. |
| 2 | Analyse a backup | Shows the partitions, firmware version and ADB status. Generates `.analysis.txt`, `.build.prop.txt` and `.default.prop.txt`. These are the files to share if you need help. |
| 3 | Analyse the card directly | Same as option 2, but reads the card directly (read-only). Output files are named `card_YYYYMMDD_HHMM.*`. |
| 4 | Check card vs backup | Checks whether the card is identical to a backup. |
| 5 | Extract partitions | Extracts partitions (boot and system only, or all fixed-size partitions) to `.img` files in a `<backup>_partitions` folder. Each file gets its own `.sha256`. |
| 6 | Create a system partition with ADB enabled | Copies the system partition from the backup to a NEW file (`system_adb_YYYYMMDD_HHMM.img`) and patches its `build.prop`. The backup is never modified. Also writes `.build.prop.original.txt`, `.build.prop.new.txt`, `.info.txt` and `.sha256`. |
| 7 | Write a partition to the card (system or boot) | First checks that the card matches the backup (same partition table and size), that the file size matches the partition, and that the file is intact (`.sha256`). After writing, it reads the card back to verify. |
| 8 | Fix the USB setting saved on the card (data) | Android saves a USB setting in `/data/property` that takes precedence over `build.prop`. If it says `mtp` (without `adb`), ADB will not start. This option modifies only that small file, directly on the card, and verifies it. |
| 9 | Restore a full backup | Checks the backup's SHA-256 and that the card is not smaller than the backup, writes it, then verifies the result. |
| 10 | Convert a `.chd` file to `.img` and analyse it | Uses `chdman.exe` (included with MAME) to convert a CHD image. Copy `chdman.exe` into the tool's folder. About 9 GB of free space is needed. |
| 11 | View apps and games inside an image | Lists `system/app`, `data` and `userdata`, and saves the full listing to `.contents.txt`. Large files (apk, obb, data packages > 1 MB) are summarised at the top. |
| 12 | Open the working folder | Opens `Documents\StorioTV` in File Explorer. |
| 0 | Exit | |

Options **7, 8 and 9 write to the card**. To confirm, you must type **`WRITE`**
(in capitals). Yes/no questions accept `y` / `yes`.

For safety, the system disk and disks larger than 64 GB are never offered.

## Enabling ADB (step order)

1. **Option 1**: make a full backup.
2. **Option 2**: analyse the backup.
3. **Option 6**: create a system partition with ADB enabled.
4. **Option 7**: write it to the card (choose the `system` partition).
5. **Option 8**: only if the analysis says so (a saved USB setting in `data`/`userdata` disables ADB).
6. Put the card back in the console.
7. Connect the console to the PC via USB.

In short: `1 -> 2 -> 6 -> 7 (system) -> 8 (if the analysis says so) -> card back into the console -> USB`.

Notes from the analysis:

- `ro.secure=1`: ADB gives you a shell **without root**. This is enough to install APKs.
- `ro.adb.secure=1`: ADB asks you to authorise the PC on screen. If the console does
  not show the prompt, ADB will not work.

If anything goes wrong, use **option 9** with your backup to put the console back
the way it was.

## Building from source

`StorioTV-Tool.ps1` is generated from the files in `src/`:

- `src/menu.ps1`: the PowerShell menu and operations
- `src/core.cs`: C# 5 code (raw disk access, Rockchip partition table, ext4
  reader/writer) that is embedded and compiled at runtime with `Add-Type`
- `src/build.py`: replaces the `#__CORE__` line in `menu.ps1` with `core.cs` and writes `../StorioTV-Tool.ps1`

```
cd src
python3 build.py
```

`core.cs` must stay C# 5 compatible. Windows PowerShell 5.1 compiles it with the
old .NET Framework compiler, so do not use string interpolation, `?.`,
expression-bodied members, and similar C# 6+ features.

## Disclaimer

This tool writes directly to raw disks. It includes several safety checks, but
you use it entirely **at your own risk**. Always keep a verified backup of your card.
