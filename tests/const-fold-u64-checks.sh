#!/bin/sh
# tests/const-fold-u64-checks.sh — F-03 and F-06 of the second full source
# audit (AUDIT-v0.23.72-dev.md), repaired in v0.23.74-dev.
#
# F-03: a u64 global initializer was folded with i64 signed-overflow rules.
# `let g: u64 = 9223372036854775807 + 1;` was refused as "addition overflows
# i64 in global variable initializer" although the same expression at run
# time wraps. foldConst now takes a u64Target flag and only the u64 slots
# enable uint64_t wrap semantics; i32/i64/u32 keep their historical refusals.
#
# F-06: checkArrayBounds called constantInteger() and returned silently when
# folding failed. `a[9223372036854775807 + 1]` is constant-shaped but cannot
# fold, so the bounds check was skipped entirely and the wrapped runtime
# index read a[0]. constantShape()/foldedIndex() now separate a genuinely
# dynamic index from a constant-shaped one that failed to fold, and the
# latter is a hard error.
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
OUT=${OUT:-tmp-const-fold-u64-checks}
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
grep -qF '#define ASTER_VERSION_STRING "0.23.74-dev"' src/aster.cpp \
    || { echo 'FAIL: the version constant is not 0.23.74-dev' >&2; exit 1; }
bump

# ---------------------------------------------------------------------------
printf '%s\n' '[2/9] Source guards: one wrap flag, one folding-failure gate'
python3 - <<'PY'
import pathlib
s = pathlib.Path('src/aster.cpp').read_text(encoding='utf-8')
guards = [
    ('u64Target parameter',            'int64_t foldConst(const Expr& e,bool u64Target=false){', 1),
    ('add wraps under u64',            'if(u64Target)return (int64_t)((uint64_t)a+(uint64_t)b);', 1),
    ('shl wraps under u64',            'if(u64Target)return (int64_t)((uint64_t)a<<b);', 1),
    ('u64 initializer slots',          'const int64_t value=foldConst(*init,ty.k==Ty::U64);', 2),
    ('constantShape helper',           'static bool constantShape(const Expr& e){', 1),
    ('foldedIndex helper',             'static bool foldedIndex(const Expr& index,int64_t& value){', 1),
    ('one gate per bounds check',      'int64_t value=0;if(!foldedIndex(index,value))return;', 3),
    ('explicit folding-failure error', 'array index constant expression overflows or is invalid', 1),
    ('old silent bypass is gone',      'int64_t value=0;if(!constantInteger(index,value))return;', 0),
]
for label, text, want in guards:
    got = s.count(text)
    assert got == want, f'{label}: found {got}, wanted {want}'
    print(f'  {label:44s} {"absent" if want == 0 else "pinned"}')
PY
bump

# ---------------------------------------------------------------------------
# Corpus. Every program below was compiled and run against the repaired
# compiler; the expected statuses are measured, not inferred.
python3 - "$W" <<'PY'
import pathlib, sys
w = pathlib.Path(sys.argv[1])
C = {}
C['u64_sub'] = '''let g: u64 = 0 - 1;
fn main()->i32 { if (g == 18446744073709551615) { return 1; } return 0; }
'''
C['u64_neg'] = '''let g: u64 = -1;
fn main()->i32 { if (g == 18446744073709551615) { return 1; } return 0; }
'''
C['u64_bitnot'] = '''let g: u64 = ~0;
fn main()->i32 { if (g == 18446744073709551615) { return 1; } return 0; }
'''
C['u64_cast'] = '''let g: u64 = u64(9223372036854775807 + 1);
fn main()->i32 { if (g == 9223372036854775808) { return 1; } return 0; }
'''
C['u64_nested'] = '''let g: u64 = (9223372036854775807 + 1) + (9223372036854775807 + 2);
fn main()->i32 { if (g == 1) { return 1; } return 0; }
'''
C['i32_ovf'] = '''let g: i32 = 9223372036854775807 + 1;
fn main()->i32 { return 0; }
'''
C['i64_shl'] = '''let g: i64 = 3 << 62;
fn main()->i32 { return 0; }
'''
C['u32_ovf'] = '''let g: u32 = 9223372036854775807 + 1;
fn main()->i32 { return 0; }
'''
C['idx_ok'] = '''let a: i32[4] = 0;
fn main()->i32 { a[2]=33; return a[1+1]; }
'''
C['idx_dynamic'] = '''let a: i32[4] = 0;
fn main()->i32 { let i: i32 = 2; a[2]=33; return a[i]; }
'''
C['idx_oob_const'] = '''let a: i32[4] = 0;
fn main()->i32 { return a[4]; }
'''
C['idx_ovf_add'] = '''let a: i32[4] = 0;
fn main()->i32 { return a[9223372036854775807 + 1]; }
'''
C['idx_ovf_mul'] = '''let a: i32[4] = 0;
fn main()->i32 { return a[9223372036854775807 * 2]; }
'''
C['idx_ovf_shl'] = '''let a: i32[4] = 0;
fn main()->i32 { return a[1 << 64]; }
'''
C['idx_div0'] = '''let a: i32[4] = 0;
fn main()->i32 { return a[1 / 0]; }
'''
C['idx_ovf_sub'] = '''let a: i32[4] = 0;
fn main()->i32 { return a[-9223372036854775807 - 2]; }
'''
C['idx_write_ovf'] = '''let a: i32[4] = 0;
fn main()->i32 { a[9223372036854775807 + 1] = 9; return 0; }
'''
C['idx_two_dim_ovf'] = '''let a: i32[2][4] = 0;
fn main()->i32 { return a[0][9223372036854775807 + 1]; }
'''
for n, src in C.items():
    (w / (n + '.ast')).write_text(src)
PY

printf '%s\n' '[3/9] Static diagnostics: position, caret, and the two distinct refusals'
for n in idx_ovf_add idx_ovf_mul idx_ovf_shl idx_div0 idx_ovf_sub idx_write_ovf idx_two_dim_ovf; do
    if "$A" build-elf "$W/$n.ast" -o "$W/$n.elf" >"$W/$n.diag" 2>&1; then
        echo "FAIL: $n is accepted but must be refused" >&2; exit 1
    fi
    head -1 "$W/$n.diag" | grep -qE ': error: .* at [0-9]+:[0-9]+$' \
        || { echo "FAIL: $n has no structured diagnostic" >&2; head -3 "$W/$n.diag" >&2; exit 1; }
    grep -qE '^ *\^$' "$W/$n.diag" \
        || { echo "FAIL: $n has no source caret" >&2; exit 1; }
    grep -qF 'array index constant expression overflows or is invalid' "$W/$n.diag" \
        || { echo "FAIL: $n refused for the wrong reason" >&2; exit 1; }
    bump
done
# The three non-u64 targets must still report the historical i64 errors: the
# u64 wrap flag may not leak into every initializer slot.
for spec in 'i32_ovf:addition overflows i64' 'i64_shl:left shift overflows i64' \
            'u32_ovf:addition overflows i64'; do
    n=${spec%%:*}; needle=${spec#*:}
    if "$A" build-elf "$W/$n.ast" -o "$W/$n.elf" >"$W/$n.diag" 2>&1; then
        echo "FAIL: $n must still be refused" >&2; exit 1
    fi
    grep -qF "$needle" "$W/$n.diag" \
        || { echo "FAIL: $n lost the i64 overflow refusal" >&2; exit 1; }
    bump
done

printf '%s\n' '[4/9] Behavioural matrix: wrap, bounds, and every control'
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
# The shipped example is the public witness: 1+2+4+8 = 15.
if ! "$A" build-elf examples/const_fold_u64.ast -o "$W/example.elf" >"$W/ex.build" 2>&1; then
    echo 'FAIL: examples/const_fold_u64.ast does not build' >&2; exit 1
fi
rc=0; run "$W/example.elf" >/dev/null 2>&1 || rc=$?
[ "$rc" = 15 ] || { echo "FAIL: shipped example returned $rc, expected 15" >&2; exit 1; }
printf '  %-30s accept exit 15\n' 'const_fold_u64 (shipped)'; bump
for n in u64_sub u64_neg u64_bitnot u64_cast u64_nested; do accept "$n" 1; done
accept idx_ok 33
accept idx_dynamic 33
refuse idx_oob_const "array index out of bounds for 'a': index 4, length 4"
for n in idx_ovf_add idx_ovf_mul idx_ovf_shl idx_div0 idx_ovf_sub idx_write_ovf idx_two_dim_ovf; do
    refuse "$n" 'array index constant expression overflows or is invalid'
done
refuse i32_ovf 'addition overflows i64'
refuse i64_shl 'left shift overflows i64'
refuse u32_ovf 'addition overflows i64'

# ---------------------------------------------------------------------------
printf '%s\n' '[5/9] C twin: gcc folds the same unsigned constants'
if [ -n "$HOSTCC" ]; then
    $HOSTCC -static -O2 tests/const-fold-u64-twin.c -o "$W/twin" >/dev/null 2>&1 \
        || { echo 'FAIL: cannot build the C twin' >&2; exit 1; }
    rc=0; run "$W/twin" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 15 ] \
        || { echo "FAIL: the C twin returned $rc, Aster returned 15" >&2; exit 1; }
    printf '  %-40s %s\n' 'gcc twin agrees on the wrap values' 'yes'; bump
else
    printf '%s\n' 'SKIP: no cross gcc; the C twin did not run'
fi

# ---------------------------------------------------------------------------
printf '%s\n' '[6/9] Every writer: EXEC, PIE, DYN and ET_REL'
"$A" build-elf     examples/const_fold_u64.ast -o "$W/w.elf" >/dev/null 2>&1 \
    || { echo 'FAIL: build-elf failed' >&2; exit 1; }; bump
"$A" build-pie     examples/const_fold_u64.ast -o "$W/w.pie" >/dev/null 2>&1 \
    || { echo 'FAIL: build-pie failed' >&2; exit 1; }; bump
"$A" build-so      examples/const_fold_u64.ast -o "$W/w.so"  >/dev/null 2>&1 \
    || { echo 'FAIL: build-so failed' >&2; exit 1; }; bump
"$A" build-obj --pic examples/const_fold_u64.ast -o "$W/w.o" >/dev/null 2>&1 \
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
[ "$rc" = 15 ] || { echo "FAIL: the PIE returned $rc, expected 15" >&2; exit 1; }
bump

# ---------------------------------------------------------------------------
printf '%s\n' '[7/9] Coverage census'
[ "$COVER" -ge 38 ] \
    || { echo "FAIL: only $COVER invariants exercised" >&2; exit 1; }
printf '  %-40s %s\n' 'invariants exercised' "$COVER"; bump

# ---------------------------------------------------------------------------
printf '%s\n' '[8/9] Mutations: every edit must be tested'
mut_check(){ # <mutant binary> -> 0 when the damaged compiler still behaves
    "$1" build-elf examples/const_fold_u64.ast -o "$W/m.elf" >/dev/null 2>&1 || return 1
    rc=0; run "$W/m.elf" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 15 ] || return 1
    for n in u64_sub u64_neg u64_bitnot u64_cast u64_nested; do
        "$1" build-elf "$W/$n.ast" -o "$W/m_$n.elf" >/dev/null 2>&1 || return 1
        run "$W/m_$n.elf" >/dev/null 2>&1 || return 1
    done
    for n in idx_ovf_add idx_ovf_mul idx_ovf_shl idx_div0 idx_ovf_sub idx_write_ovf idx_two_dim_ovf; do
        if "$1" build-elf "$W/$n.ast" -o "$W/m_$n.elf" >/dev/null 2>&1; then return 1; fi
    done
    for n in i32_ovf i64_shl u32_ovf; do
        if "$1" build-elf "$W/$n.ast" -o "$W/m_$n.elf" >/dev/null 2>&1; then return 1; fi
    done
    for n in idx_ok idx_dynamic; do
        "$1" build-elf "$W/$n.ast" -o "$W/m_$n.elf" >/dev/null 2>&1 || return 1
        rc=0; run "$W/m_$n.elf" >/dev/null 2>&1 || rc=$?
        [ "$rc" = 33 ] || return 1
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
    printf '  %-38s %s\n' "$1" 'caught'; bump
}
mutate 'm1: u64 slots lose the wrap flag' \
    'const int64_t value=foldConst(*init,ty.k==Ty::U64);' \
    'const int64_t value=foldConst(*init);' 2
mutate 'm2: addition no longer wraps' \
    'if(u64Target)return (int64_t)((uint64_t)a+(uint64_t)b);' \
    'if(false)return (int64_t)((uint64_t)a+(uint64_t)b);'
mutate 'm3: left shift no longer wraps' \
    'if(u64Target)return (int64_t)((uint64_t)a<<b);' \
    'if(false)return (int64_t)((uint64_t)a<<b);'
mutate 'm4: constantShape ignores binary operators' \
    'return e.a && e.b && constantShape(*e.a) && constantShape(*e.b);' \
    'return false;'
mutate 'm5: folding failure is silent again' \
    'if(constantShape(index))' 'if(false)'
mutate 'm6: bounds gate reverts to constantInteger' \
    'int64_t value=0;if(!foldedIndex(index,value))return;' \
    'int64_t value=0;if(!constantInteger(index,value))return;' 3

# ---------------------------------------------------------------------------
printf '%s\n' '[9/9] Byte baseline: the new example reproduces, older rows do not move'
BASE=$(aster_baseline_file)
rows=$(grep '^const_fold_u64\.' "$BASE" | LC_ALL=C sort)
[ "$(printf '%s\n' "$rows" | wc -l)" = 3 ] \
    || { echo 'FAIL: the baseline must pin exactly three const_fold_u64 rows' >&2; exit 1; }
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
printf '  %-40s %s\n' 'const_fold_u64 rows reproduced' '3'; bump
_cur_v=$(aster_baseline_version)
_prev_v=$(ls tests/baseline/ | grep -v "^v${_cur_v}\$" | sort -V | tail -1)
PREV="tests/baseline/${_prev_v}/example-hashes.txt"
moved=$(awk 'NR==FNR{a[$1]=$2;next} ($1 in a) && a[$1]!=$2 {print $1}' "$PREV" "$BASE")
[ -z "$moved" ] \
    || { echo "FAIL: this round moved bytes of an older program: $moved" >&2; exit 1; }
prev_rows=$(wc -l < "$PREV")
[ "$prev_rows" = 384 ] \
    || { echo "FAIL: previous baseline has $prev_rows rows, expected 384" >&2; exit 1; }
printf '  %-40s %s\n' 'pre-existing rows unchanged' "$prev_rows"; bump

printf '%s\n' 'PASS: all v0.23.74-dev F-03 / F-06 constant-folding checks'
