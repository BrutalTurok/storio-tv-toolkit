# Storio TV / InnoTV - cartridge reader

Reads the memory chip of the cartridge inserted in a VTech Storio TV / InnoTV
(also InnoTab MAX / Storio MAX cartridges) using the console itself, without
opening the cartridge. It dumps the whole NAND, including the spare area (OOB)
of every page, in the layout MAME uses.

**Read-only:** nothing is ever written to the cartridge.

## Requirements

- Windows with Windows PowerShell 5.1 (included with Windows 10/11)
- `adb` (Android SDK platform-tools; the script looks in
  `%LOCALAPPDATA%\Android\Sdk\platform-tools` first, then in `PATH`)
- A console with **root ADB** enabled (see `../sd-tool`)
- About **550 MB free** in the console's internal storage (`/sdcard`): the dump
  is written there first and then copied to the PC

## Usage

Console switched on (with HDMI connected), USB cable connected, cartridge inserted:

    powershell -ExecutionPolicy Bypass -File Read-Cartridge.ps1

`Read-Cartridge.ps1` and the `cart_reader` binary must be in the same folder.
The script:

1. pushes `cart_reader` to `/data/local/tmp/cart_reader` and runs it, writing to
   `/sdcard/cart_dump` (a few minutes; do not remove the cartridge),
2. copies the result to the PC and removes the temporary files from the console,
3. verifies the dump: it walks the FAT file system inside `cart_data.bin` and
   checks that the MD5 of the game (`MAIN.ITA`) matches the `main.ita.md5` file
   stored next to it on the cartridge,
4. computes the hashes for MAME / No-Intro.

## Output

Everything goes to `Documents\StorioTV\cartridges\<part number>_<date>\`:

| File | Contents |
|------|----------|
| `cart_raw.bin` | Raw NAND: each page is 2048 data bytes followed by 128 spare (OOB) bytes, the MAME layout. 285,212,672 bytes (272 MiB) for a 256 MiB cartridge. |
| `cart_data.bin` | Data pages only (256 MiB): what the console's file system sees. |
| `hashes.txt` | Size, CRC32, MD5, SHA1 and SHA256 of both files, the result of the `MAIN.ITA` check, and the key lines of the report. |
| `report.txt` | Chip info, `/proc/mtd`, bad blocks, read errors and the final `RESULT: OK` / `RESULT: ERRORS` line. |

## Known limitation: spare area

The cartridge chip (Toshiba TC58NVG1S3HTA00) has 2048 + 128 bytes per page, but
the VTech MTD driver only exposes **8 OOB bytes per page**. `cart_reader` reads
what the driver provides and pads the remaining 120 bytes of each page's spare
area with `0xFF` (the report says so with a `WARNING` line). Because of this,
`cart_raw.bin` will **not** match a dump made with a NAND programmer
byte-for-byte. The data area is exact: `cart_data.bin` (and the data part of
every page in `cart_raw.bin`) is what the chip holds, and it is verified through
the `MAIN.ITA` MD5 check.

## Files

    Read-Cartridge.ps1        Windows script (run this)
    cart_reader               prebuilt static ARM binary that runs on the console
    src/cart_reader.c         the reader: freestanding, no libc, raw Linux syscalls
    src/aeabi_int.c           ARM EABI division / memory helpers (no libgcc needed)
    src/build.sh              build script
    src/tests/make_test_fat.py  builds a small FAT16 test image

`cart_reader` finds the cartridge in `/proc/mtd` (a partition whose name contains
`Inno`, `VFAT` or `Cart`), opens `/dev/mtd/mtdN` or `/dev/mtdN` (or, failing
that, creates a device node at `/data/local/tmp/mtd_reader`), and reads every
page plus its OOB with `MEMREADOOB`. It can also be run by hand from an
`adb shell`: `/data/local/tmp/cart_reader [output dir]` (default `/sdcard/cart_dump`).

## Building

Needs `clang`, `ld.lld` and `llvm-strip` (any recent LLVM; no ARM sysroot or
libc needed):

    src/build.sh

This produces `src/cart_reader`; copy it next to `Read-Cartridge.ps1`.

## Testing on a PC (qemu)

Building with `-DTEST` replaces the MTD ioctls with an emulation (a 4 MiB chip,
2048-byte pages, 64 OOB bytes per page filled with `(page + i) & 255`, block 3
marked bad) and reads `/tmp/cart_reader_test/fake_procmtd` and
`/tmp/cart_reader_test/fake_mtd` instead of the real devices:

    T=/tmp/cart_reader_test; mkdir -p $T
    clang --target=armv7a-linux-gnueabi -marm -march=armv7-a -mfloat-abi=soft -O2 \
      -ffreestanding -fno-builtin -nostdlib -static -fno-pie -fuse-ld=lld \
      -fno-stack-protector -fno-unwind-tables -fno-asynchronous-unwind-tables \
      -Wl,--gc-sections -DTEST src/cart_reader.c src/aeabi_int.c -o $T/cart_reader_test
    printf 'dev:    size   erasesize  name\nmtd0: 10000000 00020000 "Inno_FC0_VFAT"\n' > $T/fake_procmtd
    head -c 4194304 /dev/urandom > $T/fake_mtd
    qemu-arm-static $T/cart_reader_test $T/out

Expected: `RESULT: OK`, `out/cart_data.bin` identical to `fake_mtd`, and
`out/cart_raw.bin` of 2048 x 2176 bytes where each page is followed by 64
pattern bytes and 64 bytes of `0xFF`.

The C# FAT checker inside `Read-Cartridge.ps1` can be tested with an image from
`python3 src/tests/make_test_fat.py test.img` (it prints the expected MD5 of
`MAIN.ITA`).
