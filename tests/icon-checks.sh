#!/bin/sh
# v0.23.6-dev checks for the launcher icon (P2.2).
#
# android:icon is not a path, it is a resource id (0xpptteeee). The mapping from
# that id to res/drawable-nodpi/ic_launcher.png exists only inside
# resources.arsc, and without it AssetManager resolves nothing: the app installs
# cleanly, nothing is logged, and the launcher quietly shows the system default
# icon. So the feature is really two generators Aster did not have before -- a
# PNG encoder and a binary resource table -- plus one attribute whose data type
# has to be TYPE_REFERENCE rather than the numerically identical TYPE_INT_HEX.
#
# Layers:
#   1. strict compiler build
#   2. source guards for PNG, ARSC, the reference attribute and the injection
#   3. build a NativeActivity APK and let validate_apk.py re-derive everything
#   4. a second, independent byte-level read of both new files: an inline PNG
#      decoder (zlib) plus an inline resources.arsc walk, the rendered glyph,
#      and the centring invariant the truncation bug below used to break
#   5. compiler mutations: drop resources.arsc, mangle the Res_value data type,
#      write the icon as TYPE_INT_HEX, break the PNG chunk CRC, and leave the
#      table pointing at a file that was never added
#   6. external witnesses (androguard ARSCParser, PIL) when they are installed
#
# No Android toolchain is involved: no aapt, no d8, no apksigner, no NDK.
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-icon-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

ASTER=${ASTER:-$OUT/aster}
SO=${SO:-$OUT/icon.so}
APK=${APK:-/tmp/aster-icon-test.apk}
PKG=${PKG:-com.aster.icontest}
LIB=${LIB:-icontest}
ABI=${ABI:-arm64-v8a}
KEY_DIR=${KEY_DIR:-/tmp/aster-icon-keys}

mkdir -p "$KEY_DIR"
printf '%s\n' '[1/6] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$ASTER"

printf '%s\n' '[2/6] Source guards: PNG encoder, resource table, reference attribute'
# A regression that removes any one of these changes behaviour before a test
# that exercises it can fail, so the guards come first.
grep -qF 'namespace PNG {' src/aster.cpp \
    || { echo 'FAIL: the PNG encoder is gone' >&2; exit 1; }
grep -qF 'static uint32_t adler32(const uint8_t* p, size_t n) {' src/aster.cpp \
    || { echo 'FAIL: PNG::adler32 missing (the zlib trailer would be wrong)' >&2; exit 1; }
grep -qF 'static void deflateStored(std::vector<uint8_t>& o, const uint8_t* p, size_t n) {' src/aster.cpp \
    || { echo 'FAIL: PNG::deflateStored missing' >&2; exit 1; }
grep -qF 'put32be(o, crc32(t.data(), t.size()));' src/aster.cpp \
    || { echo 'FAIL: PNG chunk CRC-32 is no longer written' >&2; exit 1; }
grep -qF 'z.push_back(0x78); z.push_back(0x01);' src/aster.cpp \
    || { echo 'FAIL: the zlib header is missing' >&2; exit 1; }
grep -qF 'std::vector<uint8_t> trns = {0xFF, 0xFF, 0x00};' src/aster.cpp \
    || { echo 'FAIL: the icon no longer has a real alpha channel (tRNS)' >&2; exit 1; }
grep -qF 'namespace ARSC {' src/aster.cpp \
    || { echo 'FAIL: the resource table generator is gone' >&2; exit 1; }
grep -qF 'put32(sp, 0x00000100u);                     // UTF8_FLAG' src/aster.cpp \
    || { echo 'FAIL: resource string pools are no longer UTF-8 flagged' >&2; exit 1; }
grep -qF 'const uint32_t kConfigSize = 56;' src/aster.cpp \
    || { echo 'FAIL: ResTable_type no longer declares a 56-byte default config' >&2; exit 1; }
grep -qF 'const uint32_t entriesStart = headerSize + 4 * n;' src/aster.cpp \
    || { echo 'FAIL: entriesStart no longer skips the entry offset array' >&2; exit 1; }
grep -qF 'put16(type, 8); type.push_back(0); type.push_back(0x03); put32(type, gintern(e->value));' src/aster.cpp \
    || { echo 'FAIL: the icon Res_value is no longer TYPE_STRING' >&2; exit 1; }
# TYPE_REFERENCE, not TYPE_INT_HEX: identical bytes, completely different meaning.
grep -qF 'else if (kind=="ref") { dtype=0x01; data=(uint32_t)std::stoul(val, nullptr, 0); }' src/aster.cpp \
    || { echo 'FAIL: android:icon is no longer encoded as TYPE_REFERENCE' >&2; exit 1; }
grep -qF 'const uint32_t iconResId  = table.resId("drawable", iconName);    // 0x7f010000' src/aster.cpp \
    || { echo 'FAIL: the icon resource id no longer comes from the table' >&2; exit 1; }
grep -qF 'append("resources.arsc", arsc, false);' src/aster.cpp \
    || { echo 'FAIL: resources.arsc is no longer added to the APK' >&2; exit 1; }
# The centring guard: (x - pad) / cell truncates towards zero, so without an
# explicit x >= pad test the leftmost glyph column stretches 17px further left
# than the rightmost reaches right and the letter sits off-centre.
grep -qF 'int gx = (x >= pad) ? (x - pad) / cell : -1;' src/aster.cpp \
    || { echo 'FAIL: the glyph grid no longer guards the negative-index truncation' >&2; exit 1; }
printf '%s\n' 'PASS: PNG encoder, ARSC generator, TYPE_REFERENCE attribute and icon injection present'

printf '%s\n' '[3/6] Build a NativeActivity APK and validate it'
rm -rf "$KEY_DIR" && mkdir -p "$KEY_DIR"
"$ASTER" keygen --dir "$KEY_DIR" > /dev/null
"$ASTER" build-so examples/native_activity.ast -o "$SO" > /dev/null
"$ASTER" build-apk "$SO" -o "$APK" \
    --package "$PKG" --libname "$LIB" --abi "$ABI" \
    --label "Aster Icon Test" --min-sdk 24 --target-sdk 34 \
    --version-code 1 --version-name "1.0" --keystore-dir "$KEY_DIR" > /dev/null
# validate_apk.py owns sections [4a] (the reference attribute), [4b]
# (resources.arsc) and [4c] (the decoded PNG) for this feature.
python3 tests/validate_apk.py "$APK" --package "$PKG" --libname "$LIB" --abi "$ABI" \
    > "$OUT/validate.log" 2>&1 || { cat "$OUT/validate.log"; exit 1; }
grep -q "android:icon = 0x7f010000 encoded as TYPE_REFERENCE (0x01)" "$OUT/validate.log" \
    || { echo 'FAIL: validate_apk.py did not see the icon reference'; exit 1; }
grep -q "0x7f010000 -> drawable/ic_launcher -> TYPE_STRING" "$OUT/validate.log" \
    || { echo 'FAIL: validate_apk.py did not resolve the icon through the table'; exit 1; }
"$ASTER" verify-apk "$APK" > /dev/null
printf '%s\n' 'PASS: APK built, dual-signed, icon resolved through resources.arsc'

printf '%s\n' '[4/6] Independent byte-level read of resources.arsc and the PNG'
# Written from scratch here rather than reusing validate_apk.py, so the two
# parsers have to agree independently. This is also where the icon is checked to
# actually *look* like something, which no structural check can express.
ICON_PATH=$(python3 - "$APK" <<'PY'
import sys, zipfile, struct, zlib
apk = sys.argv[1]
z = zipfile.ZipFile(apk)
names = z.namelist()
assert 'resources.arsc' in names, 'resources.arsc missing from the APK'

# ------------------------------------------------ resources.arsc, walked by hand
b = z.read('resources.arsc')
def u16(p): return struct.unpack_from('<H', b, p)[0]
def u32(p): return struct.unpack_from('<I', b, p)[0]
entries = []
assert u16(0) == 0x0002, 'not a ResTable'
assert u16(2) == 12 and u32(8) == 1, 'unexpected table header'
def pool(pos):
    assert u16(pos) == 0x0001, 'not a string pool at %d' % pos
    hs, sz = u16(pos + 2), u32(pos + 4)
    cnt, flags, sstart = u32(pos + 8), u32(pos + 16), u32(pos + 20)
    assert flags & 0x100, 'string pool is not UTF-8 flagged'
    out = []
    for i in range(cnt):
        off = u32(pos + hs + 4 * i)
        q = pos + sstart + off
        n, q = (b[q], q + 1)
        if n & 0x80:
            n = ((n & 0x7f) << 8) | b[q]; q += 1
        n2, q = (b[q], q + 1)
        if n2 & 0x80:
            n2 = ((n2 & 0x7f) << 8) | b[q]; q += 1
        out.append(b[q:q + n2].decode('utf-8'))
    return out, sz
gstrs, gsz = pool(12)
pos = 12 + gsz
assert u16(pos) == 0x0200, 'no ResTable_package at %d' % pos
phs, psz = u16(pos + 2), u32(pos + 4)
pid = u32(pos + 8)
pname = b[pos + 12:pos + 12 + 256].decode('utf-16-le').split('\0')[0]
types, _ = pool(pos + u32(pos + 268))
keys, _ = pool(pos + u32(pos + 276))
assert pid == 0x7F, 'package id 0x%02x' % pid
# v0.23.7-dev: the table is a real table now, so drawable is one type among
# several rather than the only one it can hold.
assert 'drawable' in types, types
assert 'ic_launcher' in keys, keys
# walk the type chunks inside the package
found = None
p = pos + phs
while p + 8 <= pos + psz:
    ct, chs, csz = u16(p), u16(p + 2), u32(p + 4)
    if ct == 0x0201:                                   # ResTable_type
        tid = b[p + 8]
        ecount, estart = u32(p + 12), u32(p + 16)
        assert u32(p + 20) == 56, 'config.size is not 56'
        assert chs == 20 + 56, 'headerSize is not 20 + config.size'
        assert estart == chs + 4 * ecount, 'entriesStart does not skip the offset array'
        for i in range(ecount):
            eo = u32(p + chs + 4 * i)
            if eo == 0xFFFFFFFF:
                continue
            ep = p + estart + eo
            esz, eflags, key = u16(ep), u16(ep + 2), u32(ep + 4)
            assert eflags == 0, 'unexpected complex entry'
            assert esz == 8, 'ResTable_entry size %d' % esz
            vp = ep + esz
            assert u16(vp) == 8, 'Res_value size %d' % u16(vp)
            assert b[vp + 2] == 0, 'Res_value res0 is not 0'
            dtype, data = b[vp + 3], u32(vp + 4)
            resid = (pid << 24) | (tid << 16) | i
            entries.append((resid, types[tid - 1], keys[key], dtype, data))
    p += csz
assert entries, 'no ResTable_type entry found'
# More than one resource lives in here now; the icon is the drawable one.
found = None
for e in entries:
    if e[1] == 'drawable' and e[2] == 'ic_launcher':
        found = e
assert found is not None, 'no drawable/ic_launcher entry: %r' % (entries,)
resid, tname, kname, dtype, data = found
assert resid == 0x7F010000, 'entry id is 0x%08x' % resid
assert dtype == 0x03, 'Res_value dataType is 0x%02x, expected TYPE_STRING' % dtype
path = gstrs[data]
assert path.startswith('res/') and path.endswith('.png'), path
assert path in names, 'arsc points at %r, which is not in the APK' % path
sys.stderr.write('   arsc: 0x%08x -> %s/%s -> TYPE_STRING -> %s\n' % (resid, tname, kname, path))

# --------------------------------------------------------------- the PNG itself
png = z.read(path)
assert png[:8] == b'\x89PNG\r\n\x1a\n', 'bad PNG signature'
q = 8
chunks = []
ihdr = None
plte = None
trns = None
idat = b''
while q + 8 <= len(png):
    ln = struct.unpack_from('>I', png, q)[0]
    typ = png[q + 4:q + 8]
    body = png[q + 8:q + 8 + ln]
    crc = struct.unpack_from('>I', png, q + 8 + ln)[0]
    assert crc == (zlib.crc32(typ + body) & 0xFFFFFFFF), 'bad CRC-32 on %r' % typ
    chunks.append(typ.decode())
    if typ == b'IHDR':
        ihdr = struct.unpack_from('>IIBBBBB', body)
    elif typ == b'PLTE':
        plte = body
    elif typ == b'tRNS':
        trns = body
    elif typ == b'IDAT':
        idat += body
    q += 12 + ln
assert chunks[0] == 'IHDR' and chunks[-1] == 'IEND', chunks
assert 'PLTE' in chunks and 'tRNS' in chunks and 'IDAT' in chunks, chunks
w, h, depth, ctype, comp, filt, interl = ihdr
assert depth == 2 and ctype == 3, 'expected a 2-bit palette image, got depth=%d ctype=%d' % (depth, ctype)
assert interl == 0, 'interlaced'
assert len(plte) == 9, 'palette should have 3 entries'
assert trns[2] == 0, 'the third palette entry is not the transparent one'
plate = (plte[0], plte[1], plte[2])
assert plate == (0x28, 0x35, 0x93), 'plate colour changed: %r' % (plate,)
# inflate: this also checks the adler32 trailer
raw = zlib.decompress(idat)
stride = (w * depth + 7) // 8
assert len(raw) == h * (stride + 1), 'IDAT inflated to %d bytes' % len(raw)
def px(x, y):
    row = raw[y * (stride + 1) + 1: (y + 1) * (stride + 1)]
    assert raw[y * (stride + 1)] == 0, 'scanline %d is not filter 0' % y
    i = (row[x >> 2] >> (6 - 2 * (x & 3))) & 0x03
    a = trns[i] if i < len(trns) else 0xFF
    return (plte[3 * i], plte[3 * i + 1], plte[3 * i + 2], a)
assert px(0, 0)[3] == 0, 'the corner is not transparent'
assert px(w // 2, h // 2)[:3] == (255, 255, 255), 'the centre is not the glyph colour'
# the glyph must be centred: the bounding box of its white pixels has to be
# symmetric in both axes. This is the assertion the (x-pad)/cell truncation bug
# fails -- the left leg used to be 17px wider than the right one.
minx = miny = 1 << 30
maxx = maxy = -1
for y in range(h):
    for x in range(w):
        if px(x, y)[:3] == (255, 255, 255):
            minx = min(minx, x); maxx = max(maxx, x)
            miny = min(miny, y); maxy = max(maxy, y)
assert minx + maxx + 1 == w, 'glyph is not horizontally centred: x[%d,%d]' % (minx, maxx)
assert miny + maxy + 1 == h, 'glyph is not vertically centred: y[%d,%d]' % (miny, maxy)
# ...and it has to read as a letter, not just as a blob: 16x16 downsample
N = 16
art = []
for gy in range(N):
    line = ''
    for gx in range(N):
        c = px(w * gx // N + w // (2 * N), h * gy // N + h // (2 * N))
        line += ' ' if c[3] == 0 else ('#' if c[:3] == (255, 255, 255) else '.')
    art.append(line)
sys.stderr.write('   icon %dx%dx%dbit, %d chunks, plate=#%02x%02x%02x, glyph bbox x[%d,%d] y[%d,%d]\n'
      % (w, h, depth, len(chunks), plate[0], plate[1], plate[2], minx, maxx, miny, maxy))
for line in art:
    sys.stderr.write('   |%s|\n' % line)
EXPECTED = [
    ' .............. ',
    '................',
    '.....######.....',
    '...###...###....',
    '...###...###....',
    '..###......###..',
    '..###......###..',
    '..###......###..',
    '..############..',
    '..###......###..',
    '..###......###..',
    '..###......###..',
    '..###......###..',
    '..###......###..',
    '................',
    ' .............. ',
]
assert art == EXPECTED, 'the icon no longer renders as an A:\n' + '\n'.join(art)
print(path)
PY
) || exit 1
printf '%s\n' "PASS: resources.arsc and $ICON_PATH re-derived independently; icon renders as a centred A"

printf '%s\n' '[5/6] Compiler mutations: five ways to ship an invisible icon'
# Every APK entry is covered by the v1 and v2 signatures, so tampering with a
# finished APK proves nothing about the generator. Mutate the generator instead:
# compile a variant, let it build an APK, and require the validator to reject it
# for the specific reason that mutation is supposed to cause.
python3 - "$OUT" <<'PY'
import os, sys
root = sys.argv[1]
src = open('src/aster.cpp').read()

def w(name, pairs):
    s = src
    for old, new in pairs:
        assert s.count(old) == 1, 'anchor for %s appears %d times' % (name, s.count(old))
        s = s.replace(old, new)
    d = os.path.join(root, 'mut-' + name)
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, 'aster.cpp'), 'w').write(s)

# 1. no resources.arsc in the APK: the id has no table to resolve against
w('no-arsc', [
    ('    append("resources.arsc", arsc, false);\n', '    arsc.clear();\n'),
    ('    addMF("resources.arsc", arsc); addMF(soname, so);', '    addMF(soname, so);'),
])
# 2. the icon entry is not TYPE_STRING: the file path is never read
w('bad-datatype', [
    ('put16(type, 8); type.push_back(0); type.push_back(0x03); put32(type, gintern(e->value));',
     'put16(type, 8); type.push_back(0); type.push_back(0x11); put32(type, gintern(e->value));'),
])
# 3. android:icon as TYPE_INT_HEX: byte-identical in a hex dump, resolves to nothing
w('int-hex-icon', [
    ('else if (kind=="ref") { dtype=0x01; data=(uint32_t)std::stoul(val, nullptr, 0); }',
     'else if (kind=="ref") { dtype=0x11; data=(uint32_t)std::stoul(val, nullptr, 0); }'),
])
# 4. a PNG whose chunk CRCs do not match: decoders reject the whole image
w('bad-png-crc', [
    ('put32be(o, crc32(t.data(), t.size()));', 'put32be(o, crc32(t.data(), t.size()) ^ 0xFFFFu);'),
])
# 5. the table points at a file that was never added to the APK
w('no-icon-file', [
    ('    append(iconPath, icon, false);\n', '    icon.clear();\n'),
    ('addMF("AndroidManifest.xml", manifest); addMF(iconPath, icon);',
     'addMF("AndroidManifest.xml", manifest);'),
])
print('\n'.join(sorted(os.listdir(root))))
PY

for m in no-arsc bad-datatype int-hex-icon bad-png-crc no-icon-file; do
    ( cd "$OUT/mut-$m" && c++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror \
        -o aster aster.cpp ) &
done
wait
for m in no-arsc bad-datatype int-hex-icon bad-png-crc no-icon-file; do
    [ -x "$OUT/mut-$m/aster" ] || { echo "FAIL: mutated compiler '$m' did not build"; exit 1; }
done
printf '%s\n' '    (five mutated compilers built)'

check_mutation() {   # $1 = name, $2 = substring validate_apk.py must report
    d="$OUT/mut-$1"
    "$d/aster" build-so examples/native_activity.ast -o "$d/lib.so" > /dev/null
    "$d/aster" build-apk "$d/lib.so" -o "$d/app.apk" \
        --package "$PKG" --libname "$LIB" --abi "$ABI" \
        --label "Aster Icon Test" --min-sdk 24 --target-sdk 34 \
        --version-code 1 --version-name "1.0" --keystore-dir "$KEY_DIR" \
        --no-verify > /dev/null
    if python3 tests/validate_apk.py "$d/app.apk" --package "$PKG" --libname "$LIB" --abi "$ABI" \
            > "$d/log" 2>&1; then
        echo "FAIL: mutation '$1' produced an APK that passed every check"
        return 1
    fi
    if ! grep -qF "$2" "$d/log"; then
        echo "FAIL: mutation '$1' was rejected, but not because of $2:"
        sed -n 's/^/    /p' "$d/log"
        return 1
    fi
    printf '%s\n' "PASS: mutation '$1' rejected -- $2"
}
check_mutation no-arsc        'missing resources.arsc'
check_mutation bad-datatype   'expected TYPE_STRING (0x03)'
check_mutation int-hex-icon   'expected TYPE_REFERENCE (0x01)'
check_mutation bad-png-crc    'bad CRC-32'
check_mutation no-icon-file   'is not in the APK'

printf '%s\n' '[6/6] External witness (androguard / PIL)'
# Optional: the suite has to stay hermetic, so when neither third-party reader
# is installed this section reports SKIP rather than failing.
if python3 - "$APK" <<'PY'
import sys
try:
    import androguard, PIL
except ImportError:
    print('SKIP: androguard / PIL not installed')
    sys.exit(0)

import io, zipfile
from androguard.core.axml import ARSCParser
from PIL import Image

# androguard logs every chunk it walks through loguru; keep the section readable.
try:
    from loguru import logger
    logger.remove()
    logger.add(sys.stderr, level='WARNING')
except Exception:
    import logging
    logging.disable(logging.DEBUG)

apk = zipfile.ZipFile(sys.argv[1])
table = ARSCParser(apk.read('resources.arsc'))
pkgs = table.get_packages_names()
assert pkgs, 'androguard found no package in resources.arsc'
got = table.get_id(pkgs[0], 0x7F010000)
# get_id returns (type_name, key_name, resource_id)
assert got[0] == 'drawable' and got[1] == 'ic_launcher', 'androguard resolved %r' % (got,)
print('   androguard: %s 0x%08x -> %s/%s' % (pkgs[0], got[2], got[0], got[1]))

img = Image.open(io.BytesIO(apk.read('res/drawable-nodpi/ic_launcher.png')))
img.load()
assert img.size == (192, 192), 'PIL saw size %r' % (img.size,)
assert img.mode == 'P', 'PIL saw mode %r (expected a palette image)' % img.mode
rgba = img.convert('RGBA')
assert rgba.getpixel((0, 0))[3] == 0, 'PIL: the corner is not transparent'
assert rgba.getpixel((96, 96)) == (255, 255, 255, 255), 'PIL: the centre is not the glyph'
# getcolors() rather than getdata(): the latter is deprecated in Pillow >= 10.
colours = rgba.getcolors(maxcolors=16)
assert colours is not None, 'PIL saw more than 16 colours'
assert len(colours) == 3, 'PIL saw %d distinct colours' % len(colours)
print('   PIL: mode %s size %s, %d distinct colours, corner alpha 0'
      % (img.mode, img.size, len(colours)))
print('PASS: androguard resolves the icon and PIL decodes it as a 192x192 palette PNG')
PY
then
    :
else
    echo 'FAIL: the external witness disagreed with Aster'; exit 1
fi

printf '%s\n' 'ALL ICON CHECKS PASSED'
