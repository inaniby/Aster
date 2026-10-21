#!/bin/sh
# v0.17.0 regression proof: adding the source-level symbol table must not change anything the
# loader or the running program sees.
#
# For every final product this script shows that, against the same v0.16.0 compiler:
#   * ET_EXEC / static PIE images are the v0.16.0 image extended by appended sections -- the whole
#     v0.16.0 file is a byte-identical prefix once e_shoff/e_shentsize/e_shnum/e_shstrndx are
#     masked out (v0.16.0 left all four zero);
#   * a shared object is byte-identical up to the end of its loaded segments (the offset of its
#     .shstrtab section, which v0.16.0 placed right after the last loaded byte);
#   * the program header table (every field of every entry), the entry point, e_type/e_machine/
#     e_flags/e_ehsize and every section that already existed keep exactly their old bytes,
#     addresses, sizes, flags, alignments and link/info fields;
#   * the only sections a product gains are the symbol table and its string table (plus, for
#     ET_EXEC/PIE, the .text/.data/.bss sections the section table now describes), and no product
#     gains a .debug_* section;
#   * ET_REL objects are still byte-for-byte identical to v0.16.0.
#
# Reference images are produced by a real v0.16.0 compiler when ASTER_V16_DIR points at a v0.16.0
# checkout (the directory that holds its src/aster.cpp). Without it the fixtures committed under
# tests/baseline/v0.16.0 are used, so the script always runs. Regenerate the fixtures with:
#
#   ASTER_V16_DIR=/path/to/aster-v0.16.0 FIXTURE_DIR=tests/baseline/v0.16.0 \
#       sh tests/regression-symtab.sh --write-fixtures
#
set -eu
CXX=${CXX:-g++}
[ -x ./aster ] || { echo "build ./aster first" >&2; exit 2; }
FIXTURE_DIR=${FIXTURE_DIR:-tests/baseline/v0.16.0}
WRITE_FIXTURES=no
[ "${1:-}" = "--write-fixtures" ] && WRITE_FIXTURES=yes

CASES="exec_plain exec_globals exec_align exec_rtinit pie_plain pie_globals so_math so_rtinit obj_globals obj_array link_multi"

build_case() { # $1 = aster binary, $2 = case, $3 = output directory
  a=$1; c=$2; d=$3
  mkdir -p "$d"
  case $c in
    exec_plain)   "$a" build-elf examples/hello.ast            -o "$d/exec_plain"    >/dev/null ;;
    exec_globals) "$a" build-elf examples/symbols_demo.ast     -o "$d/exec_globals"  >/dev/null ;;
    exec_align)   "$a" build-elf examples/align_global.ast     -o "$d/exec_align"    >/dev/null ;;
    exec_rtinit)  "$a" build-elf examples/runtime_init.ast     -o "$d/exec_rtinit"   >/dev/null ;;
    pie_plain)    "$a" build-pie examples/hello.ast            -o "$d/pie_plain"     >/dev/null ;;
    pie_globals)  "$a" build-pie examples/pie_global_rw.ast    -o "$d/pie_globals"   >/dev/null ;;
    so_math)      "$a" build-so  examples/so_math.ast          -o "$d/so_math.so"    >/dev/null ;;
    so_rtinit)    "$a" build-so  examples/runtime_init.ast     -o "$d/so_rtinit.so"  >/dev/null ;;
    obj_globals)  "$a" build-obj examples/global_rw.ast        -o "$d/obj_globals.o" >/dev/null ;;
    obj_array)    "$a" build-obj examples/array_rw.ast         -o "$d/obj_array.o"   >/dev/null ;;
    link_multi)   "$a" build-obj examples/global_shared_main.ast -o "$d/gmain.o" >/dev/null
                  "$a" build-obj examples/global_shared_defs.ast -o "$d/gdefs.o" >/dev/null
                  "$a" link-obj "$d/gmain.o" "$d/gdefs.o" -o "$d/link_multi" >/dev/null
                  rm -f "$d/gmain.o" "$d/gdefs.o" ;;
    *) echo "internal error: unknown case $c" >&2; exit 2 ;;
  esac
}

ROOT=$(pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

REF="$WORK/ref"
NEW="$WORK/new"

if [ -n "${ASTER_V16_DIR:-}" ]; then
  echo "# reference images generated from ASTER_V16_DIR=$ASTER_V16_DIR"
  "$CXX" -std=c++17 -O2 -w "$ASTER_V16_DIR/src/aster.cpp" -o "$WORK/aster-v0.16.0"
  for c in $CASES; do build_case "$WORK/aster-v0.16.0" "$c" "$REF"; done
  if [ "$WRITE_FIXTURES" = yes ]; then
    rm -rf "$ROOT/$FIXTURE_DIR"; mkdir -p "$ROOT/$FIXTURE_DIR"
    cp "$REF"/* "$ROOT/$FIXTURE_DIR"/
    echo "# fixtures written to $FIXTURE_DIR"
  fi
else
  [ -d "$FIXTURE_DIR" ] || { echo "no v0.16.0 reference: set ASTER_V16_DIR or restore $FIXTURE_DIR" >&2; exit 2; }
  echo "# reference images taken from the committed fixtures in $FIXTURE_DIR"
  echo "# (set ASTER_V16_DIR=/path/to/aster-v0.16.0 to regenerate them from a real v0.16.0 compiler)"
  mkdir -p "$REF"; cp "$FIXTURE_DIR"/* "$REF"/
fi
[ "$WRITE_FIXTURES" = yes ] && { echo "PASS: v0.16.0 reference fixtures written"; exit 0; }

for c in $CASES; do build_case "$ROOT/aster" "$c" "$NEW"; done

python3 - "$REF" "$NEW" <<'PY'
import os, struct, sys

refdir, newdir = sys.argv[1], sys.argv[2]
# e_shoff, e_shentsize, e_shnum, e_shstrndx: the four header fields v0.16.0 left at zero and
# v0.17.0 fills in. They are the only header bytes allowed to differ.
MASK = ((40, 8), (58, 2), (60, 2), (62, 2))


def read(path):
    with open(path, 'rb') as f:
        return f.read()


def header(b):
    return {
        'type': struct.unpack_from('<H', b, 16)[0],
        'machine': struct.unpack_from('<H', b, 18)[0],
        'entry': struct.unpack_from('<Q', b, 24)[0],
        'phoff': struct.unpack_from('<Q', b, 32)[0],
        'shoff': struct.unpack_from('<Q', b, 40)[0],
        'flags': struct.unpack_from('<I', b, 48)[0],
        'ehsize': struct.unpack_from('<H', b, 52)[0],
        'phentsize': struct.unpack_from('<H', b, 54)[0],
        'phnum': struct.unpack_from('<H', b, 56)[0],
        'shentsize': struct.unpack_from('<H', b, 58)[0],
        'shnum': struct.unpack_from('<H', b, 60)[0],
        'shstrndx': struct.unpack_from('<H', b, 62)[0],
    }


def phdrs(b, e):
    return [struct.unpack_from('<IIQQQQQQ', b, e['phoff'] + i * e['phentsize']) for i in range(e['phnum'])]


def sections(b, e):
    if not e['shnum']:
        return {}
    raw = [struct.unpack_from('<IIQQQQIIQQ', b, e['shoff'] + i * e['shentsize']) for i in range(e['shnum'])]
    names = b[raw[e['shstrndx']][4]:raw[e['shstrndx']][4] + raw[e['shstrndx']][5]]
    out = {}
    for s in raw:
        if s[0] >= len(names):
            continue
        out.setdefault(names[s[0]:names.index(b'\0', s[0])].decode(), s)
    return out


def masked(b):
    b = bytearray(b)
    for off, n in MASK:
        if off + n <= len(b):
            b[off:off + n] = b'\0' * n
    return bytes(b)


passed = 0
for rel in sorted(os.listdir(refdir)):
    ref, new = read(os.path.join(refdir, rel)), read(os.path.join(newdir, rel))
    er, en = header(ref), header(new)

    if er['type'] == 1:                                        # ET_REL: must be identical
        assert new == ref, rel + ': relocatable object changed'
        print(f'PASS: {rel}: ET_REL object byte-for-byte identical to v0.16.0 ({len(new)} bytes)')
        passed += 1
        continue

    assert (en['type'], en['machine'], en['flags'], en['ehsize']) == (er['type'], er['machine'], er['flags'], er['ehsize']), rel
    assert en['entry'] == er['entry'], (rel, hex(en['entry']), hex(er['entry']))
    assert (en['phoff'], en['phentsize'], en['phnum']) == (er['phoff'], er['phentsize'], er['phnum']), rel
    assert phdrs(new, en) == phdrs(ref, er), rel + ': program header table changed'

    secs_r, secs_n = sections(ref, er), sections(new, en)
    # v0.16.0 put the section-name table right after the last loaded byte of a shared object, so its
    # offset is exactly the end of the loaded image; ET_EXEC/PIE had no sections and were pure image.
    limit = secs_r['.shstrtab'][4] if '.shstrtab' in secs_r else len(ref)
    assert masked(new[:limit]) == masked(ref[:limit]), rel + ': loaded image bytes changed'
    assert 'shstrtab' in rel or len(new) > len(ref), rel

    unchanged = 0
    for name, s in secs_r.items():
        if not name:
            continue
        assert name in secs_n, (rel, 'section disappeared', name)
        t = secs_n[name]
        assert (s[1], s[2], s[6], s[7], s[8], s[9]) == (t[1], t[2], t[6], t[7], t[8], t[9]), \
            (rel, 'section header changed', name, s, t)
        if name == '.shstrtab':
            # The section-name table must grow so that .symtab/.strtab can be named: it is the only
            # pre-existing section whose offset, size and bytes are allowed to move. Every section
            # name v0.16.0 had must still be described by it.
            assert set(secs_r) <= set(secs_n), (rel, 'a v0.16.0 section name was dropped from .shstrtab')
            continue
        assert (s[3], s[5]) == (t[3], t[5]), (rel, 'section address/size changed', name, s, t)
        if s[1] != 8:                                          # NOBITS has no file bytes
            assert ref[s[4]:s[4] + s[5]] == new[t[4]:t[4] + t[5]], (rel, 'section content changed', name)
        unchanged += 1

    added = {n for n in set(secs_n) - set(secs_r) if n}   # the NULL section is not a name
    assert '.symtab' in secs_n and '.strtab' in secs_n, (rel, sorted(secs_n))
    if secs_r:                                                 # shared object: append only
        assert added == {'.symtab', '.strtab'}, (rel, sorted(added))
        assert all(secs_n[n][4] >= limit for n in added), (rel, 'symbol table overlaps the loaded image')
    else:                                                      # ET_EXEC / PIE: first real section table
        assert added <= {'.text', '.data', '.bss', '.symtab', '.strtab', '.shstrtab'}, (rel, sorted(added))
    assert not any(n.startswith('.debug') for n in secs_n), (rel, 'unexpected debug section')

    kind = 'ET_DYN shared object' if secs_r and '.dynamic' in secs_n else ('ET_DYN static PIE' if er['type'] == 3 else 'ET_EXEC')
    note = '' if 'so' not in rel else ' (+ .shstrtab extended)'
    print(f'PASS: {rel}: {kind} unchanged -- program headers, entry 0x{er["entry"]:x}, '
          f'{unchanged} pre-existing section(s) byte-identical{note}, appended {sorted(added)}, '
          f'file {len(ref)} -> {len(new)} bytes')
    passed += 1

print(f'PASS: {passed} product(s) compared against the v0.16.0 reference: only the symbol table is new')
PY
echo "PASS: all v0.17.0 source-level-symbol-table regression checks"
