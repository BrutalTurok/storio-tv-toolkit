# DOOM for Storio TV / InnoTV

A port of DOOM to the VTech Storio TV / InnoTV console (Android 4.2.2, ARMv7).

- Engine: [doomgeneric](https://github.com/ozkl/doomgeneric) (based on Chocolate
  Doom), built for the console **without the Android NDK**.
- No Java code: a `NativeActivity` that draws straight to the window and reads
  the controller directly.
- Sound: sound effects plus FM music (Chocolate Doom's OPL emulation), played
  through OpenSL ES at 44.1 kHz.
- WAD: if you copy your own `doom1.wad` (shareware), `doom.wad` or `doom2.wad`
  to the console, that one is used. Otherwise it plays
  [Freedoom](https://freedoom.github.io/) (free, bundled in the APK).

## Requirements

- Windows PowerShell 5.1.
- `adb` (looked up in `%LOCALAPPDATA%\Android\Sdk\platform-tools`, then `PATH`).
- ADB enabled on the console (see `../sd-tool`), console switched on and
  connected over USB.
- `doom.apk` in this folder, next to the scripts (download it from the
  repository's GitHub Releases, or build it yourself, see below).

## Install

In PowerShell, inside this folder:

    powershell -ExecutionPolicy Bypass -File Install-DOOM.ps1

With your own `doom1.wad` (it is copied to `/sdcard/doom1.wad`):

    powershell -ExecutionPolicy Bypass -File Install-DOOM.ps1 -Wad C:\path\doom1.wad

`Install-DOOM.ps1` installs (or updates) the APK, copies `doom_buttons.txt` to
the console and starts the game. To start it again later from the PC, use
`Play-DOOM.ps1`, or:

    adb shell am start -n org.storio.doom/android.app.NativeActivity

To uninstall: `adb uninstall org.storio.doom`

## Adding DOOM to the VTech menu

    powershell -ExecutionPolicy Bypass -File Add-To-Menu.ps1

This uses the developer route of the VTech package manager, so DOOM shows up
in the games section of the console's desktop with its own icon. Before
changing anything it saves a backup of the desktop database to
`Documents\StorioTV\menu\` (`fakeapp_<date>.db`), together with a log
(`add_<date>.txt`).

- It takes 1-2 minutes: DOOM opens by itself while the icon is generated. Do
  not touch anything until the script finishes.
- If DOOM disappears from the menu after a reboot, run `Add-To-Menu.ps1` again.
- Always update DOOM with `Install-DOOM.ps1`: every reinstall changes the APK
  path, and the VTech manager hides the game if the saved path no longer
  exists. `Install-DOOM.ps1` (since 1.6b) refreshes that path automatically.
- To undo it: `Restore-Menu.ps1` restores the oldest backup (type `YES` to
  confirm), then reboot the console.

## Controls (default)

VTech controller:

| Button | Action |
|--------|--------|
| D-pad / joystick | Move, navigate menus |
| Main button | Fire, accept in menus |
| Green button | Use / open doors, "yes" in prompts |
| Red button | Next weapon |
| Help button | Menu |
| Wheel | Strafe: clockwise = right, anticlockwise = left |

Generic Android gamepads also work: A = fire, B = use, X = run, Y = next
weapon, L1/R1 = strafe, L2 = previous weapon, R2/SELECT = map,
START/MENU/BACK = menu.

## Button map: `doom_buttons.txt`

The game reads `/sdcard/doom_buttons.txt` on start-up (`Install-DOOM.ps1` and
`Play-DOOM.ps1` copy it from this folder). Each line is

    code=action[,second_action]

- `code` is an Android key code, or `r` followed by a raw VTech controller
  code (for example `r303=fire,enter`).
- To find a button's code, start DOOM, run `Show-Buttons.ps1` and press the
  button: the log shows `Android key NNN pressed` or `VTech button rNNN (...)
  pressed`. Add the code to `doom_buttons.txt` and run `Install-DOOM.ps1` again.
- Actions: `up down left right fire use run strafe strafe_left strafe_right
  menu enter map yes no next_weapon prev_weapon 1 2 3 4 5 6 7 pause backspace`
- Wheel options:
  - `wheel=180` - how long each wheel click holds strafe, in ms (30-1000;
    higher = slides further per click)
  - `wheel=invert` - if it goes the wrong way
  - `wheel=off` - disable the wheel

Lines starting with `#` are comments. For backward compatibility, the old file
name `/sdcard/doom_botones.txt`, the Spanish action names (`arriba`,
`disparar`, `usar`, ...) and `ruleta=` are still accepted; if both files exist,
`doom_buttons.txt` is used.

## Audio options

Optional settings in `/sdcard/doom_audio.txt` (see `doom_audio_example.txt`):

    music=4       extra music volume (0 = no music, 1 = original, up to 16)
    sfx=2         sound effect volume, in halves (1 = half, 2 = normal, 4 = double)
    rate=44100    output sample rate (8000-48000)

To copy it:

    adb push doom_audio_example.txt /sdcard/doom_audio.txt

If sound causes problems, start without sound by creating a flag file:

    adb shell touch /sdcard/doom_no_sound

(The Spanish keys `musica=`, `efectos=`, `frecuencia=` and the flag file
`/sdcard/doom_sin_sonido` from earlier versions still work.)

## Troubleshooting

- **Red screen:** no WAD was found (not even the bundled Freedoom).
- **Gray screen on first run:** Freedoom is being copied out of the APK; it
  takes a few seconds.
- **Black screen for a long time, or other problems:** run `Show-Log.ps1`. It
  saves the console log to `Documents\StorioTV\doom_log.txt`.
- **A button does nothing:** run `Show-Buttons.ps1` (see above) to see which
  code it sends.

## Where the APK comes from

`doom.apk` is published in the repository's GitHub Releases. You can also
build it yourself on Linux from `src/`:

    cd src
    ./build.sh

This produces `src/build/doom.apk`. It needs clang, lld, llvm-nm and
llvm-strip (LLVM 14 or later), python3, openssl, git, curl and unzip; it
downloads doomgeneric (pinned commit, patched with `doomgeneric-storio.patch`)
and Freedoom by itself.

Signing: the private key used for the release APK is not in the repository.
`build.sh` uses `$SIGN_KEY` / `$SIGN_CERT` if set, otherwise
`src/signing/key.pem` + `cert.pem`, and if those do not exist it generates a new
self-signed key there. Android will not install an APK over an existing one
signed with a different key, so to switch between the release APK and your own
build, uninstall first (`adb uninstall org.storio.doom`).

## Version history

- **1.0 - 1.2:** playable with the controller; raw VTech buttons; icon in the
  VTech menu.
- **1.3:** sound (sound effects + OPL music, 44.1 kHz).
- **1.4:** louder music (the emulated OPL output is very quiet), DC offset
  removal.
- **1.5 / 1.6:** strafe with the controller wheel (wheel values centred on 128).
- **1.6b:** the installer refreshes the APK path stored in the VTech menu.
- **1.7:** English release: English config file, action and option names
  (the Spanish ones are still accepted).

## License

- DOOM code (doomgeneric and Chocolate Doom, including the OPL music code):
  GNU GPL v2, see `LICENSE-GPLv2.txt`. The source for this port is in `src/`.
- Freedoom (bundled WAD): BSD license, see `LICENSE-Freedoom-BSD.txt`.
- The DOOM shareware WAD (`doom1.wad`) belongs to id Software and is not
  included.
