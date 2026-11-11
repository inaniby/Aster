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
# v0.23.71-dev: four of the eleven CASES had no reference at all --
# so_math.so, so_rtinit.so, obj_globals.o and obj_array.o. The comparison
# loop iterated os.listdir(refdir), so those four products were built and
# then silently never looked at; worse, both ET_REL products were among the
# missing four, so the ET_REL branch (er['type'] == 1) had never executed.
# There is no v0.16.0 tag or commit in this repository's history, so a real
# v0.16.0 reference cannot be regenerated. Instead the four are committed as
# an explicitly-labelled v0.23.71-dev frozen snapshot under
# tests/baseline/symtab-frozen/ -- a cross-release shape baseline, never
# passed off as a v0.16.0 image. Against that snapshot the ET_REL assertion
# is the honest section-level invariant (same section set, same header fields,
# same section bytes, .symtab/.strtab present, no .debug_*), not a whole-file
# byte comparison, which for a same-version snapshot would be a tautology and
# would break on any legitimate section-table relayout.
# The loop now walks all eleven products and asserts the fixture set is
# complete, so a missing reference fails loudly instead of shrinking coverage.
#
# v0.23.77-dev: A-16 deliberately stopped registering DT_VERNEED/DT_VERNEEDNUM
# in shared objects, so the v0.23.71-dev frozen snapshot's .dynamic can no
# longer match byte for byte. frozen_invariants() now compares that section
# semantically -- every other tag and offset unchanged, the removed pair still
# absent, and the freed slots zero DT_NULL padding -- and asserts the A-16
# change instead of exempting the section. All other sections stay byte-exact.
#
# Reference images are produced by a real v0.16.0 compiler when ASTER_V16_DIR points at a v0.16.0
# checkout (the directory that holds its src/aster.cpp). Without it the fixtures committed under
# tests/baseline/v0.16.0 are used, so the script always runs. Regenerate the fixtures with:
#
#   ASTER_V16_DIR=/path/to/aster-v0.16.0 FIXTURE_DIR=tests/baseline/v0.16.0 \
#       sh tests/regression-symtab.sh --write-fixtures
#
# Refresh the frozen snapshot (only when a deliberate ET_REL / .so shape change lands):
#
#   sh tests/regression-symtab.sh --write-frozen
#
set -eu
CXX=${CXX:-g++}
# v0.23.64-dev: this suite had never run — the CI orphan gate enumerated
# tests/*-checks.sh and this file does not match that pattern. Two things had
# to change before it could. First, it required a pre-built ./aster instead of
# building its own, which no other suite does and which a fresh checkout (or a
# private worktree) does not have.
OUT=${OUT:-tmp-regression-symtab}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
ASTER=${ASTER:-./aster}
[ -x "$ASTER" ] || { $CXX -std=c++17 -O2 -w src/aster.cpp -o "$OUT/aster"; ASTER="$OUT/aster"; }
FIXTURE_DIR=${FIXTURE_DIR:-tests/baseline/v0.16.0}
FROZEN_DIR=${FROZEN_DIR:-tests/baseline/symtab-frozen}
WRITE_FIXTURES=no
WRITE_FROZEN=no
[ "${1:-}" = "--write-fixtures" ] && WRITE_FIXTURES=yes
[ "${1:-}" = "--write-frozen" ]   && WRITE_FROZEN=yes

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

# --write-frozen uses the *current* compiler, not a v0.16.0 reference: these
# four fixtures are explicitly a v0.23.71-dev shape baseline, never a claim
# about what v0.16.0 emitted.
if [ "$WRITE_FROZEN" = yes ]; then
  rm -rf "$ROOT/$FROZEN_DIR"; mkdir -p "$ROOT/$FROZEN_DIR"
  for c in so_math so_rtinit obj_globals obj_array; do
      build_case "$ROOT/$ASTER" "$c" "$ROOT/$FROZEN_DIR"
  done
  echo "PASS: v0.23.71-dev frozen symtab snapshot written to $FROZEN_DIR"
  exit 0
fi

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
  echo "# four products use the v0.23.71-dev frozen snapshot in $FROZEN_DIR"
  [ -d "$FROZEN_DIR" ] || { echo "no frozen snapshot: restore $FROZEN_DIR or run --write-frozen" >&2; exit 2; }
  mkdir -p "$REF"; cp "$FIXTURE_DIR"/* "$REF"/; cp "$FROZEN_DIR"/* "$REF"/
fi
[ "$WRITE_FIXTURES" = yes ] && { echo "PASS: v0.16.0 reference fixtures written"; exit 0; }

for c in $CASES; do build_case "$ROOT/$ASTER" "$c" "$NEW"; done

# Only the committed-fixture path has "frozen" references. A real ASTER_V16_DIR
# build produces all eleven products from v0.16.0 itself, so every one of them
# goes through the historical assertions.
if [ -z "${ASTER_V16_DIR:-}" ]; then
  FROZEN_FILES="so_math.so so_rtinit.so obj_globals.o obj_array.o"
else
  FROZEN_FILES=""
fi
export FROZEN_FILES

python3 - "$REF" "$NEW" <<'PY'
import os, struct, sys

refdir, newdir = sys.argv[1], sys.argv[2]
# e_shoff, e_shentsize, e_shnum, e_shstrndx: the four header fields v0.16.0 left at zero and
# v0.17.0 fills in. They are the only header bytes allowed to differ.
# v0.23.64-dev: the loaded image is no longer compared against the v0.16.0
# fixture byte for byte. That assertion was never what this suite is for — it
# is named for the *symbol table* — and it stopped being true when the frame
# and spill-slot layout was redesigned around 8-byte slots (v0.23.2-dev;
# ARCHITECTURE.md: "Scalars occupy one 8-byte slot each (slot*8 byte
# offsets)"). `examples/hello.ast` moved `str w0,[sp,#4]` to `str w0,[sp,#8]`
# and `examples/pie_global_rw.ast` moved a spill from `str w0,[sp,#4080]` to
# `str x0,[sp,#4032]`. Both are documented codegen changes, not regressions,
# and an exemption list would only grow: any later legitimate frame change
# would have to be added to it by hand.
#
# What replaces it is the invariant the suite actually exists to hold, which is
# still true of every product: the section table is **append-only**. The
# program header table is already compared field by field above, so what is
# left is that the table (and therefore .symtab/.strtab/.shstrtab) begins at or
# after the last byte a loader maps. A symbol table that overlapped the loaded
# image would be overwritten by the program's own writes.
LOADED_IMAGE_EXEMPT = set()

# v0.23.71-dev: the four products that had no v0.16.0 fixture. They are
# compared against the v0.23.71-dev frozen snapshot with section-level
# invariants instead. A real ASTER_V16_DIR build produces all eleven references
# itself, so in that mode nothing is frozen.
FROZEN = set(os.environ.get('FROZEN_FILES', '').split())
EXPECTED_FILES = {
    'exec_plain', 'exec_globals', 'exec_align', 'exec_rtinit',
    'pie_plain', 'pie_globals', 'link_multi',
    'so_math.so', 'so_rtinit.so', 'obj_globals.o', 'obj_array.o',
}


DT_VERNEED, DT_VERNEEDNUM, DT_NULL = 0x6ffffffe, 0x6fffffff, 0


def dyn_entries(blob, sec):
    off, size = sec[4], sec[5]
    assert size % 16 == 0, ('.dynamic is not a whole number of Elf64_Dyn entries', size)
    return [struct.unpack_from('<qQ', blob, off + j * 16)
            for j in range(size // 16)]


def dynamic_invariants(rel, ref, new, rs, ns):
    """v0.23.77-dev: A-16 plus the deterministic .dynamic fix.

    The v0.23.71-dev frozen snapshot still registers DT_VERNEED/DT_VERNEEDNUM
    naming libc.so.6. This writer has no DT_NEEDED at all, and Android's bionic
    refuses a library whose VERNEED cannot be matched, so A-16 deliberately
    stopped registering the pair. Raw section bytes can no longer match, so
    compare the semantic entry list instead: every other tag -- including every
    section offset -- must still be exactly where the snapshot left it, the
    removed tags must stay gone, and the freed slots must be zero DT_NULL
    padding rather than uninitialised heap bytes. Those bytes used to leak an
    ASLR pointer, which made two identical builds hash differently.
    """
    a, b = dyn_entries(ref, rs), dyn_entries(new, ns)
    assert any(t == DT_VERNEED for t, _ in a), \
        (rel, 'frozen snapshot no longer carries the historical VERNEED')
    assert not any(t in (DT_VERNEED, DT_VERNEEDNUM) for t, _ in b), \
        (rel, 'A-16 regressed: DT_VERNEED registered again')
    a_sem = [(t, v) for t, v in a
             if t not in (DT_VERNEED, DT_VERNEEDNUM, DT_NULL)]
    b_sem = [(t, v) for t, v in b if t != DT_NULL]
    assert a_sem == b_sem, (rel, '.dynamic semantic entries changed', a_sem, b_sem)
    nulls = [(t, v) for t, v in b if t == DT_NULL]
    assert nulls and all(v == 0 for _, v in nulls), \
        (rel, '.dynamic padding is not zero DT_NULL entries', nulls)


def frozen_invariants(rel, ref, new, er, en):
    """A same-version snapshot can only honestly promise section-level shape.

    Whole-file equality would be a tautology here and would fail on any
    legitimate section-table relayout. sh_offset is therefore deliberately
    not pinned; everything a loader or a linker reads is.
    """
    secs_r, secs_n = sections(ref, er), sections(new, en)
    assert (en['type'], en['machine'], en['flags'], en['ehsize']) == \
           (er['type'], er['machine'], er['flags'], er['ehsize']), (rel, 'ELF header changed')
    assert set(secs_r) == set(secs_n), \
        (rel, 'section set changed', sorted(set(secs_r) ^ set(secs_n)))
    for name, s in secs_r.items():
        if not name:
            continue
        t = secs_n[name]
        assert (s[1], s[2], s[3], s[5], s[6], s[7], s[8], s[9]) == \
               (t[1], t[2], t[3], t[5], t[6], t[7], t[8], t[9]), \
            (rel, 'section header changed', name, s, t)
        if s[1] != 8:                                          # NOBITS has no file bytes
            if name == '.dynamic':
                # A-16 deliberately removed DT_VERNEED; see dynamic_invariants.
                dynamic_invariants(rel, ref, new, s, t)
            else:
                assert ref[s[4]:s[4] + s[5]] == new[t[4]:t[4] + t[5]], \
                    (rel, 'section content changed', name)
    assert '.symtab' in secs_n and '.strtab' in secs_n, \
        (rel, 'symbol table missing', sorted(secs_n))
    assert not any(n.startswith('.debug') for n in secs_n), (rel, 'unexpected debug section')
    if er['type'] != 1:
        loaded_end = max([ph[2] + ph[5] for ph in phdrs(new, en) if ph[0] == 1], default=0)
        assert en['shoff'] >= loaded_end, (rel, 'section table overlaps the loaded image')
    return len(secs_n)


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


# A missing reference must fail the suite, not quietly shrink the loop. This
# is the guard that would have caught the four missing products in the first
# place: the old loop iterated os.listdir(refdir) and compared only what it
# happened to find.
available = set(os.listdir(refdir))
assert available == EXPECTED_FILES, \
    ('incomplete reference set', sorted(EXPECTED_FILES - available),
     sorted(available - EXPECTED_FILES))
assert all(os.path.isfile(os.path.join(newdir, rel)) for rel in EXPECTED_FILES), \
    'not every CASES product was built'

passed = 0
etrel = 0
for rel in sorted(available):
    ref, new = read(os.path.join(refdir, rel)), read(os.path.join(newdir, rel))
    er, en = header(ref), header(new)
    frozen = rel in FROZEN

    if er['type'] == 1:                                        # ET_REL branch
        etrel += 1
        if frozen:
            n = frozen_invariants(rel, ref, new, er, en)
            print(f'PASS: {rel}: ET_REL section-level invariants against the '
                  f'v0.23.71-dev frozen snapshot ({n} sections)')
        else:
            assert new == ref, rel + ': relocatable object changed'
            print(f'PASS: {rel}: ET_REL object byte-for-byte identical to v0.16.0 ({len(new)} bytes)')
        passed += 1
        continue

    if frozen:
        n = frozen_invariants(rel, ref, new, er, en)
        print(f'PASS: {rel}: ET_DYN section-level invariants against the '
              f'v0.23.71-dev frozen snapshot ({n} sections)')
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
    if rel in LOADED_IMAGE_EXEMPT:
        print(f'PASS: {rel}: loaded image exempt ({len(new)} bytes) -- program headers, entry '
              f'and section table still compared below')
    else:
        # The section table must begin at or after every byte a loader maps;
        # see the comment on LOADED_IMAGE_EXEMPT.
        # p_offset + p_filesz: the last byte the segment occupies in the file,
        # which for every product this suite builds is also its last mapped
        # byte (a .so is laid out with vaddr == offset).
        loaded_end = max([ph[2] + ph[5] for ph in phdrs(new, en) if ph[0] == 1], default=0)
        assert en['shoff'] >= loaded_end, \
            (rel, 'section table overlaps the loaded image', en['shoff'], loaded_end)
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

assert passed == len(EXPECTED_FILES), ('not every product was compared', passed)
assert etrel >= 2, ('the ET_REL branch did not execute', etrel)
print(f'PASS: {passed} product(s) compared ({passed - len(FROZEN)} against the v0.16.0 '
      f'reference, {len(FROZEN)} against the v0.23.71-dev frozen snapshot); '
      f'ET_REL branch executed {etrel} time(s)')
PY
echo "PASS: all v0.17.0 source-level-symbol-table regression checks"
