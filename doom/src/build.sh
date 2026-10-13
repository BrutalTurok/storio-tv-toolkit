#!/bin/bash
# Builds DOOM for the Storio TV / InnoTV (Android 4.2, ARMv7) WITHOUT the Android NDK.
# Requirements: clang + lld + llvm-nm + llvm-strip (LLVM 14 or later), python3, openssl, git, curl, unzip.
# Usage:  ./build.sh          -> produces build/doom.apk
#
# APK signing key (the private key is NOT part of the repository):
#   1. $SIGN_KEY and $SIGN_CERT (PEM files), if both are set;
#   2. otherwise signing/key.pem + signing/cert.pem next to this script, if they exist;
#   3. otherwise a new self-signed RSA 2048 key + certificate is generated in signing/.
# Android only installs an update over an existing app if both APKs are signed with the
# same key, so keep signing/ (or your own key) to be able to update without uninstalling.
set -e -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/build"; mkdir -p "$OUT"
DGREPO="$OUT/doomgeneric"
# 1. doomgeneric at the exact commit used + patches for the console
if [ ! -d "$DGREPO" ]; then
  git clone -q https://github.com/ozkl/doomgeneric.git "$DGREPO"
  git -C "$DGREPO" checkout -q e257a09527062bfb986b6e5e0780839b6cbd5b71
  git -C "$DGREPO" apply "$HERE/doomgeneric-storio.patch"
fi
DG="$DGREPO/doomgeneric"
# 2. Freedoom (free fallback WAD bundled in the APK)
if [ ! -f "$OUT/freedoom1.wad" ]; then
  curl -sSL -o "$OUT/freedoom.zip" https://github.com/freedoom/freedoom/releases/download/v0.13.0/freedoom-0.13.0.zip
  unzip -j -o -q "$OUT/freedoom.zip" '*/freedoom1.wad' -d "$OUT"
fi
# 3. Compile
RES=$(clang -print-resource-dir)/include
CFLAGS="--target=armv7a-linux-androideabi17 -march=armv7-a -mfloat-abi=softfp -mfpu=vfpv3-d16 -mthumb -O2 -fPIC
 -ffreestanding -nostdinc -isystem $HERE/inc -isystem $RES -I$DG -DNORMALUNIX -DLINUX -D_DEFAULT_SOURCE
 -DDOOMGENERIC_RESX=320 -DDOOMGENERIC_RESY=200 -DFEATURE_SOUND -DDG_STORIO -Dmusic_opl_module=DG_music_module
 -DSDL_SwapBE32(x)=__builtin_bswap32(x) -DSDL_SwapBE16(x)=__builtin_bswap16(x) -I$HERE/opl -fvisibility=hidden
 -fno-stack-protector -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-exceptions -w"
rm -rf "$OUT/obj"; mkdir -p "$OUT/obj"
SRCS=$(sed -n 's/^SRC_DOOM = //p' "$DG/Makefile" | sed 's/doomgeneric_xlib.o//' | sed 's/\.o/.c/g')
for s in $SRCS; do clang $CFLAGS -c "$DG/$s" -o "$OUT/obj/${s%.c}.o"; done
clang $CFLAGS -c "$DG/mus2mid.c" -o "$OUT/obj/mus2mid.o"
for f in dg_android aeabi sound_storio sl_out; do clang $CFLAGS -c "$HERE/storio/$f.c" -o "$OUT/obj/$f.o"; done
for f in opl opl_queue dbopl opl_storio i_oplmusic midifile; do clang $CFLAGS -c "$HERE/opl/$f.c" -o "$OUT/obj/opl_$f.o"; done
# 4. "Fake" system libraries (only for linking; the real ones are used on the console)
llvm-nm -u "$OUT"/obj/*.o | awk 'NF==2{print $2} NF==1{print $1}' | grep -v ':$' | sort -u > "$OUT/undef.txt"
llvm-nm --defined-only "$OUT"/obj/*.o | awk 'NF==3{print $3}' | sort -u > "$OUT/def.txt"
comm -23 "$OUT/undef.txt" "$OUT/def.txt" > "$OUT/need.txt"
mkdir -p "$OUT/stubs"
grep -E '^__android_log' "$OUT/need.txt" > "$OUT/n_log.txt" || true
grep -E '^(ANativeWindow_|AInputQueue_|AInputEvent_|AKeyEvent_|AMotionEvent_|ALooper_|AAsset|ANativeActivity_)' "$OUT/need.txt" > "$OUT/n_android.txt" || true
grep -xE '(sqrt|sin|cos|tan|atan|atan2|pow|floor|ceil|fabs|exp|log|sqrtf|fabsf|sinf|cosf|exp2|log2|ldexp|frexp|fmod|round|lround)' "$OUT/need.txt" > "$OUT/n_m.txt" || true
grep -E '^(sl|SL_)' "$OUT/need.txt" > "$OUT/n_OpenSLES.txt" || true
cat "$OUT"/n_log.txt "$OUT"/n_android.txt "$OUT"/n_m.txt "$OUT"/n_OpenSLES.txt | sort > "$OUT/n_other.txt"
comm -23 "$OUT/need.txt" "$OUT/n_other.txt" > "$OUT/n_c.txt"
for L in c m log android OpenSLES; do
  awk '/^SL_IID_/{print "const void* "$1" = 0;"; next} {print "void "$1"(void){}"}' "$OUT/n_$L.txt" > "$OUT/stubs/$L.c"
  clang --target=armv7a-linux-androideabi17 -nostdlib -shared -fPIC -fno-builtin -w -Wl,-soname,lib$L.so -Wl,--hash-style=sysv "$OUT/stubs/$L.c" -o "$OUT/stubs/lib$L.so"
done
# 5. Link libdoom.so (sysv hash and no RELRO: the Android 4.2 dynamic linker does not understand the modern ones)
clang --target=armv7a-linux-androideabi17 -fuse-ld=lld -nostdlib -shared -Wl,-soname,libdoom.so \
  -Wl,--hash-style=sysv -Wl,-z,norelro -Wl,--no-undefined -Wl,--gc-sections -Wl,-z,noexecstack \
  -Wl,--build-id=sha1 -Wl,--pack-dyn-relocs=none -Wl,--no-rosegment \
  "$OUT"/obj/*.o -L"$OUT/stubs" -lc -lm -llog -landroid -lOpenSLES -o "$OUT/libdoom.so"
llvm-strip --strip-unneeded "$OUT/libdoom.so"
# 6. Package and sign (v1 SHA1 signature, compatible with Android 4.2; same key = can update without uninstalling)
if [ -n "$SIGN_KEY" ] && [ -n "$SIGN_CERT" ]; then
  KEY="$SIGN_KEY"; CERT="$SIGN_CERT"
else
  KEY="$HERE/signing/key.pem"; CERT="$HERE/signing/cert.pem"
  if [ ! -f "$KEY" ] || [ ! -f "$CERT" ]; then
    mkdir -p "$HERE/signing"
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 10950 -subj "/CN=Storio DOOM" \
      -keyout "$KEY" -out "$CERT" 2>/dev/null
    chmod 600 "$KEY"
    echo "WARNING: generated a new signing key in $HERE/signing/" >&2
    echo "WARNING: an APK signed with this key cannot be installed over a DOOM APK signed with a" >&2
    echo "         different key (e.g. the release APK). Uninstall first: adb uninstall org.storio.doom" >&2
    echo "         Keep signing/key.pem to be able to update your own builds later." >&2
  fi
fi
[ -f "$KEY" ] && [ -f "$CERT" ] || { echo "Signing key/cert not found: $KEY $CERT" >&2; exit 1; }
python3 "$HERE/tools/mkapk.py" "$OUT/unsigned.apk" "$OUT/libdoom.so" "$OUT/freedoom1.wad"
python3 "$HERE/tools/signv1.py" "$OUT/unsigned.apk" "$OUT/doom.apk" "$KEY" "$CERT"
ls -la "$OUT/doom.apk"
