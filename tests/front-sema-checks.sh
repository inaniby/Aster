#!/bin/sh
# tests/front-sema-checks.sh — F-04, F-05 and F-11 of the second full source
# audit (AUDIT-v0.23.72-dev.md), repaired in v0.23.74-dev.
#
# F-04: the type-alias / struct / enum tag namespaces were cross-checked only
# from typeAliasDeclaration, so whether a collision was refused depended on
# declaration order: `type P = i32; struct P { ... }` compiled and silently
# shadowed the alias, while the reverse order was refused. One shared
# rejectTagConflict() is now called by all three declaration entry points,
# preserving the historical messages.
#
# F-05: caseValueFits() had no Enum arm, so `switch(enum)` accepted a case
# value outside i32, truncated it at the comparison and matched a different
# label. Enum is an i32 underneath, exactly as for an initializer slot.
#
# F-11: Sema's DerefAssign only annotated the right-hand side, so `*p = true`
# on a ptr<i64> compiled and stored 1 while `a = true` on the same i64 was
# refused. A typed pointer now checks the store against ptrElemType(inner);
# an untyped ptr keeps its historical 64-bit store.
#
# Layers (the project 9-layer shape): strict build; source guards; static
# diagnostic structure; the accept/refuse behavioural matrix; a gcc twin;
# every ELF writer; a coverage census; six mutations; the byte baseline.
set -eu
cd "$(dirname "$0")/.."
. tests/lib/baseline.sh
. tests/lib/verdict.sh
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-front-sema-checks}
W="$OUT/work"
mkdir -p "$W"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
run(){ sh "$RUNNER" "$@"; }
HOSTCC=${HOSTCC:-}
if [ -z "$HOSTCC" ] && command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    HOSTCC=aarch64-linux-gnu-gcc
fi
COVER=0
bump(){ COVER=$((COVER + 1)); }

# ---------------------------------------------------------------------------
printf '%s\n' '[1/9] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"
A=$OUT/aster
grep -qF '#define ASTER_VERSION_STRING "0.23.75-dev"' src/aster.cpp \
    || { echo 'FAIL: the version constant is not 0.23.75-dev' >&2; exit 1; }
bump

# ---------------------------------------------------------------------------
printf '%s\n' '[2/9] Source guards: three entry points, three static checks'
python3 - <<'PY'
import pathlib
s = pathlib.Path('src/aster.cpp').read_text(encoding='utf-8')
guards = [
    ('shared tag cross-check',       'void rejectTagConflict(const Token& id,const std::string& kind){', 1),
    ('struct/union entry point',     'rejectTagConflict(id,kind);', 1),
    ('enum entry point',             'rejectTagConflict(id,"enum");', 1),
    ('type alias entry point',       'rejectTagConflict(id,"type alias");', 1),
    ('enum range in both tables',    'case Ty::Enum: return enumValueFits(folded);', 2),
    ('DerefAssign checked store',    'checkValue(ptrElemType(inner),*s.expr,actual,"type mismatch assigning through a pointer",false);', 1),
    ('old scattered alias check gone', 'if(g_typeAlias.count(id.s))throw Error(loc(id.line,id.col,"duplicate type alias: "', 0),
]
for label, text, want in guards:
    got = s.count(text)
    assert got == want, f'{label}: found {got}, wanted {want}'
    print(f'  {label:44s} {"absent" if want == 0 else "pinned"}')
PY
bump

# ---------------------------------------------------------------------------
# Corpus. Every rejection message and every exit status below is measured
# against the repaired compiler, not inferred from reading source.
python3 - "$W" <<'PY'
import pathlib, sys
w = pathlib.Path(sys.argv[1])
C = {}
# F-04: all six ordered pairs of the three tag namespaces, plus the three
# same-kind duplicates and the union spelling of a struct tag.
C['tag_alias_struct'] = '''type P = i32;
struct P { x: i32 }
fn main()->i32 { return 0; }
'''
C['tag_alias_enum'] = '''type P = i32;
enum P { A }
fn main()->i32 { return 0; }
'''
C['tag_struct_alias'] = '''struct P { x: i32 }
type P = i32;
fn main()->i32 { return 0; }
'''
C['tag_struct_enum'] = '''struct P { x: i32 }
enum P { A }
fn main()->i32 { return 0; }
'''
C['tag_enum_alias'] = '''enum P { A }
type P = i32;
fn main()->i32 { return 0; }
'''
C['tag_enum_struct'] = '''enum P { A }
struct P { x: i32 }
fn main()->i32 { return 0; }
'''
C['tag_alias_alias'] = '''type P = i32;
type P = u16;
fn main()->i32 { return 0; }
'''
C['tag_struct_struct'] = '''struct P { x: i32 }
struct P { y: i32 }
fn main()->i32 { return 0; }
'''
C['tag_enum_enum'] = '''enum P { A }
enum P { B }
fn main()->i32 { return 0; }
'''
C['tag_union_alias'] = '''union P { x: i32 }
type P = i32;
fn main()->i32 { return 0; }
'''
C['tag_distinct'] = '''type A = i32;
struct B { x: i32 }
enum C { Red }
fn main()->i32 { let a: A = 1; let b: B = B { 2 }; let c: C = Red;
    return a + b.x + i32(c); }
'''
# F-05
C['enum_case_big'] = '''enum Color { Red = 0 }
fn main()->i32 { let c: Color = Red;
    switch (c) { case 4294967296: return 1; default: return 0; } }
'''
C['enum_case_ok'] = '''enum Color { Red = 0, Green = 1 }
fn main()->i32 { let c: Color = Green;
    switch (c) { case 0: return 10; case 1: return 20; default: return 30; } }
'''
C['enum_case_neg'] = '''enum Color { Red = 0 }
fn main()->i32 { let c: Color = Red;
    switch (c) { case -4294967296: return 1; default: return 0; } }
'''
C['i32_case_big'] = '''fn main()->i32 { let c: i32 = 0;
    switch (c) { case 4294967296: return 1; default: return 0; } }
'''
# F-11
C['deref_bool'] = '''fn main()->i32 { let a: i64 = 7; let p: ptr<i64> = &a;
    *p = true; if (a == 1) { return 1; } return 0; }
'''
C['deref_ok'] = '''fn main()->i32 { let a: i64 = 7; let p: ptr<i64> = &a;
    *p = 42; if (a == 42) { return 1; } return 0; }
'''
C['deref_u8_ok'] = '''fn main()->i32 { let a: u8 = 7; let p: ptr<u8> = &a;
    *p = 9; if (a == 9) { return 1; } return 0; }
'''
C['deref_i32_expr'] = '''fn main()->i32 { let a: i64 = 7; let p: ptr<i64> = &a;
    let w: i32 = 5; *p = w; return 0; }
'''
# An untyped ptr keeps its historical 64-bit store; the F-11 check applies
# only to typed pointers. Both spellings of taking the address are witnessed.
C['untyped1'] = '''let g: i32[4] = 0;
fn main()->i32 { let p: ptr = &g; *p = 42; if (g[0] == 42) { return 1; } return 0; }
'''
C['untyped2'] = '''let g: i32[4] = 0;
fn main()->i32 { let p: ptr = &g[0]; *p = 42; if (g[0] == 42) { return 1; } return 0; }
'''
for n, src in C.items():
    (w / (n + '.ast')).write_text(src)
PY

printf '%s\n' '[3/9] Static diagnostics: every refusal is a positioned, caret-backed error'
for n in tag_alias_struct tag_alias_enum tag_struct_alias tag_struct_enum \
         tag_enum_alias tag_enum_struct tag_alias_alias tag_struct_struct \
         tag_enum_enum tag_union_alias enum_case_big enum_case_neg \
         i32_case_big deref_bool; do
    if "$A" build-elf "$W/$n.ast" -o "$W/$n.elf" >"$W/$n.diag" 2>&1; then
        echo "FAIL: $n is accepted but must be refused" >&2; exit 1
    fi
    head -1 "$W/$n.diag" | grep -qE ': error: .* at [0-9]+:[0-9]+$' \
        || { echo "FAIL: $n has no structured diagnostic" >&2; head -3 "$W/$n.diag" >&2; exit 1; }
    grep -qE '^ *\^$' "$W/$n.diag" \
        || { echo "FAIL: $n has no source caret" >&2; exit 1; }
    bump
done
# The three failure families must stay distinct: a tag collision is not a
# type mismatch, and an out-of-range case value is neither.
grep -qF 'conflicts with' "$W/tag_alias_struct.diag" \
    || { echo 'FAIL: tag collisions no longer report a conflict' >&2; exit 1; }
grep -qF 'case value does not fit the switch subject type' "$W/enum_case_big.diag" \
    || { echo 'FAIL: the enum case refusal changed' >&2; exit 1; }
grep -qF 'type mismatch assigning through a pointer' "$W/deref_bool.diag" \
    || { echo 'FAIL: the DerefAssign refusal changed' >&2; exit 1; }
bump

printf '%s\n' '[4/9] Behavioural matrix: accepted side and the full refusal matrix'
accept(){ # <name> <expected exit>
    if ! "$A" build-elf "$W/$1.ast" -o "$W/$1.elf" >"$W/$1.build" 2>&1; then
        echo "FAIL: $1 no longer compiles" >&2; sed -n '1,3p' "$W/$1.build" >&2; exit 1
    fi
    rc=0; run "$W/$1.elf" >/dev/null 2>&1 || rc=$?
    [ "$rc" = "$2" ] || { echo "FAIL: $1 returned $rc, expected $2" >&2; exit 1; }
    printf '  %-30s accept exit %s\n' "$1" "$rc"; bump
}
refuse(){ # <name> <needle>
    if "$A" build-elf "$W/$1.ast" -o "$W/$1.elf" >"$W/$1.build" 2>&1; then
        echo "FAIL: $1 is accepted but must be refused" >&2; exit 1
    fi
    grep -qF "$2" "$W/$1.build" \
        || { echo "FAIL: $1 refused for the wrong reason" >&2; sed -n '1,3p' "$W/$1.build" >&2; exit 1; }
    printf '  %-30s refused\n' "$1"; bump
}
if ! "$A" build-elf examples/front_sema.ast -o "$W/example.elf" >"$W/ex.build" 2>&1; then
    echo 'FAIL: examples/front_sema.ast does not build' >&2; exit 1
fi
rc=0; run "$W/example.elf" >/dev/null 2>&1 || rc=$?
[ "$rc" = 28 ] || { echo "FAIL: shipped example returned $rc, expected 28" >&2; exit 1; }
printf '  %-30s accept exit 28\n' 'front_sema (shipped)'; bump
accept tag_distinct 3
accept enum_case_ok 20
accept deref_ok 1
accept deref_u8_ok 1
accept deref_i32_expr 0
accept untyped1 1
accept untyped2 1
refuse tag_alias_struct 'struct name conflicts with a type alias: P'
refuse tag_alias_enum   'enum name conflicts with a type alias: P'
refuse tag_struct_alias 'type alias conflicts with a struct: P'
refuse tag_struct_enum  'enum name conflicts with a struct: P'
refuse tag_enum_alias   'type alias conflicts with an enum: P'
refuse tag_enum_struct  'struct name conflicts with an enum: P'
refuse tag_alias_alias  'duplicate type alias: P'
refuse tag_struct_struct 'duplicate struct declaration: P'
refuse tag_enum_enum    'duplicate enum declaration: P'
refuse tag_union_alias  'type alias conflicts with a struct: P'
refuse enum_case_big    'case value does not fit the switch subject type'
refuse enum_case_neg    'case value does not fit the switch subject type'
refuse i32_case_big     'case value does not fit the switch subject type'
refuse deref_bool       'type mismatch assigning through a pointer: expected i64, got bool'

# ---------------------------------------------------------------------------
printf '%s\n' '[5/9] C twin: gcc computes the same accepted-side answer'
if [ -n "$HOSTCC" ]; then
    $HOSTCC -static -O2 tests/front-sema-twin.c -o "$W/twin" >/dev/null 2>&1 \
        || { echo 'FAIL: cannot build the C twin' >&2; exit 1; }
    rc=0; run "$W/twin" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 28 ] \
        || { echo "FAIL: the C twin returned $rc, Aster returned 28" >&2; exit 1; }
    printf '  %-40s %s\n' 'gcc twin agrees on enum/pointer semantics' 'yes'; bump
else
    printf '%s\n' 'SKIP: no cross gcc; the C twin did not run'
fi

# ---------------------------------------------------------------------------
printf '%s\n' '[6/9] Every writer: EXEC, PIE, DYN and ET_REL'
"$A" build-elf     examples/front_sema.ast -o "$W/w.elf" >/dev/null 2>&1 \
    || { echo 'FAIL: build-elf failed' >&2; exit 1; }; bump
"$A" build-pie     examples/front_sema.ast -o "$W/w.pie" >/dev/null 2>&1 \
    || { echo 'FAIL: build-pie failed' >&2; exit 1; }; bump
"$A" build-so      examples/front_sema.ast -o "$W/w.so"  >/dev/null 2>&1 \
    || { echo 'FAIL: build-so failed' >&2; exit 1; }; bump
"$A" build-obj --pic examples/front_sema.ast -o "$W/w.o" >/dev/null 2>&1 \
    || { echo 'FAIL: build-obj --pic failed' >&2; exit 1; }; bump
if command -v aarch64-linux-gnu-readelf >/dev/null 2>&1; then
    aarch64-linux-gnu-readelf -h "$W/w.elf" | grep -q 'EXEC' \
        || { echo 'FAIL: build-elf is not ET_EXEC' >&2; exit 1; }
    aarch64-linux-gnu-readelf -h "$W/w.pie" | grep -q 'DYN' \
        || { echo 'FAIL: build-pie is not ET_DYN' >&2; exit 1; }
    aarch64-linux-gnu-readelf -h "$W/w.so"  | grep -q 'DYN' \
        || { echo 'FAIL: build-so is not ET_DYN' >&2; exit 1; }
    aarch64-linux-gnu-readelf -h "$W/w.o"   | grep -q 'REL' \
        || { echo 'FAIL: build-obj is not ET_REL' >&2; exit 1; }
    printf '  %-40s %s\n' 'four ELF types verified' 'yes'; bump
fi
rc=0; run "$W/w.pie" >/dev/null 2>&1 || rc=$?
[ "$rc" = 28 ] || { echo "FAIL: the PIE returned $rc, expected 28" >&2; exit 1; }
bump

# ---------------------------------------------------------------------------
printf '%s\n' '[7/9] Coverage census'
[ "$COVER" -ge 46 ] \
    || { echo "FAIL: only $COVER invariants exercised" >&2; exit 1; }
printf '  %-40s %s\n' 'invariants exercised' "$COVER"; bump

# ---------------------------------------------------------------------------
printf '%s\n' '[8/9] Mutations: every edit must be tested'
mut_check(){ # <mutant binary> -> 0 when the damaged compiler still behaves
    "$1" build-elf examples/front_sema.ast -o "$W/m.elf" >/dev/null 2>&1 || return 1
    rc=0; run "$W/m.elf" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 28 ] || return 1
    for n in tag_distinct enum_case_ok deref_ok deref_u8_ok deref_i32_expr untyped1 untyped2; do
        "$1" build-elf "$W/$n.ast" -o "$W/m_$n.elf" >/dev/null 2>&1 || return 1
        run "$W/m_$n.elf" >/dev/null 2>&1 || return 1
    done
    for n in tag_alias_struct tag_alias_enum tag_struct_alias tag_struct_enum \
             tag_enum_alias tag_enum_struct tag_alias_alias tag_struct_struct \
             tag_enum_enum tag_union_alias enum_case_big enum_case_neg \
             i32_case_big deref_bool; do
        if "$1" build-elf "$W/$n.ast" -o "$W/m_$n.elf" >/dev/null 2>&1; then return 1; fi
    done
    return 0
}
mutate(){ # <label> <old> <new> [expected occurrences]
    python3 - "$2" "$3" "${4:-1}" <<'PY'
import pathlib, sys
s = pathlib.Path('src/aster.cpp').read_text(encoding='utf-8')
old, new, want = sys.argv[1], sys.argv[2], int(sys.argv[3])
got = s.count(old)
assert got == want, (got, want, old[:70])
pathlib.Path('tmp-mut.cpp').write_text(s.replace(old, new), encoding='utf-8')
PY
    mv tmp-mut.cpp "$W/mut.cpp"
    $CXX -std=c++17 -O2 -w "$W/mut.cpp" -o "$W/mut.aster" >/dev/null 2>&1 \
        || { echo "FAIL: $1 mutant does not compile" >&2; exit 1; }
    if mut_check "$W/mut.aster"; then
        # "went unnoticed" is the survivor-assertion wording the aggregate
        # mutation-score census greps for; keep this failing path visible.
        echo "FAIL: mutation '$1' went unnoticed" >&2; exit 1
    fi
    printf '  %-42s %s\n' "$1" 'caught'; bump
}
mutate 'm1: struct entry drops the cross-check' \
    'rejectTagConflict(id,kind);' ';'
mutate 'm2: enum entry drops the cross-check' \
    'rejectTagConflict(id,"enum");' ';'
mutate 'm3: type alias entry drops the cross-check' \
    'rejectTagConflict(id,"type alias");' ';'
# Only caseValueFits' Enum arm is targeted: initializerFits has an identical
# line, so the two-line anchor selects the switch-case table.
mutate 'm4: enum case values are unchecked' \
    '        case Ty::Enum: return enumValueFits(folded);
        // v0.23.48-dev: u64 holds every folded value' \
    '        case Ty::Enum: return true;
        // v0.23.48-dev: u64 holds every folded value'
mutate 'm5: DerefAssign type check removed' \
    '                if(tyIsPtrToElem(inner))
                    checkValue(ptrElemType(inner),*s.expr,actual,"type mismatch assigning through a pointer",false);' \
    '                if(false)
                    checkValue(ptrElemType(inner),*s.expr,actual,"type mismatch assigning through a pointer",false);'
mutate 'm6: DerefAssign checks the wrong element type' \
    'checkValue(ptrElemType(inner),*s.expr,actual,"type mismatch assigning through a pointer",false);' \
    'checkValue(Ty::Bool,*s.expr,actual,"type mismatch assigning through a pointer",false);'

# ---------------------------------------------------------------------------
printf '%s\n' '[9/9] Byte baseline: the new example reproduces, older rows do not move'
BASE=$(aster_baseline_file)
rows=$(grep '^front_sema\.' "$BASE" | LC_ALL=C sort)
[ "$(printf '%s\n' "$rows" | wc -l)" = 3 ] \
    || { echo 'FAIL: the baseline must pin exactly three front_sema rows' >&2; exit 1; }
printf '%s\n' "$rows" > "$W/ours.rows"
while IFS= read -r spec; do
    [ -z "$spec" ] && continue
    key=${spec% *}; val=${spec#* }
    mode=${key#*.}; base=${key%.*}
    case "$mode" in
        build-so) m='build-so' ;;
        build-elf) m='build-elf' ;;
        build-obj_--pic) m='build-obj --pic' ;;
    esac
    # shellcheck disable=SC2086
    if "$A" $m "examples/$base.ast" -o "$W/$key" >/dev/null 2>&1; then
        got=$(sha256sum "$W/$key" | cut -d' ' -f1)
    else
        got=FAILED
    fi
    [ "$got" = "$val" ] \
        || { echo "FAIL: $key baseline moved: expected $val, got $got" >&2; exit 1; }
done < "$W/ours.rows"
printf '  %-40s %s\n' 'front_sema rows reproduced' '3'; bump
_cur_v=$(aster_baseline_version)
_prev_v=$(ls tests/baseline/ | grep -v "^v${_cur_v}\$" | sort -V | tail -1)
PREV="tests/baseline/${_prev_v}/example-hashes.txt"
moved=$(awk 'NR==FNR{a[$1]=$2;next} ($1 in a) && a[$1]!=$2 {print $1}' "$PREV" "$BASE")
[ -z "$moved" ] \
    || { echo "FAIL: this round moved bytes of an older program: $moved" >&2; exit 1; }
prev_rows=$(wc -l < "$PREV")
[ "$prev_rows" = 390 ] \
    || { echo "FAIL: previous baseline has $prev_rows rows, expected 390" >&2; exit 1; }
printf '  %-40s %s\n' 'pre-existing rows unchanged' "$prev_rows"; bump

printf '%s\n' 'PASS: all v0.23.74-dev F-04 / F-05 / F-11 frontend semantics checks'
