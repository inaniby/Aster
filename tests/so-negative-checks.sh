#!/bin/sh
# v0.22.22-dev structural and link-time negative cases for shared objects.
set -eu
[ -x ./aster ] || { echo "build ./aster first" >&2; exit 2; }

WORK=tmp-so-negative
rm -rf "$WORK"; mkdir -p "$WORK"

# Duplicate exports must be rejected by link-so with a stable, actionable diagnostic.
cat >"$WORK/duplicate-a.ast" <<'AST'
fn aster_duplicate_probe(value: i32) -> i32 { return value + 1; }
AST
cat >"$WORK/duplicate-b.ast" <<'AST'
fn aster_duplicate_probe(value: i32) -> i32 { return value + 2; }
AST
./aster build-obj --pic "$WORK/duplicate-a.ast" -o "$WORK/duplicate-a.o"
./aster build-obj --pic "$WORK/duplicate-b.ast" -o "$WORK/duplicate-b.o"
if ./aster link-so "$WORK/duplicate-a.o" "$WORK/duplicate-b.o" -o "$WORK/duplicate.so" 2>"$WORK/duplicate.err"; then
  echo 'FAIL: link-so accepted duplicate global exports' >&2; exit 1
fi
grep -F "duplicate global symbol 'aster_duplicate_probe' across input objects" "$WORK/duplicate.err" >/dev/null
echo 'PASS: link-so rejects duplicate exported symbols with a diagnostic'

# Build a library whose DT_NEEDED entry intentionally has no provider in this test directory.
./aster build-so examples/so_missing_dependency.ast -o "$WORK/libmissing-dependency-client.so" --needed libaster_missing_dependency.so
./aster build-so examples/so_missing_symbol.ast -o "$WORK/libmissing-symbol-client.so"
python3 - "$WORK" <<'PY'
import struct, sys
from pathlib import Path
work = Path(sys.argv[1])
def sections(b):
    off = struct.unpack_from('<Q', b, 40)[0]
    ent, n, si = struct.unpack_from('<HHH', b, 58)
    raw = [struct.unpack_from('<IIQQQQIIQQ', b, off+i*ent) for i in range(n)]
    strings = b[raw[si][4]:raw[si][4]+raw[si][5]]
    return {strings[s[0]:strings.index(b'\0', s[0])].decode(): s for s in raw}
def dyn_tags(b, sec):
    s = sec['.dynamic']; out = {}
    for i in range(s[5]//16):
        tag, value = struct.unpack_from('<qQ', b, s[4]+i*16)
        out.setdefault(tag, []).append(value)
    return out
p = work/'libmissing-dependency-client.so'; b = p.read_bytes(); sec = sections(b); dyn = dyn_tags(b, sec)
assert struct.unpack_from('<H', b, 16)[0] == 3
st = sec['.dynstr']; strings = b[st[4]:st[4]+st[5]]
needed = [strings[x:].split(b'\0')[0].decode() for x in dyn.get(1, [])]
assert needed == ['libaster_missing_dependency.so'], needed
print('PASS: missing-dependency fixture records its intentional DT_NEEDED entry')
p = work/'libmissing-symbol-client.so'; b = p.read_bytes(); sec = sections(b)
sym, st = sec['.dynsym'], sec['.dynstr']; strings = b[st[4]:st[4]+st[5]]
names = []
for i in range(sym[5]//24):
    name, info, other, shndx, value, size = struct.unpack_from('<IBBHQQ', b, sym[4]+i*24)
    names.append((strings[name:].split(b'\0')[0].decode(), shndx))
assert ('aster_missing_function', 0) in names, [x for x in names if 'missing' in x[0]]
print('PASS: missing-symbol fixture preserves an undefined dynamic symbol')
PY

echo 'PASS: all v0.22.22-dev shared-object negative structural checks'
