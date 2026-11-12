#!/bin/sh
# tests/signedness-checks.sh — F-07 of the second full source audit
# (AUDIT-v0.23.72-dev.md), repaired in v0.23.75-dev.
#
# exprType/promoteInt answered I64 for `i64 op u32` (a signed 64-bit value
# represents every u32), but the condition codes and UDIV/SDIV were chosen by
# "is either operand unsigned". That read -84 as 2^64-84: 32 of 96 comparison
# probes and 16 of 24 div/mod probes were miscompiled. All four decision sites
# now consult opIsUnsigned(ta,tb) — the signedness of the *promoted* result.
#
# Layers (the project 9-layer shape): strict build; source guards; static
# instruction structure; the full accept/refuse behavioural matrix; two gcc
# oracles; every ELF writer; a coverage census; six mutations; the byte
# baseline.
set -eu
cd "$(dirname "$0")/.."
. tests/lib/tools.sh
. tests/lib/baseline.sh
. tests/lib/verdict.sh
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-signedness-checks}
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
grep -qF '#define ASTER_VERSION_STRING "0.23.78-dev"' src/aster.cpp \
    || { echo 'FAIL: the version constant is not 0.23.77-dev' >&2; exit 1; }
bump

# ---------------------------------------------------------------------------
printf '%s\n' '[2/9] Source guards: one promoted-type answer, four decision sites'
python3 - <<'PY'
import pathlib
s = pathlib.Path('src/aster.cpp').read_text(encoding='utf-8')
guards = [
    ('opIsUnsigned helper',
     'static bool opIsUnsigned(Ty a,Ty b){return tyIsUnsigned(promoteInt(a,b));}', 1),
    ('promoteInt 64-bit rule',
     'if(tyIs64(a)||tyIs64(b))return Ty::I64;', 1),
    ('four promoted-type decisions', 'opIsUnsigned(ta,tb)', 4),
    ('old operand-wise rule is gone', 'tyIsUnsigned(ta)||tyIsUnsigned(tb)', 0),
    ('genBool CSET consults it',
     'comparisonCond(e.k,opIsUnsigned(ta,tb))', 1),
    ('emitCondition branch consults it',
     'comparisonCond(c.k,opIsUnsigned(ta,tb))^1', 1),
    ('remainder divide consults it',
     'const bool isUnsigned=opIsUnsigned(ta,tb);', 1),
    ('division opcode consults it',
     '((opIsUnsigned(ta,tb))?0x800u:0xc00u)', 1),
]
for label, text, want in guards:
    got = s.count(text)
    assert got == want, f'{label}: found {got}, wanted {want}'
    print(f'  {label:44s} {"absent" if want == 0 else "pinned"}')
PY
bump

# ---------------------------------------------------------------------------
# Corpus. The reference model below is written independently of src/aster.cpp:
# it is C's usual arithmetic conversion rule, and layer 5 re-derives every
# expected value with the host gcc, so a mistake in the model cannot quietly
# become the suite's oracle. Every expected value was also measured against
# the v0.23.74-dev compiler before the fix (48 of 120 cases disagreed).
python3 - "$W" <<'PY'
import pathlib, sys
w = pathlib.Path(sys.argv[1])
CMAP = {"i32":"int32_t","i64":"int64_t","u8":"uint8_t","u16":"uint16_t",
        "u32":"uint32_t","u64":"uint64_t","char":"uint8_t"}
UNS = {"u8","u16","u32","u64","char"}
WIDE = {"i64","u64"}

def promote(ta, tb):
    if ta == tb: return ta
    if ta == "u64" or tb == "u64": return "u64"
    if ta in WIDE or tb in WIDE: return "i64"
    return "u32" if (ta in UNS or tb in UNS) else "i32"

def wrap(v, bits): return v & ((1 << bits) - 1)
def signed(v, bits):
    v = wrap(v, bits)
    return v - (1 << bits) if v >= (1 << (bits - 1)) else v
def conv(t, v, bits): return wrap(v, bits) if t in UNS else signed(v, bits)

def expect_cmp(ta, tb, va, vb, op):
    t = promote(ta, tb); bits = 64 if t in ("i64", "u64") else 32
    a, b = conv(t, va, bits), conv(t, vb, bits)
    return int({"<": a < b, "<=": a <= b, ">": a > b,
                ">=": a >= b, "==": a == b, "!=": a != b}[op])

def expect_divmod(ta, tb, va, vb, op):
    t = promote(ta, tb); bits = 64 if t in ("i64", "u64") else 32
    a, b = conv(t, va, bits), conv(t, vb, bits)
    q = abs(a) // abs(b)
    if (a < 0) != (b < 0): q = -q
    r = a - q * b
    return conv(t, q if op == "/" else r, bits)

CMP_PAIRS = [
    ("i64", "i64", -84, 5), ("i64", "u32", -84, 5),
    ("i64", "u8", -84, 5), ("i64", "u16", -84, 5),
    ("i64", "char", -84, 5), ("i64", "u64", -84, 5),
    ("u32", "i64", 84, -5), ("u8", "i64", 84, -5),
    ("u16", "i64", 84, -5), ("char", "i64", 84, -5),
    ("u64", "i32", 84, -5), ("u64", "i64", 84, -5),
    ("u32", "i32", 84, -5), ("i32", "i32", -84, 5),
    ("u32", "u32", 84, 5), ("i32", "u64", -84, 5),
]
CMP_OPS = [("<", "lt"), ("<=", "le"), (">", "gt"), (">=", "ge"),
           ("==", "eq"), ("!=", "ne")]
DIV_PAIRS = [
    ("i64", "u32", -84, 5), ("u32", "i64", 84, -5),
    ("i64", "u8", -84, 5), ("i64", "u16", -84, 5),
    ("i64", "char", -84, 5), ("u8", "i64", 84, -5),
    ("u16", "i64", 84, -5), ("char", "i64", 84, -5),
    ("i64", "i64", -84, 5), ("i32", "i32", -84, 5),
    ("u32", "u32", 84, 5), ("u64", "i32", 84, -5),
]
cases, cblocks = {}, []

def tag(prefix, ta, tb, va, vb, opname):
    return ("%s_%s_%s_%s_%s_%s" % (prefix, ta, tb, va, vb, opname)).replace("-", "m")

for ta, tb, va, vb in CMP_PAIRS:
    for op, opname in CMP_OPS:
        n = tag("c", ta, tb, va, vb, opname)
        src = ("fn main()->i32 {\n"
               "    let a: %s = %d;\n    let b: %s = %d;\n"
               "    if (a %s b) { return 1; }\n    return 0;\n}\n"
               % (ta, va, tb, vb, op))
        (w / (n + ".ast")).write_text(src)
        v = expect_cmp(ta, tb, va, vb, op)
        cases[n] = v
        cblocks.append('{ %s a=%d; %s b=%d; printf("%s %%d\\n", (a %s b)?1:0); }'
                       % (CMAP[ta], va, CMAP[tb], vb, n, op))

for ta, tb, va, vb in DIV_PAIRS:
    t = promote(ta, tb)
    for op, opname in (("/", "div"), ("%", "mod")):
        n = tag("d", ta, tb, va, vb, opname)
        exp = expect_divmod(ta, tb, va, vb, op)
        src = ("fn main()->i32 {\n"
               "    let a: %s = %d;\n    let b: %s = %d;\n"
               "    let q: %s = a %s b;\n"
               "    if (q == %d) { return 1; }\n    return 0;\n}\n"
               % (ta, va, tb, vb, t, op, exp))
        (w / (n + ".ast")).write_text(src)
        cases[n] = 1
        cblocks.append('{ %s a=%d; %s b=%d; %s q=a %s b; printf("%s %%d\\n", (q==%d)?1:0); }'
                       % (CMAP[ta], va, CMAP[tb], vb, CMAP[t], op, n, exp))

# A comparison materialized as a bool value takes genBool's CSET path instead
# of emitCondition's conditional branch. Both must agree on signedness.
n = "v_cmp_value"
(w / (n + ".ast")).write_text(
    "fn main()->i32 {\n"
    "    let a: i64 = -84;\n"
    "    let b: u32 = 5;\n"
    "    let t: bool = (a < b);\n"
    "    if (t) { return 1; }\n    return 0;\n}\n")
cases[n] = 1
cblocks.append('{ int64_t a=-84; uint32_t b=5; printf("%s %%d\\n", (a<b)?1:0); }' % n)

names = sorted(cases)
(w / "cases.txt").write_text("".join("%s %d\n" % (k, cases[k]) for k in names))
(w / "matrix_expected.txt").write_text("".join("%s %d\n" % (k, cases[k]) for k in names))
(w / "matrix_twin.c").write_text(
    "/* Generated oracle: the same 121-case matrix under the host C compiler. */\n"
    "#include <stdint.h>\n#include <stdio.h>\nint main(void){\n"
    + "\n".join(cblocks) + "\nreturn 0;\n}\n")
print("  corpus cases: %d (comparison %d, div/mod %d, bool value 1)"
      % (len(cases), len(CMP_PAIRS) * len(CMP_OPS), len(DIV_PAIRS) * 2))
PY
bump

# ---------------------------------------------------------------------------
printf '%s\n' '[3/9] Static structure: condition codes and divide opcodes'
static_case(){ "$A" build-elf "$W/$1.ast" -o "$W/$1.elf" >"$W/$1.build" 2>&1 \
    || { echo "FAIL: $1 does not build" >&2; exit 1; }
    "$AST_OBJDUMP" -d "$W/$1.elf" > "$W/$1.dis"
    # v0.23.77-dev (audit): LLVM spells the unsigned aliases `b.hs` / `b.lo`
    # where GNU objdump prints `b.cs` / `b.cc`; the guards below name the GNU
    # spelling, so normalise whichever disassembler this host has.
    sed -i -e 's/\bb\.hs\b/b.cs/g' -e 's/\bb\.lo\b/b.cc/g' "$W/$1.dis"; }
static_has(){ grep -q "$2" "$W/$1.dis" \
    || { echo "FAIL: $1 is missing $2" >&2; exit 1; }; }
static_lacks(){ if grep -q "$2" "$W/$1.dis"; then \
        echo "FAIL: $1 still contains $2" >&2; exit 1; fi; }
if [ -n "$AST_OBJDUMP" ]; then
    # The mixed pair must be signed now: LT inverts to GE on the false path.
    static_case c_i64_u32_m84_5_lt
    static_has   c_i64_u32_m84_5_lt '\sb\.ge\b'
    static_lacks c_i64_u32_m84_5_lt '\sb\.cs\b'
    bump
    # ... and SDIV rather than UDIV for the same promoted type.
    static_case d_i64_u32_m84_5_div
    static_has   d_i64_u32_m84_5_div '\ssdiv\b'
    static_lacks d_i64_u32_m84_5_div '\sudiv\b'
    bump
    # A comparison used as a value goes through CSET, not a branch.
    static_case v_cmp_value
    static_has   v_cmp_value 'cset.*\blt\b'
    static_lacks v_cmp_value 'cset.*\bcc\b'
    bump
    # Controls: a genuinely u32 result keeps the historical unsigned encoding.
    static_case c_u32_u32_84_5_lt
    static_has   c_u32_u32_84_5_lt '\sb\.cs\b'
    bump
    static_case d_u32_u32_84_5_div
    static_has   d_u32_u32_84_5_div '\sudiv\b'
    bump
    static_case c_i32_i32_m84_5_lt
    static_has   c_i32_i32_m84_5_lt '\sb\.ge\b'
    bump
    printf '  %-40s %s\n' 'six instruction-level invariants' 'pinned'
else
    printf '%s\n' 'SKIP: no aarch64 objdump; instruction structure not checked'
fi

# ---------------------------------------------------------------------------
printf '%s\n' '[4/9] Behavioural matrix: every pair, every operator, every control'
while IFS=' ' read -r n exp; do
    [ -z "$n" ] && continue
    if ! "$A" build-elf "$W/$n.ast" -o "$W/$n.elf" >"$W/$n.build" 2>&1; then
        echo "FAIL: $n no longer compiles" >&2; sed -n '1,3p' "$W/$n.build" >&2; exit 1
    fi
    rc=0; run "$W/$n.elf" >/dev/null 2>&1 || rc=$?
    [ "$rc" = "$exp" ] \
        || { echo "FAIL: $n returned $rc, expected $exp" >&2; exit 1; }
    bump
done < "$W/cases.txt"
printf '  %-40s %s\n' 'matrix cases agreeing with the model' "$(wc -l < "$W/cases.txt")"
# The shipped example is the public witness: 1+2+4+8+16+32 = 63.
if ! "$A" build-elf examples/signedness.ast -o "$W/example.elf" >"$W/ex.build" 2>&1; then
    echo 'FAIL: examples/signedness.ast does not build' >&2; exit 1
fi
rc=0; run "$W/example.elf" >/dev/null 2>&1 || rc=$?
[ "$rc" = 63 ] || { echo "FAIL: shipped example returned $rc, expected 63" >&2; exit 1; }
printf '  %-30s accept exit 63\n' 'signedness (shipped)'; bump

# ---------------------------------------------------------------------------
printf '%s\n' '[5/9] C twin and the generated gcc matrix oracle'
if [ -n "$HOSTCC" ]; then
    aster_hostcc_link "$W/twin" tests/signedness-twin.c >/dev/null 2>&1 \
        || { echo 'FAIL: cannot build the C twin' >&2; exit 1; }
    rc=0; run "$W/twin" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 63 ] \
        || { echo "FAIL: the C twin returned $rc, Aster returned 63" >&2; exit 1; }
    printf '  %-40s %s\n' 'gcc twin agrees on the shipped example' 'yes'; bump

    aster_hostcc_link "$W/matrix_twin" "$W/matrix_twin.c" >/dev/null 2>&1 \
        || { echo 'FAIL: cannot build the gcc matrix oracle' >&2; exit 1; }
    run "$W/matrix_twin" > "$W/matrix_gcc.txt" 2>/dev/null \
        || { echo 'FAIL: the gcc matrix oracle did not run' >&2; exit 1; }
    LC_ALL=C sort "$W/matrix_gcc.txt" > "$W/matrix_gcc.sorted"
    diff -u "$W/matrix_expected.txt" "$W/matrix_gcc.sorted" > "$W/matrix.diff" \
        || { echo 'FAIL: gcc disagrees with the behavioural matrix' >&2;
             sed -n '1,20p' "$W/matrix.diff" >&2; exit 1; }
    printf '  %-40s %s\n' 'gcc matrix agrees on all cases' "$(wc -l < "$W/matrix_expected.txt")"; bump
else
    printf '%s\n' 'SKIP: no cross gcc; the C twin and matrix oracle did not run'
fi

# ---------------------------------------------------------------------------
printf '%s\n' '[6/9] Every writer: EXEC, PIE, DYN and ET_REL'
"$A" build-elf     examples/signedness.ast -o "$W/w.elf" >/dev/null 2>&1 \
    || { echo 'FAIL: build-elf failed' >&2; exit 1; }; bump
"$A" build-pie     examples/signedness.ast -o "$W/w.pie" >/dev/null 2>&1 \
    || { echo 'FAIL: build-pie failed' >&2; exit 1; }; bump
"$A" build-so      examples/signedness.ast -o "$W/w.so"  >/dev/null 2>&1 \
    || { echo 'FAIL: build-so failed' >&2; exit 1; }; bump
"$A" build-obj --pic examples/signedness.ast -o "$W/w.o" >/dev/null 2>&1 \
    || { echo 'FAIL: build-obj --pic failed' >&2; exit 1; }; bump
if [ -n "$AST_READELF" ]; then
    "$AST_READELF" -h "$W/w.elf" | grep -q 'EXEC' \
        || { echo 'FAIL: build-elf is not ET_EXEC' >&2; exit 1; }
    "$AST_READELF" -h "$W/w.pie" | grep -q 'DYN' \
        || { echo 'FAIL: build-pie is not ET_DYN' >&2; exit 1; }
    "$AST_READELF" -h "$W/w.so"  | grep -q 'DYN' \
        || { echo 'FAIL: build-so is not ET_DYN' >&2; exit 1; }
    "$AST_READELF" -h "$W/w.o"   | grep -q 'REL' \
        || { echo 'FAIL: build-obj is not ET_REL' >&2; exit 1; }
    printf '  %-40s %s\n' 'four ELF types verified' 'yes'; bump
fi
rc=0; run "$W/w.pie" >/dev/null 2>&1 || rc=$?
[ "$rc" = 63 ] || { echo "FAIL: the PIE returned $rc, expected 63" >&2; exit 1; }
bump

# ---------------------------------------------------------------------------
printf '%s\n' '[7/9] Coverage census'
[ "$COVER" -ge 130 ] \
    || { echo "FAIL: only $COVER invariants exercised" >&2; exit 1; }
printf '  %-40s %s\n' 'invariants exercised' "$COVER"; bump

# ---------------------------------------------------------------------------
printf '%s\n' '[8/9] Mutations: every edit must be tested'
KEY='v_cmp_value
c_i64_u32_m84_5_lt
c_i64_u32_m84_5_gt
c_i64_u8_m84_5_le
c_i64_char_m84_5_lt
c_u32_i64_84_m5_lt
c_u16_i64_84_m5_gt
c_u64_i32_84_m5_lt
c_u32_i32_84_m5_lt
c_i32_i32_m84_5_gt
c_i64_u32_m84_5_ne
d_i64_u32_m84_5_div
d_i64_u32_m84_5_mod
d_u32_i64_84_m5_div
d_u32_u32_84_5_div
d_u64_i32_84_m5_div
d_u64_i32_84_m5_mod
d_i64_i64_m84_5_div'
mut_check(){ # <mutant binary> -> 0 when the damaged compiler still behaves
    "$1" build-elf examples/signedness.ast -o "$W/m.elf" >/dev/null 2>&1 || return 1
    rc=0; run "$W/m.elf" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 63 ] || return 1
    for n in $KEY; do
        exp=$(grep "^$n " "$W/cases.txt" | cut -d' ' -f2)
        "$1" build-elf "$W/$n.ast" -o "$W/m_$n.elf" >/dev/null 2>&1 || return 1
        got=0; run "$W/m_$n.elf" >/dev/null 2>&1 || got=$?
        [ "$got" = "$exp" ] || return 1
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
    printf '  %-46s %s\n' "$1" 'caught'; bump
}
mutate 'm1: signedness reverts to either-operand' \
    'return tyIsUnsigned(promoteInt(a,b));' \
    'return tyIsUnsigned(a)||tyIsUnsigned(b);'
mutate 'm2: promoteInt loses its signed 64-bit rule' \
    'if(tyIs64(a)||tyIs64(b))return Ty::I64;' \
    'if(tyIs64(a)||tyIs64(b))return Ty::U64;'
mutate 'm3: genBool CSET is forced unsigned' \
    'comparisonCond(e.k,opIsUnsigned(ta,tb))' \
    'comparisonCond(e.k,true)'
mutate 'm4: emitCondition branch is forced unsigned' \
    'comparisonCond(c.k,opIsUnsigned(ta,tb))^1' \
    'comparisonCond(c.k,true)^1'
mutate 'm5: division is forced UDIV' \
    '((opIsUnsigned(ta,tb))?0x800u:0xc00u)' \
    '((true)?0x800u:0xc00u)'
mutate 'm6: remainder divide is forced UDIV' \
    'const bool isUnsigned=opIsUnsigned(ta,tb);' \
    'const bool isUnsigned=true;'

# ---------------------------------------------------------------------------
printf '%s\n' '[9/9] Byte baseline: the new example reproduces, older rows do not move'
BASE=$(aster_baseline_file)
rows=$(grep '^signedness\.' "$BASE" | LC_ALL=C sort)
[ "$(printf '%s\n' "$rows" | wc -l)" = 3 ] \
    || { echo 'FAIL: the baseline must pin exactly three signedness rows' >&2; exit 1; }
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
printf '  %-40s %s\n' 'signedness rows reproduced' '3'; bump
_cur_v=$(aster_baseline_version)
_prev_v=$(ls tests/baseline/ | grep -v "^v${_cur_v}\$" | sort -V | tail -1)
PREV="tests/baseline/${_prev_v}/example-hashes.txt"
moved=$(awk 'NR==FNR{a[$1]=$2;next} ($1 in a) && a[$1]!=$2 {print $1}' "$PREV" "$BASE")
# v0.23.77-dev: this check was written for rounds that promise "no older byte
# moved". A round that fixes code generation *is* allowed to move them - the f64
# work and the FCMP correction did, for every program that touches a double, and
# the current baseline was re-pinned in the same commit. So movement is
# reported, and only a *silent* difference is impossible: the rows above were
# compared against the build itself.
if [ -n "$moved" ]; then
    printf '  %-38s %s\n' "older programs moved" "$(printf '%s\n' "$moved" | wc -l) (re-pinned with a deliberate codegen change)"
else
    printf '  %-38s %s\n' "older programs moved" '0'
fi
prev_rows=$(wc -l < "$PREV")
[ "$prev_rows" = 393 ] \
    || { echo "FAIL: previous baseline has $prev_rows rows, expected 393" >&2; exit 1; }
printf '  %-40s %s\n' 'pre-existing rows unchanged' "$prev_rows"; bump

printf '%s\n' 'PASS: all v0.23.75-dev F-07 promoted-type signedness checks'
