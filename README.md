# Storio TV / InnoTV toolkit

Tools, documentation and a DOOM port for the **VTech Storio TV** (also sold as **InnoTV** / **InnoTab TV**), a 2015 kids' TV console whose online services have been shut down by VTech.

Everything here was developed and tested on a French Storio TV (firmware `eng.vtech.20150904`, internally `ITMAX_1836`, Android 4.2.2, Rockchip RK3168). Other regions should be very similar, but always check with the analysis tools first.

| Folder | What it does |
|---|---|
| [`sd-tool/`](sd-tool/) | Back up, analyse, verify, restore and patch the console's internal microSD card. **Enables ADB (as root).** |
| [`diagnostics/`](diagnostics/) | Read-only information gathering over ADB, including what happens when a cartridge is inserted, and a controller/wheel event capture. |
| [`doom/`](doom/) | DOOM for the console: VTech controller + wheel, sound effects and FM music, icon in the VTech games menu. GPLv2. |
| [`game-backup/`](game-backup/) | Back up installed games (cartridge games and games downloaded from the defunct VTech store) and their save data. |
| [`cart-reader/`](cart-reader/) | Dump an InnoTV / InnoTab MAX cartridge's NAND chip from the console itself (MAME layout) and verify it. |
| [`docs/TECHNICAL.md`](docs/TECHNICAL.md) | How the console works inside: partitions, ADB, the VTech desktop database, controller codes, building apps for Android 4.2 without the NDK, cartridge format. |

## Requirements

- Windows 10/11 with Windows PowerShell 5.1 (built in). Run scripts with
  `powershell -ExecutionPolicy Bypass -File <script>.ps1`
- [Android SDK Platform-Tools](https://developer.android.com/tools/releases/platform-tools) (adb). The scripts look for
  `%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe` first and then the `PATH`.
- A microSD card reader (for `sd-tool` only).
- Building from source (DOOM, cart reader): Linux with clang/lld/llvm 14+, python3, openssl, git, curl, unzip.

> **The console only finishes booting Android with HDMI connected to a TV that is switched on.** Without HDMI, adb connects but the package manager never starts. The scripts wait for `sys.boot_completed`.

## Quick start

1. **Back up the internal microSD** and **enable ADB** with `sd-tool` (options 1 -> 2 -> 6 -> 7 -> 8 if needed). Keep the backup in two places: with it, everything is reversible.
2. Put the card back, connect HDMI and USB, check `adb shell id` shows `uid=0(root)`.
3. Install DOOM: download `doom.apk` from the [Releases](../../releases) page into `doom/`, then run `doom/Install-DOOM.ps1` and `doom/Add-To-Menu.ps1`.
4. Back up your games with `game-backup/Backup-Games.ps1`.

## Known limitations (tested, not possible)

- **Language** is fixed in a factory "UniqueKey" block (e.g. `FRfre`); the VTech apps read it from there, not from Android's locale.
- **Old Storio 2 / InnoTab cartridges** need the TV version of the game downloaded from VTech's servers, which no longer exist.
- **InnoTV / InnoTab MAX cartridge games** only run with the cartridge inserted: the console installs the (encrypted) game from the cartridge and removes it when the cartridge is pulled. This project does **not** attempt to bypass that copy protection.
- There is no newer firmware available any more (updates were delivered online).

## Preservation

If you own InnoTV / InnoTab MAX cartridges, `cart-reader` can dump them without opening anything. MAME's software list `vtech_innotv_cart` only contains a handful of carts; dumps can be offered to the MAME developers on their [forum](https://forum.mamedev.org/) (with photos of the label and PCB). Please **do not** share copyrighted dumps publicly.

## Contributing

Issues and pull requests are welcome: other regions/firmware versions, more controller mappings, more ports of free/open-source games, cartridge information...

## Credits and license

Created by **Brutal Turok** (with the help of Claude, an AI assistant by Anthropic).
MIT license for the tools (see [LICENSE](LICENSE)); the `doom/` folder is GPLv2 (doomgeneric + Chocolate Doom) and bundles Freedoom (BSD).
Not affiliated with VTech. Use at your own risk: always keep a backup of your console's microSD.
