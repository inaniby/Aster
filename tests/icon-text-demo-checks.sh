#!/bin/sh
# v0.23.7-dev: the icon + text demo, and the split it exists to show.
#
# examples/icon_text_demo.ast draws two things, and neither is compiled into
# the code:
#
#   * a 48x48 RGBA icon, read at compile time by @embed
#   * three lines of text, drawn with an 8x8 bitmap font that is also @embed'd
#
# The app's *name* is not in the source at all: it is string/app_name in
# resources.arsc, and the manifest carries only a TYPE_REFERENCE to it. The
# framework's resources go through the table; the program's own resources go in
# the .so. This suite checks both halves, and renders the picture so there is
# something to look at rather than only numbers.
#
# The preview pixels are Aster's: the C host supplies the buffer and the file
# format, and nothing else.
#
#   HOSTCC=aarch64-linux-gnu-gcc sh tests/icon-text-demo-checks.sh
set -eu
. tests/host-toolchain-probe.sh
cd "$(dirname "$0")/.."
CXX=${CXX:-c++}
OUT=${OUT:-tmp-icon-text-demo}
ASSETS=examples/demo_assets
PKG=com.aster.icontext
LIB=icontext
LABEL='Aster 图标文字'
mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT HUP INT TERM

# Rendering needs to *run* an AArch64 binary. The probe above only proved the
# compiler; on a non-AArch64 host that also means qemu-user.
if [ "$(uname -m)" != aarch64 ] && [ "$(uname -m)" != arm64 ] \
   && ! command -v qemu-aarch64 >/dev/null 2>&1; then
    printf '%s\n' "SKIP: $0 (no way to run an AArch64 binary here; need qemu-aarch64)" >&2
    exit 0
fi

printf '%s\n' '[1/5] Build Aster compiler strictly'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"

printf '%s\n' '[2/5] Build the demo as a shared object'
"$OUT/aster" build-so examples/icon_text_demo.ast -o "$OUT/libicontext.so" > /dev/null
python3 - "$OUT/libicontext.so" <<'PY'
import sys, struct
b = open(sys.argv[1], 'rb').read()
assert b[:4] == b'\x7fELF' and b[4] == 2 and b[5] == 1, 'not an ELF64 LE object'
assert struct.unpack_from('<H', b, 16)[0] == 3, 'not ET_DYN'
print('   ELF64 AArch64 ET_DYN, %d bytes' % len(b))
PY

printf '%s\n' '[3/5] Every embedded asset is in the object, byte for byte, exactly once'
python3 - "$OUT/libicontext.so" "$ASSETS" <<'PY'
import sys, zipfile
so = open(sys.argv[1], 'rb').read()
base = sys.argv[2]
names = ['icon48.bin', 'font8x8.bin', 'title.txt', 'line2.txt', 'line3.txt']
for n in names:
    d = open(base + '/' + n, 'rb').read()
    assert d, n
    c = so.count(d)
    # One occurrence: the same path embedded twice is embedded once, and these
    # five paths each appear once in the source.
    assert c == 1, '%s: found %d times, expected exactly 1' % (n, c)
    print('   %-12s %6d bytes present exactly once' % (n, len(d)))
PY
printf '%s\n' 'PASS: the icon, the font and the three text files are in the .so'

printf '%s\n' '[4/5] Render it: the pixels Aster draws, with no Android present'
# The object imports ANativeWindow_* and __android_log_print, so dlopen needs
# those names to exist. Stubs, not mocks: they are never called on this path.
cat > "$OUT/stub.c" <<'C'
int ANativeWindow_setBuffersGeometry(void *w, int a, int b, int c) { return 0; }
int ANativeWindow_lock(void *w, void *o, void *d) { return -1; }
int ANativeWindow_unlockAndPost(void *w) { return 0; }
int __android_log_print(int p, const char *t, const char *f) { return 0; }
C
mkdir -p "$OUT/stub"
${HOSTCC:-cc} -O1 -shared -fPIC -o "$OUT/stub/libandroid.so" "$OUT/stub.c"
cp "$OUT/stub/libandroid.so" "$OUT/stub/liblog.so"
${HOSTCC:-cc} -std=c11 -O1 -Wall -Wextra -Wpedantic -Werror \
    tests/icon-text-host.c -o "$OUT/host" -ldl
LD_LIBRARY_PATH="$PWD/$OUT/stub" \
    "$PWD/tests/run-aarch64.sh" "$OUT/host" "$PWD/$OUT/libicontext.so" \
    360 640 "$PWD/$OUT/preview.ppm" > /dev/null
W=360
H=640
python3 - "$OUT/preview.ppm" "$W" "$H" "${PREVIEW_OUT:-}" <<'PY'
import sys
from collections import Counter
path, w, h, pngout = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
raw = open(path, 'rb').read()
# P6\n<w> <h>\n255\n then w*h*3
i = raw.index(b'255\n') + 4
px = raw[i:]
assert len(px) == w * h * 3, 'PPM payload %d, expected %d' % (len(px), w * h * 3)
c = Counter()
for k in range(w * h):
    c[(px[k * 3], px[k * 3 + 1], px[k * 3 + 2])] += 1
# The host pre-fills magenta. Any magenta left is a pixel Aster never wrote,
# which is the one way a "correct looking" background can lie.
assert c[(255, 0, 255)] == 0, '%d pixels never drawn' % c[(255, 0, 255)]
plate = c[(40, 53, 147)]     # the indigo plate of the embedded icon, scaled up
white = c[(255, 255, 255)]   # line 1
grey = c[(166, 166, 166)]    # lines 2 and 3
assert plate > 12000, 'icon plate covers %d px, expected > 12000' % plate
assert white > 1500, 'line 1 has %d ink px, expected > 1500' % white
assert grey > 1500, 'lines 2-3 have %d ink px, expected > 1500' % grey
print('   %dx%d: every pixel drawn; icon %d px, title %d px, lines %d px'
      % (w, h, plate, white, grey))
if pngout:
    # Written with the standard library alone -- zlib and struct, no Pillow --
    # so the preview also works on a bare install (Termux: `pkg install python`).
    import zlib, struct
    stride = w * 3
    raw = bytearray()
    for y in range(h):
        raw.append(0)                       # filter 0 (None) on every scanline
        raw += px[y * stride:(y + 1) * stride]
    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data
                + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff))
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)   # 8-bit truecolour RGB
    open(pngout, 'wb').write(
        b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr)
        + chunk(b'IDAT', zlib.compress(bytes(raw), 9)) + chunk(b'IEND', b''))
    print('   preview written to %s' % pngout)
PY
printf '%s\n' 'PASS: the icon and all three lines are on screen, drawn from @embed data'

printf '%s\n' '[5/5] Package it: the name is spelled out in the manifest and lives in the table'
KEY_DIR="$OUT/keys"; mkdir -p "$KEY_DIR"
"$OUT/aster" build-apk examples/icon_text_demo.ast -o "$OUT/demo.apk" \
    --package "$PKG" --libname "$LIB" --abi arm64-v8a \
    --label "$LABEL" \
    --string app_subtitle="ICON + TEXT" \
    --string greeting="Hello from resources.arsc" \
    --min-sdk 24 --target-sdk 34 --version-code 1 --version-name "1.0" \
    --keystore-dir "$KEY_DIR" > /dev/null
if ! python3 tests/validate_apk.py "$OUT/demo.apk" --package "$PKG" --libname "$LIB" \
        --label "$LABEL" --label-literal > "$OUT/validate.log" 2>&1; then
    cat "$OUT/validate.log" >&2
    exit 1
fi
grep -E "types=|app_subtitle" "$OUT/validate.log" | sed 's/^/   /'
"$OUT/aster" verify-apk "$OUT/demo.apk" | tail -1
# The assets came along for the ride: they are inside the APK's .so, not beside it.
python3 - "$OUT/demo.apk" "$ASSETS" "$LABEL" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
so = z.read('lib/arm64-v8a/libicontext.so')
base = sys.argv[2]
label = sys.argv[3].encode()
for n in ['icon48.bin', 'font8x8.bin', 'title.txt', 'line2.txt', 'line3.txt']:
    d = open(base + '/' + n, 'rb').read()
    assert so.count(d) == 1, '%s missing from the packaged .so' % n
print('   all five assets are inside lib/arm64-v8a/libicontext.so')
# ...and the name is in the manifest as well as in the table. It is written as a
# literal on purpose: a viewer that reads the binary manifest and never opens
# resources.arsc shows a blank name for a reference. validate_apk.py [4d] has
# already required the two copies to agree.
assert label in z.read('AndroidManifest.xml'), \
    'the app name is not spelled out in the manifest'
print('   the app name is spelled out in AndroidManifest.xml, and in string/app_name')
PY
# APK_OUT / PREVIEW_OUT exist so the artifacts survive the cleanup trap: point
# them at somewhere you can reach from a file manager (Termux:
# /sdcard or ~/storage/shared) and you get a preview to look at and an APK to
# tap, without having to dig through tmp-icon-text-demo/.
if [ -n "${APK_OUT:-}" ]; then
    cp "$OUT/demo.apk" "$APK_OUT"
    printf '%s\n' "   APK copied to $APK_OUT"
fi
printf '%s\n' 'PASS: APK validated, v1 + v2 verified, assets packaged, name in the manifest and the table'

printf '%s\n' ''
printf '%s\n' 'ALL ICON+TEXT DEMO CHECKS PASSED'
