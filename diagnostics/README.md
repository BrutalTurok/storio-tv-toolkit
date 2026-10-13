# Storio TV / InnoTV - diagnostics

Two small read-only scripts that gather information from a VTech Storio TV /
InnoTV console over ADB. Neither changes anything on the console.

Requirements: Windows PowerShell 5.1, `adb` (looked up in
`%LOCALAPPDATA%\Android\Sdk\platform-tools`, then `PATH`), ADB enabled on the
console (see `../sd-tool`), console switched on with HDMI connected.

## StorioTV-Diagnostics.ps1

    powershell -ExecutionPolicy Bypass -File StorioTV-Diagnostics.ps1

Saves everything to `Documents\StorioTV\diagnostics_<date>\`:

1. **System information:** `getprop.txt`, `mounts.txt` (`/proc/mounts`),
   `packages.txt` (`pm list packages -f`), `storage.txt` (listing of the storage
   mount points), `property.txt` (persistent properties from `/data/property`)
   and `packages.xml`.
2. **VTech apps:** copies the main system APKs (TVDesktop, ProfileTV,
   CartReceiver, VPM, VDM, Settings and the quiz game) to `apks\`, for example
   to check which languages they include.
3. **Cartridge:** an interactive step that records what happens when a cartridge
   is inserted.
   - You remove any cartridge and press Enter: the mounts are saved
     (`mounts_without_cart.txt`) and logcat / dmesg are cleared.
   - You insert a cartridge (for example one that asks for an update), try to
     open it until the console shows its message, then press Enter.
   - The script saves `logcat_cart.txt`, `dmesg_cart.txt`, `mounts_with_cart.txt`
     and `mounts_new.txt` (mounts that appeared with the cartridge). For each new
     mount point it saves a recursive listing (`cart_listing.txt`) and copies its
     contents to `cartridge\`.
   - Finally it lists the cartridge-related data folders
     (`cart_data_listing.txt`).

## Capture-Wheel.ps1

    powershell -ExecutionPolicy Bypass -File Capture-Wheel.ps1

Captures the raw input events that the controller's wheel sends, to work out
how it is reported to apps. It writes `Documents\StorioTV\wheel.txt` with:

- the input device descriptions (`getevent -lp`),
- for a **CLOCKWISE** and then a **COUNTERCLOCKWISE** turn: the raw events
  recorded with `getevent -lt` during 6 seconds (without `SYN_REPORT` lines),
  followed by what DOOM logged at the same time (`logcat -s DOOM:I`).

Start DOOM on the console (see `../doom`) before the capture; the script tells
you when to turn the wheel, and you turn it slowly, about 5 clicks, in one
direction only.
