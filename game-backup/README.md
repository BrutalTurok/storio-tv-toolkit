# Storio TV / InnoTV - game backup

`Backup-Games.ps1` backs up the games installed on a VTech Storio TV / InnoTV
console over ADB. It only reads from the console: nothing is deleted or changed.

## What it backs up

Every installed package that is a game:

- **cartridge games** (`com.vtech.innotab.cart.*`)
- **downloaded InnoTV games** (`com.vtech.innotv.*`, except the system
  component `com.vtech.innotv.homefilter`)

For each game, in `Documents\StorioTV\games\backup_<date>\<package>\`:

| File / folder | Contents |
|---------------|----------|
| `game.apk` | The APK. Cartridge games are installed as protected apps in `/data/app-private` and are stored there already **decrypted**, so this is a normal, valid APK. Note that a cartridge game only runs with its cartridge inserted: the console uninstalls it when the cartridge is removed. |
| `resources.zip` | Public resources of protected apps (only when they are separate from the APK). |
| `lib/` | Native libraries. |
| `data/` | Private app data from `/data/data/<package>`: saved games and settings. |
| `sdcard_data/`, `sdcard_obb/` | `/sdcard/Android/data/<package>` and `/sdcard/Android/obb/<package>`, if present. |
| `dumpsys.txt` | `dumpsys package` output (paths, version, permissions). |

If a cartridge is inserted, its original contents (`/mnt/cart0`, including the
encrypted `MAIN.ITA`) are also copied to `cartridge_original/`, and `MAIN.ITA`
is checked against the `main.ita.md5` file stored on the cartridge.

`report.txt` in the backup folder lists every game with its version, paths,
APK size, ZIP check and SHA256, what was copied, and the cartridge MD5 result.

## Why this matters

The VTech store is closed, so for downloaded games these backups are the only
copy left. A downloaded game can be reinstalled with:

    adb install game.apk

## Requirements

- Windows with Windows PowerShell 5.1
- `adb` (looked up in `%LOCALAPPDATA%\Android\Sdk\platform-tools`, then `PATH`)
- **Root ADB** on the console (see `../sd-tool`); without root the protected
  games cannot be read
- The console switched on with HDMI connected (it does not finish booting otherwise)

## Usage

    powershell -ExecutionPolicy Bypass -File Backup-Games.ps1

To back up a single game, pass its package name:

    powershell -ExecutionPolicy Bypass -File Backup-Games.ps1 -Package com.vtech.innotv.quizgame
