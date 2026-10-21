#!/bin/sh
# v0.23.7-dev checks for the resource table as a table (multiple types, multiple
# entries) and for android:label being resolvable from it in both of the two
# spellings a manifest may use.
#
# The icon work in v0.23.6-dev shipped a resources.arsc that could hold exactly
# one resource: one type, one entry, one value, written by a function whose
# arguments were two strings. That is not a resource table, it is a constant
# with a header. The question it could not answer is the one that matters: what
# happens when there is a second resource?
#
# So the table is now built by adding resources to it and asking it for the ids
# it assigned, and it holds two kinds of value:
#
#   drawable/ic_launcher -> TYPE_STRING naming a path inside the APK, which
#                           AssetManager opens
#   string/app_name      -> TYPE_STRING holding the string itself, nothing to
#                           open — the table *is* the value
#
# android:label can name the second one two ways: as a TYPE_REFERENCE (what aapt
# writes; the framework opens the table) or as a TYPE_STRING spelled out in the
# manifest (Aster's default; every consumer can read it, including a viewer that
# never opens the table). Both are legal, and on a device both resolve. The part
# worth testing is that they cannot disagree -- so [4d] accepts either and then
# insists the table still says the same thing.
#
# Layers:
#   1. strict compiler build
#   2. source guards
#   3. build an APK with extra string resources and re-derive the whole table
#      with a second, independent parser
#   4. negative cases for --string
#   5. compiler mutations, each caught for a different reason, plus androguard
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-restable-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

ASTER=${ASTER:-$OUT/aster}
SO=${SO:-$OUT/restable.so}
APK=${APK:-/tmp/aster-restable-test.apk}
PKG=${PKG:-com.aster.restest}
LIB=${LIB:-restest}
LABEL=${LABEL:-Aster Resource Test}
ABI=${ABI:-arm64-v8a}
KEY_DIR=${KEY_DIR:-/tmp/aster-restable-keys}

mkdir -p "$KEY_DIR"
printf '%s\n' '[1/6] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$ASTER"

printf '%s\n' '[2/6] Source guards: a table, not a constant'
grep -qF 'struct Entry {' src/aster.cpp \
    || { echo 'FAIL: the resource table entry type is gone' >&2; exit 1; }
grep -qF 'uint32_t resId(const std::string& type, const std::string& name) const {' src/aster.cpp \
    || { echo 'FAIL: resource ids are no longer assigned by the table' >&2; exit 1; }
grep -qF 'table.add(iconEntry);' src/aster.cpp \
    || { echo 'FAIL: the icon is no longer added as a resource' >&2; exit 1; }
grep -qF 'nameEntry.value=label; nameEntry.isFile=false;' src/aster.cpp \
    || { echo 'FAIL: the app name is no longer stored as a string resource' >&2; exit 1; }
grep -qF 'const uint32_t labelResId = table.resId("string",   "app_name");' src/aster.cpp \
    || { echo 'FAIL: android:label no longer comes from the table' >&2; exit 1; }
# The reference is still the fallback base and --label-as-reference is what
# leaves it in the manifest; the literal is applied over the top of it.
grep -qF 'application.attrs={{"label","ref",labelId},' src/aster.cpp \
    || { echo 'FAIL: android:label is no longer written as TYPE_REFERENCE' >&2; exit 1; }
grep -qF 'labelAsReference ? std::string() : label);' src/aster.cpp \
    || { echo 'FAIL: --label-as-reference no longer selects the aapt spelling' >&2; exit 1; }
grep -qF 'if(!labelLiteral.empty()) application.attrs[0]={"label","str",labelLiteral};' src/aster.cpp \
    || { echo 'FAIL: the literal spelling is no longer applied over the reference' >&2; exit 1; }
# Type ids are handed out in order of first appearance, so the chunks have to
# be written in that order too.
grep -qF 'for (size_t ti = 0; ti < table.types.size(); ++ti) {' src/aster.cpp \
    || { echo 'FAIL: the table no longer emits one chunk pair per type' >&2; exit 1; }
grep -qF 'put32(spec, 16 + 4 * n);' src/aster.cpp \
    || { echo 'FAIL: ResTable_typeSpec size no longer accounts for every entry' >&2; exit 1; }
grep -qF 'static bool validResourceName(const std::string& s) {' src/aster.cpp \
    || { echo 'FAIL: --string names are no longer validated' >&2; exit 1; }
printf '%s\n' 'PASS: resource table, id assignment, label reference and --string present'

printf '%s\n' '[3/6] Build an APK with extra string resources, re-derive the table'
"$ASTER" build-so examples/native_activity.ast -o "$SO" --soname "lib$LIB.so" > /dev/null
"$ASTER" build-apk "$SO" -o "$APK" \
    --package "$PKG" --libname "$LIB" --abi "$ABI" \
    --label "$LABEL" --min-sdk 24 --target-sdk 34 \
    --string greeting=Hello --string app_subtitle="Two words" \
    --keystore-dir "$KEY_DIR" > /dev/null
if ! python3 tests/validate_apk.py "$APK" --package "$PKG" --libname "$LIB" \
        --abi "$ABI" --label "$LABEL" > "$OUT/validate.log" 2>&1; then
    echo 'FAIL: validate_apk.py rejected the APK:' >&2
    sed -n 's/^/    /p' "$OUT/validate.log" >&2
    exit 1
fi
printf '%s\n' 'PASS: validate_apk.py accepts it (icon, label, table, v1 + v2 signatures)'

# A second parser, written here rather than reused, so the two have to agree
# independently. This one walks every type chunk and every entry and checks that
# the ids the generator handed out are the ids the manifest can point at.
python3 - "$APK" "$PKG" "$LABEL" <<'PY'
import sys, zipfile, struct
apk, pkg, label = sys.argv[1], sys.argv[2], sys.argv[3]
z = zipfile.ZipFile(apk)
b = z.read('resources.arsc')
def u16(p): return struct.unpack_from('<H', b, p)[0]
def u32(p): return struct.unpack_from('<I', b, p)[0]
assert u16(0) == 0x0002, 'not a ResTable'
def pool(pos):
    hs, sz = u16(pos + 2), u32(pos + 4)
    cnt, flags, sstart = u32(pos + 8), u32(pos + 16), u32(pos + 20)
    assert flags & 0x100, 'string pool is not UTF-8'
    out = []
    for i in range(cnt):
        q = pos + sstart + u32(pos + hs + 4 * i)
        n = b[q]; q += 1
        if n & 0x80: n = ((n & 0x7f) << 8) | b[q]; q += 1
        n2 = b[q]; q += 1
        if n2 & 0x80: n2 = ((n2 & 0x7f) << 8) | b[q]; q += 1
        out.append(b[q:q + n2].decode('utf-8'))
    return out, sz
gstrs, gsz = pool(12)
pos = 12 + gsz
assert u16(pos) == 0x0200, 'no ResTable_package'
phs, psz = u16(pos + 2), u32(pos + 4)
pid = u32(pos + 8)
types, _ = pool(pos + u32(pos + 268))
keys, _ = pool(pos + u32(pos + 276))
assert pid == 0x7F, 'package id 0x%02x' % pid
assert b[pos + 12:pos + 12 + 256].decode('utf-16-le').split('\0')[0] == pkg, 'wrong package'

# Every type chunk, in id order, and every entry in each.
entries = []
specs = []
p = pos + phs
while p + 8 <= pos + psz:
    ct, chs, csz = u16(p), u16(p + 2), u32(p + 4)
    if ct == 0x0202:                                     # ResTable_typeSpec
        tid = b[p + 8]
        specs.append((tid, u32(p + 12)))
        assert csz == 16 + 4 * u32(p + 12), 'typeSpec size %d for %d entries' % (csz, u32(p + 12))
    elif ct == 0x0201:                                   # ResTable_type
        tid = b[p + 8]
        ecount, estart = u32(p + 12), u32(p + 16)
        assert u32(p + 20) == 56, 'config.size is not 56'
        assert chs == 76, 'headerSize %d' % chs
        assert estart == chs + 4 * ecount, 'entriesStart %d' % estart
        for i in range(ecount):
            ep = p + estart + u32(p + chs + 4 * i)
            assert u16(ep) == 8 and u16(ep + 2) == 0, 'bad ResTable_entry'
            key = u32(ep + 4)
            vp = ep + 8
            assert u16(vp) == 8, 'Res_value size'
            dtype, data = b[vp + 3], u32(vp + 4)
            entries.append(((pid << 24) | (tid << 16) | i, types[tid - 1], keys[key], dtype, data))
    p += csz
assert len(specs) == len(types), '%d typeSpecs for %d types' % (len(specs), len(types))
assert [s[0] for s in specs] == list(range(1, len(types) + 1)), 'type ids not in order: %r' % (specs,)

# What the table is supposed to hold.
want = [
    (0x7F010000, 'drawable', 'ic_launcher', 0x03, 'res/drawable-nodpi/ic_launcher.png'),
    (0x7F020000, 'string',   'app_name',    0x03, label),
    (0x7F020001, 'string',   'greeting',    0x03, 'Hello'),
    (0x7F020002, 'string',   'app_subtitle',0x03, 'Two words'),
]
assert len(entries) == len(want), 'table holds %d entries, expected %d: %r' % (len(entries), len(want), entries)
for i, (resid, tname, kname, dtype, data) in enumerate(entries):
    wresid, wtname, wkname, wdtype, wvalue = want[i]
    assert resid == wresid, 'entry %d: id 0x%08x != 0x%08x' % (i, resid, wresid)
    assert (tname, kname) == (wtname, wkname), 'entry %d: %s/%s != %s/%s' % (i, tname, kname, wtname, wkname)
    assert dtype == wdtype, 'entry %d: dataType 0x%02x' % (i, dtype)
    assert data < len(gstrs), 'entry %d: data %d out of range' % (i, data)
    assert gstrs[data] == wvalue, 'entry %d: value %r != %r' % (i, gstrs[data], wvalue)
    sys.stderr.write('   0x%08x %-8s %-12s TYPE_STRING %r\n' % (resid, tname, kname, gstrs[data]))

# A drawable names a file; a string is the value. The difference is not on the
# wire, so the check is what the string happens to name.
for resid, tname, kname, dtype, data in entries:
    v = gstrs[data]
    if tname == 'drawable':
        assert v.startswith('res/'), 'drawable %s does not name a path: %r' % (kname, v)
        assert v in z.namelist(), 'drawable %s names %r, which is not in the APK' % (kname, v)
    else:
        assert not v.startswith('res/'), 'string %s looks like a path: %r' % (kname, v)
# The two kinds share one global pool and it is interned: the icon path appears
# once even though only one entry names it, and no string is stored twice.
assert len(set(gstrs)) == len(gstrs), 'the global string pool has duplicates: %r' % (gstrs,)
sys.stderr.write('   %d types, %d entries, %d interned pool strings\n' % (len(types), len(entries), len(gstrs)))
PY
printf '%s\n' 'PASS: the whole table re-derived independently, ids included'

printf '%s\n' '[4/6] Negative cases for --string'
expect_apk_fail() {   # $1 = label, $2.. = extra build-apk arguments
    lbl=$1; shift
    if "$ASTER" build-apk "$SO" -o "$OUT/bad.apk" --package "$PKG" --libname "$LIB" \
            --label "$LABEL" --keystore-dir "$KEY_DIR" "$@" > "$OUT/bad.log" 2>&1; then
        echo "FAIL: $lbl was accepted" >&2
        sed -n 's/^/    /p' "$OUT/bad.log" >&2
        return 1
    fi
    printf '%s\n' "PASS: $lbl rejected"
}
expect_apk_fail 'a name with a space' --string "bad name=x"
expect_apk_fail 'a name that starts with a digit' --string "9lives=x"
expect_apk_fail 'a value with no name' --string "=x"
expect_apk_fail 'no equals sign at all' --string "justaname"
expect_apk_fail 'the same resource twice' --string "greeting=Hi" --string "greeting=Bye"
# ...and each one says what is actually wrong
check_msg() {   # $1 = label, $2 = expected substring, rest = arguments
    lbl=$1; want=$2; shift 2
    "$ASTER" build-apk "$SO" -o "$OUT/bad.apk" --package "$PKG" --libname "$LIB" \
        --label "$LABEL" --keystore-dir "$KEY_DIR" "$@" > "$OUT/bad.log" 2>&1 \
        && { echo "FAIL: $lbl was accepted" >&2; return 1; }
    grep -qF "$want" "$OUT/bad.log" \
        || { echo "FAIL: $lbl rejected for another reason:" >&2; sed -n 's/^/    /p' "$OUT/bad.log" >&2; return 1; }
    printf '%s\n' "PASS: $lbl -- $want"
}
check_msg 'space in a resource name' 'not a valid resource name' --string "bad name=x"
check_msg 'no equals sign' 'expects NAME=VALUE' --string "justaname"
check_msg 'a duplicate resource' 'duplicate --string resource' --string "a=1" --string "a=2"

printf '%s\n' '[5/6] Compiler mutations and an external witness'
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

# 1. the literal in the manifest drifting away from the table: the one failure
#    mode the "two copies of one name" argument warns about, made real
w('label-mismatch', [
    ('if(!labelLiteral.empty()) application.attrs[0]={"label","str",labelLiteral};',
     'if(!labelLiteral.empty()) application.attrs[0]={"label","str",labelLiteral + " (stale)"};'),
])
# 2. the label pointing at the icon: still a reference, still resolves, still
#    wrong.  Built with --label-as-reference below, which is the only spelling
#    that puts an id in the manifest at all.
w('label-is-icon', [
    ('const uint32_t labelResId = table.resId("string",   "app_name");',
     'const uint32_t labelResId = table.resId("drawable", iconName);'),
])
# 3. the string resource filed under the drawable type: back to one type
w('one-type', [
    ('nameEntry.value=label; nameEntry.isFile=false;',
     'nameEntry.type="drawable"; nameEntry.value=label; nameEntry.isFile=false;'),
])
print('\n'.join(sorted(n for n in os.listdir(root) if n.startswith('mut-'))))
PY
for m in label-mismatch label-is-icon one-type; do
    ( cd "$OUT/mut-$m" && c++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror \
        -o aster aster.cpp ) &
done
wait
for m in label-mismatch label-is-icon one-type; do
    [ -x "$OUT/mut-$m/aster" ] || { echo "FAIL: mutated compiler '$m' did not build"; exit 1; }
done
printf '%s\n' '    (three mutated compilers built)'

printf '%s\n' '[6/6] the name is spelled out by default; --label-as-reference asks for the aapt spelling'
# A binary-XML reader that stops at the manifest shows a blank name for a
# TYPE_REFERENCE, because resolving it means opening resources.arsc -- which the
# framework does on install and not every viewer does. So the default writes the
# name as TYPE_STRING, readable without opening anything, and
# --label-as-reference writes the aapt spelling for anyone who wants the name to
# live in exactly one place.
#
# The table is the same either way: string/app_name is still there, is still
# what the framework reads, and is still required to agree with the manifest.
"$ASTER" build-apk "$SO" -o "$OUT/lit.apk" --package "$PKG" --libname "$LIB" --abi "$ABI" \
    --label "$LABEL" --keystore-dir "$KEY_DIR" > /dev/null
"$ASTER" build-apk "$SO" -o "$OUT/ref.apk" --package "$PKG" --libname "$LIB" --abi "$ABI" \
    --label "$LABEL" --keystore-dir "$KEY_DIR" --label-as-reference > /dev/null
for pair in "lit.apk --label-literal" "ref.apk --label-reference"; do
    set -- $pair
    python3 tests/validate_apk.py "$OUT/$1" --package "$PKG" --libname "$LIB" \
        --abi "$ABI" --label "$LABEL" "$2" > "$OUT/$1.log" 2>&1 \
        || { sed -n 's/^/    /p' "$OUT/$1.log" >&2; echo "FAIL: $1 does not validate ($2)"; exit 1; }
done
# Pinned the other way round, each must be rejected. That is what proves the
# flags really change the bytes instead of being accepted and ignored.
for pair in "lit.apk --label-reference" "ref.apk --label-literal"; do
    set -- $pair
    python3 tests/validate_apk.py "$OUT/$1" --package "$PKG" --libname "$LIB" \
        --abi "$ABI" --label "$LABEL" "$2" > "$OUT/$1.bad.log" 2>&1 \
        && { echo "FAIL: $1 still passed when pinned to $2"; exit 1; }
done
python3 - "$OUT/lit.apk" "$OUT/ref.apk" "$LABEL" <<'PY'
import sys, zipfile
lit = zipfile.ZipFile(sys.argv[1])
ref = zipfile.ZipFile(sys.argv[2])
label = sys.argv[3].encode()
assert label in lit.read('AndroidManifest.xml'), 'the default does not spell the name out'
assert label not in ref.read('AndroidManifest.xml'), 'the reference form started spelling it out'
# The table is the same either way -- the flag changes the manifest and nothing
# else, so the two cannot disagree about what the app is called on a device.
assert lit.read('resources.arsc') == ref.read('resources.arsc'), 'the table changed too'
print('   default: name in the manifest (%d bytes); --label-as-reference: not; '
      'resources.arsc identical (%d bytes)'
      % (len(lit.read('AndroidManifest.xml')), len(lit.read('resources.arsc'))))
PY
printf '%s\n' 'PASS: the default spells the name out, --label-as-reference points at the table, both agree'

check_mutation() {   # $1 = name, $2 = substring, $3.. = extra build-apk args
    d="$OUT/mut-$1"; name=$1; want=$2; shift 2
    "$d/aster" build-so examples/native_activity.ast -o "$d/lib.so" > /dev/null
    "$d/aster" build-apk "$d/lib.so" -o "$d/app.apk" \
        --package "$PKG" --libname "$LIB" --abi "$ABI" --label "$LABEL" \
        --keystore-dir "$KEY_DIR" --no-verify "$@" > /dev/null
    if python3 tests/validate_apk.py "$d/app.apk" --package "$PKG" --libname "$LIB" \
            --abi "$ABI" --label "$LABEL" > "$d/log" 2>&1; then
        echo "FAIL: mutation '$name' produced an APK that passed every check" >&2
        return 1
    fi
    if ! grep -qF "$want" "$d/log"; then
        echo "FAIL: mutation '$name' was rejected, but not because of $want:" >&2
        sed -n 's/^/    /p' "$d/log" >&2
        return 1
    fi
    printf '%s\n' "PASS: mutation '$name' rejected -- $want"
}
check_mutation 'label-mismatch' 'the manifest says'
check_mutation 'label-is-icon' 'expected string/app_name' --label-as-reference
check_mutation 'one-type' 'string/app_name is missing from resources.arsc'

# androguard reads the table with its own parser, and renders the attribute the
# way the framework would: an '@' is a reference, a bare 0x is a number.
if python3 -c 'import androguard' > /dev/null 2>&1; then
    # The witness reads the aapt spelling: it asserts the label comes out as a
    # reference, which only --label-as-reference produces.
    "$ASTER" build-apk "$SO" -o "$OUT/androw.apk" --package "$PKG" --libname "$LIB" --abi "$ABI" \
        --label "$LABEL" --min-sdk 24 --target-sdk 34 \
        --string greeting=Hello --string app_subtitle="Two words" \
        --keystore-dir "$KEY_DIR" --label-as-reference > /dev/null
    python3 - "$OUT/androw.apk" "$PKG" "$LABEL" <<'PY'
from loguru import logger
import sys
logger.remove(); logger.add(sys.stderr, level='WARNING')
from androguard.core.axml import ARSCParser, AXMLPrinter
import zipfile
apk, pkg, label = sys.argv[1], sys.argv[2], sys.argv[3]
z = zipfile.ZipFile(apk)
p = ARSCParser(z.read('resources.arsc'))
want = {0x7f010000: ('drawable', 'ic_launcher'), 0x7f020000: ('string', 'app_name'),
        0x7f020001: ('string', 'greeting'),      0x7f020002: ('string', 'app_subtitle')}
for rid, (t, n) in sorted(want.items()):
    got = p.get_id(pkg, rid)
    assert got[0] == t and got[1] == n, 'androguard: 0x%08x -> %r, expected %s/%s' % (rid, got, t, n)
    sys.stderr.write('   androguard: 0x%08x -> %s/%s\n' % (rid, got[0], got[1]))
xml = AXMLPrinter(z.read('AndroidManifest.xml')).get_xml().decode()
assert 'android:label="@7F020000"' in xml, 'label is not rendered as a reference:\n%s' % xml
assert 'android:icon="@7F010000"' in xml, 'icon is not rendered as a reference:\n%s' % xml
assert label not in xml, 'the label text is still spelled out in the manifest'
sys.stderr.write('   AXMLPrinter: android:label="@7F020000", and the name is nowhere in the manifest\n')
PY
    printf '%s\n' 'PASS: androguard resolves all four resources; the label is a reference'
else
    printf '%s\n' 'SKIP: androguard is not installed'
fi

printf '%s\n' 'ALL RESOURCE TABLE CHECKS PASSED'
