# Storio TV / InnoTV - technical notes

What was found while working on a reference console (French Storio TV, October 2026). Exact numbers may differ between regions or firmware versions: always confirm them with the `sd-tool` analysis.

## 1. Hardware and system

- Rockchip RK3168 SoC (board `rk30sdk_rtl8723`), ARMv7, Android 4.2.2 (API 17).
- Firmware: `rk30sdk_rtl8723-eng 4.2.2 JDQ39 eng.vtech.20150904.171232 test-keys` (VTech calls it `ITMAX_1836`, platform "TV"). Same software base as the InnoTab MAX tablet.
- No soldered storage: the whole system lives on an 8 GB microSD card inside the console.
- 1280x720 HDMI output. **Without HDMI connected, Android never finishes booting.**
- MAME has a partial driver: `src/mame/vtech/innotv_innotabmax.cpp` (internal SD image `8gb_sdhc_internal`, cartridge list `vtech_innotv_cart`).

## 2. The internal microSD

Rockchip partition table: PARM block at byte 4194304. Addresses in `mtdparts` are 512-byte sectors and are relative to a base of `0x2000`:

| Partition | Start sector | Size | Content |
|---|---|---|---|
| misc | 0x4000 | 4 MB | |
| kernel | 0x6000 | 12 MB | KRNL |
| boot | 0xC000 | 12 MB | KRNL (ramdisk with default.prop) |
| recovery | 0x12000 | 32 MB | |
| backup | 0x22000 | 64 MB | |
| cache | 0x42000 | 128 MB | ext4 |
| kpanic | 0x82000 | 4 MB | |
| app | 0x84000 | 8 MB | |
| system | 0x88000 | 1.5 GB | ext4 (1024-byte blocks) |
| system2 | 0x388000 | 640 MB | |
| data | 0x4C8000 | 512 MB | ext4 |
| userdata | 0x5C8000 | rest | ext4 (Android's /data, including /data/property) |

### ADB

- `default.prop` (in boot) already has `ro.secure=0`, `ro.debuggable=1` and `persist.sys.usb.config=adb`, so once ADB is on, it runs **as root**.
- `system/build.prop` has `persist.sys.usb.config=mtp` and `persist.service.adb.enable=0`.
- On top of that, `/data/property` (in userdata) stores persistent properties that **override** build.prop. On the reference console an empty `persist.service.adb.enable` there kept ADB off.
- `sd-tool` options 6, 7 and 8 patch build.prop in a copy of the system partition, write it back and fix `/data/property`. This uses a small ext4 reader/writer written in C# (`sd-tool/src/core.cs`) that runs inside Windows PowerShell 5.1 with nothing to install.
- If Windows does not recognise the console over USB, it shows up as `rk30sdk_rtl8723` under "Other devices" in Device Manager: install Google's generic "Android ADB Interface" driver on it manually.

## 3. The VTech desktop (adding apps to the menu)

- The desktop (`com.vtech.innotab.TVDesktop`) lists what is in the database of VTech's package manager (`com.vtech.innotab.vpm`): `fakeapp.db`, encrypted with SQLCipher (key `"1668"` + console ID). **If the database cannot be opened, VPM deletes it**, so never edit it directly.
- Change it through VPM's own content provider with Android's `content` command:

| URI | Operation | Notes |
|---|---|---|
| `content://com.vtech.innotab.vpm.provider/full` | query | |
| `.../for_dev` | insert | register your own app: `FilePath`, `PartNO`, `Ver`, `Category`, `DisplayName`, `Description`, `ForceUpdate` |
| `.../verified/<PartNo>` | update | the `--where` selection must contain `Version` and `FileLocation` |
| `.../icon` | update | the selection must contain `_id` and `IconSupPath`; values must include `Icon` or `IconSup` |

- For an app to appear in the games section it needs `ConsoleType='|Game|'`, `VerifiedState=2`, `InstallState=0` and an `IconProcessedIcon`.
- The processed icon is produced by the `Service4CheckingNullIcon` service, which downloads `IconSupPath` over `http://` about 60 s after it starts. DOOM serves its own icon at `http://127.0.0.1:8737/doom.png` for this. Android 4.2 has no `am stopservice`; restart the service with `am force-stop com.vtech.innotab.vpm`.
- At boot, `VerifiedFileSever` checks that `FileLocation` exists and hides the app otherwise. Every `adb install -r` alternates the APK file name (`-1.apk` / `-2.apk`), so after reinstalling, `FileLocation` must be updated (`doom/Install-DOOM.ps1` does it).
- `doom/Add-To-Menu.ps1` saves a copy of `fakeapp.db` to `Documents\StorioTV\menu` before changing anything; `doom/Restore-Menu.ps1` puts it back.

## 4. The controller

- Devices: `/dev/input/eventvj1..4` (links to `event3..6`, "vtech joystick1..4", mode 0666) and `event2` ("vtech joystick0"). There is also a "vtech mouse" (`event8`).
- The D-pad reaches Android as normal keys (19-22) and also as raw `KEY_UP/DOWN/LEFT/RIGHT`.
- Buttons that do **not** reach Android as keys (read them raw, `EV_KEY`):

| Code | Button |
|---|---|
| `BTN_DEAD` 0x12f | main button |
| `KEY_GREEN` 0x18f | green |
| `KEY_RED` 0x18e | red |
| `KEY_HELP` 138 | help |
| 0x229, 0x220, 0x222 | other buttons |

- **Wheel:** `EV_REL REL_WHEEL` with values **centred on 128**: 148 = one click clockwise, 108 = counter-clockwise, 128 = rest (not +1/-1 like a mouse).
- Accelerometer: `EV_ABS ABS_TILT_X`, `ABS_TILT_Y`, `ABS_Z` (constant noise; ignore).
- `diagnostics/Capture-Wheel.ps1` and `doom/Show-Buttons.ps1` show the codes of any controller.

## 5. Building apps for the console (lessons from DOOM)

- Compiled **without the NDK**: `clang --target=armv7a-linux-androideabi17`, minimal own headers (`doom/src/inc`) and stub libraries generated from the missing symbols, only for linking. Link with lld using `--hash-style=sysv` and `-z norelro` (Android 4.2's linker understands neither GNU hash nor modern RELRO). Some ARM helper functions (`__aeabi_*`) are missing: see `doom/src/storio/aeabi.c`.
- `NativeActivity` with no Java at all. The binary `AndroidManifest.xml` and a minimal `resources.arsc` are generated by `doom/src/tools/mkapk.py`.
- **Signing:** Android 4.2 rejects modern jarsigner signatures (`INSTALL_PARSE_FAILED_NO_CERTIFICATES`). Sign v1 with SHA1 and an `rsaEncryption` SignerInfo without signed attributes: `doom/src/tools/signv1.py` does this with openssl. To update an installed app without uninstalling it, it must be signed with the **same key**.
- Sound: OpenSL ES declared by hand (`sl_out.c`), queue of 2 buffers of 256 frames at 44100 Hz (~12 ms). FM music is Chocolate Doom 2.1.0's OPL emulator (`doom/src/opl`). Android has no `/tmp`: anything that needs temporary files must use the app's own directory. The emulated OPL is very quiet: DOOM multiplies it by 4 and removes its DC offset.
- Everything is logged to logcat; `adb logcat -d -v time` is the best debugging tool.

## 6. Cartridges

- InnoTV / InnoTab MAX cartridges: Toshiba `TC58NVG1S3HTA00` 2 Gbit NAND (256 MiB), 2048 + 128-byte pages, 64 pages per block, 2048 blocks. The console exposes it as `/dev/mtd/mtd0` (`Inno_FC0_VFAT`) and mounts it read-only as FAT on `/mnt/cart0`.
- Contents: `<part number>.<hash>/CODE/MAIN.ITA` (the encrypted app: header `VITMax`, `InnoEnc 00.02`), `CODE/main.ita.md5`, `DATA/ICON.PNG`, plus `__RESERVED_SPACE__.bin`.
- When a cartridge is inserted, `CartReceiver` detects it (`ITMAX/<part number>`) and Android decrypts and installs the app as a forward-locked app in `/data/app-private/com.vtech.innotab.cart.mNN_...`. When the cartridge is removed the app is gone. Save data stays in `/data/data/<package>`.
- Old Storio 2 / InnoTab cartridges: the console has to download the TV version from VTech's servers (now closed), so they do not work.
- MAME stores cartridges as a full chip dump with the spare area interleaved (2048 + 128 per page = 285,212,672 bytes), file `TC58NVG1S3HTA00.u1`.
- The VTech MTD driver only exposes 8 spare (OOB) bytes per page: `cart-reader` pads the other 120 with 0xFF. A byte-identical MAME-style dump requires a chip programmer (e.g. XGecu T48 / TL866II+ with a TSOP48 adapter).
- Reference dump: Frozen (French), `80-274505-005-001`, `MAIN.ITA` MD5 `7AFA4BD3BCBC3871D2416BE6EF07E28B`, bad blocks 1536 and 1537.

## 7. Building from source

- **DOOM** (Linux): `cd doom/src && ./build.sh` produces `build/doom.apk`. It fetches doomgeneric (commit `e257a09`) and Freedoom 0.13.0, applies the patch and builds. Set `SIGN_KEY`/`SIGN_CERT` to sign with an existing key; otherwise a new key is generated in `doom/src/signing/` (an APK signed with a different key must be uninstalled before installing). The version is set in `tools/mkapk.py`.
- **Cartridge reader**: `cd cart-reader/src && ./build.sh`. It is a static ARM executable with no libc (raw syscalls only), so it runs on any ARM Android. Building with `-DTEST` uses a simulated chip; it was tested with `qemu-arm`.
- **SD tool**: `cd sd-tool/src && python3 build.py` embeds `core.cs` into `menu.ps1` and writes `../StorioTV-Tool.ps1` (PowerShell compiles the C# at start-up).
