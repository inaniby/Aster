#!/bin/sh
# tests/char-checks.sh — `char` as an unsigned 8-bit integer type.
#
# AUDIT-v0.23.61-dev.md's third part listed the language's gaps: `typedef`/
# type alias (1), `const` (2), `void` (3), `char` (4), `union` (5). Rounds
# v0.23.67-dev, v0.23.68-dev and v0.23.69-dev close the first four; `union`
# remains. `char` is the smallest gap: a character literal already exists
# (v0.23.50-dev, folding `'a'` to an `i32`), and the compiler already carries a
# full unsigned-8-bit type — `u8` — with its own load/store/extend machinery,
# its own constant-folding, and its own ABI rules. `char` joins as a THIN
# synonym: a `Ty::Char` that reuses every `u8` code path (LDRB/STRB, UXTB,
# 1-byte size/align, zero-extension on load). Because it is `u8` underneath,
# `char` is byte-for-byte ABI-identical to C `unsigned char`, and that is the
# whole point — the C-ABI interop witness below links an Aster `char` function
# into a C `main` and must agree with a pure-C twin.
#
# What `char` is and is not:
#
#   * An unsigned 8-bit integer type. `char c = 300;` is a narrowing error
#     (300 does not fit 0..255); `let c: char = char(300);` is an explicit
#     cast that truncates to 44. `char` widens losslessly to any wider integer,
#     exactly as `u8` does, so `let w: i32 = c;` is allowed.
#
#   * A distinct spelling from the character LITERAL. `'a'` is a `TK::Char`
#     token (a value, folded to `i32`, since v0.23.50-dev); `char` is a
#     `TK::CharType` keyword that names the type. The audit line "char literal
#     already lands, add a Ty::Char" is exactly this split.
#
#   * Usable in every position a `u8` is: local, global, `const`, array
#     element, struct field, parameter, return type, and the cast target
#     `char(x)`. The arithmetic operators see it as an integer (it is in
#     tyIsInteger), so `a + b` on two `char`s is a `char`.
#
# The oracle is gcc: `char` is the model of C `unsigned char`, so every
# behavioural case has a C twin and the two must agree on the exit status under
# qemu. The narrowing REFUSALS are Aster's stricter-than-C discipline — C only
# warns on out-of-range narrowing, so gcc does not reject them; they are pinned
# here as Aster's own rule and checked for their exact message.
#
# Layers (the project 9-layer shape): strict build; source guards pinning every
# piece of the machinery plus the reserved-word list; an independent reader (a
# C program that links Aster's char function, proving the ABI); a gcc
# differential over six cases; a refusal matrix (Aster-only, with exact
# messages); the shipped example against its C twin; coverage counting; six
# mutations; and the byte baseline for the char example.

set -eu
cd "$(dirname "$0")/.."
. tests/lib/baseline.sh
. tests/lib/verdict.sh
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-char-checks}
W="$OUT/work"
mkdir -p "$W"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
run(){ sh "$RUNNER" "$@"; }

# The differential, the independent reader and the behavioural witnesses need a
# cross gcc and a way to run AArch64; without them those layers say SKIP with a
# reason and the rest of the suite still runs.
HOSTCC=${HOSTCC:-}
if [ -z "$HOSTCC" ] && command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    HOSTCC=aarch64-linux-gnu-gcc
fi
if [ -z "$HOSTCC" ] && command -v cc >/dev/null 2>&1; then HOSTCC=cc; fi
have_qemu=yes
command -v qemu-aarch64 >/dev/null 2>&1 || have_qemu=no
case $(uname -m) in aarch64|arm64) have_qemu=yes ;; esac
if [ "$have_qemu" = yes ] && [ -n "$HOSTCC" ]; then
    printf 'int main(void){return 0;}\n' > "$W/probe.c"
    if ! "$HOSTCC" -O2 -fwrapv "$W/probe.c" -o "$W/probe" >/dev/null 2>&1; then
        have_qemu=no
    elif ! run "$W/probe" >/dev/null 2>&1; then
        have_qemu=no
    fi
fi

# ---------------------------------------------------------------------------
# [1/9] Strictly build the Aster compiler
printf '%s\n' '[1/9] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"
A=$OUT/aster

# ---------------------------------------------------------------------------
# [2/9] Source guards. Each piece of the feature is pinned by its text.
printf '%s\n' '[2/9] Source guards: the char machinery'
guard_count=0
guard(){ # $1 = literal source text, $2 = what it is
    grep -qF "$1" src/aster.cpp \
        || { printf 'FAIL: %s is gone\n' "$2" >&2; exit 1; }
    guard_count=$((guard_count + 1))
}
grep -qF '#define ASTER_VERSION_STRING "0.23.69-dev"' src/aster.cpp \
    || { echo "FAIL: the version constant is not 0.23.69-dev" >&2; exit 1; }
guard 'else if(x=="char")k=TK::CharType;' 'the char reserved word'
guard 'enum Kind { I32, U32, U8, U16, I64, U64, Ptr, Bool, Enum, Struct, Char, Void };' 'the Char type'
guard 'case TK::CharType: out=Ty::Char; ++p; return true;' 'char parsed as a type'
guard 'case TK::CharType: t=Ty::Char; break;' 'the char cast'
# tySize and tyAlign both say char is one byte; the count is part of the guard.
guard 'if (t.k == Ty::Char) return 1u;' 'char is one byte (tySize/tyAlign)'
[ "$(grep -c 'if (t.k == Ty::Char) return 1u;' src/aster.cpp)" = 2 ] \
    || { echo 'FAIL: expected two "char is one byte" sites (tySize + tyAlign)' >&2; exit 1; }
guard_count=$((guard_count + 1))
guard 'case Ty::Char: return "char";' 'char names itself'
# initializerFits and caseValueFits both reject out-of-range char; the count is
# part of the guard so a later round cannot quietly drop one.
guard 'case Ty::Char:return folded>=0&&folded<=255;' 'char range check in fit tables'
[ "$(grep -c 'case Ty::Char:return folded>=0&&folded<=255;' src/aster.cpp)" = 2 ] \
    || { echo 'FAIL: expected two "char range" sites (initializerFits + caseValueFits)' >&2; exit 1; }
guard_count=$((guard_count + 1))
guard 'case Ty::Char:return (int64_t)(uint64_t)(uint8_t)(uint64_t)v;' 'char constant truncation'
guard 'case Ty::Char: nm="char";size=1;enc=0x08;break;' 'char DWARF base type'
guard '|| t.k == Ty::Char || t.k == Ty::Enum' 'char is an integer (tyIsInteger)'
guard '|| t.k == Ty::U64 || t.k == Ty::Char;' 'char is unsigned (tyIsUnsigned)'
# The 13 U8/char codegen sites reuse the u8 path; at least ten must remain.
[ "$(grep -c 't==Ty::U8||t==Ty::Char' src/aster.cpp)" -ge 10 ] \
    || { echo 'FAIL: fewer than ten u8/char codegen sites remain' >&2; exit 1; }
guard_count=$((guard_count + 1))
# The reserved-word list is generated, not hand-written: 31 words now that
# `type`, `const`, `void` and `char` joined it, and `tls` is still a context
# keyword.
python3 - <<'PY' || exit 1
import re
src = open('bootstrap/gen_lexer_names.py').read()
m = re.search(r'KEYWORDS = \[(.*?)\]', src, re.S)
entries = re.findall(r'\("([^"]+)",', m.group(1))
assert len(entries) == 31, ('reserved-word count moved', len(entries), entries)
assert 'char' in entries, 'char is not a reserved word'
assert 'tls' not in entries, 'tls became a reserved word — it must stay a context keyword'
print('PASS: 31 reserved words, char among them, tls still a context keyword')
PY
guard_count=$((guard_count + 1))
printf '  %-30s %s\n' "guards passed" "$guard_count"

# ---------------------------------------------------------------------------
# [3/9] An independent reader: a C program links Aster's char function and must
# agree with a C program linking a C char function. This is the feature's whole
# point — char is the model of C unsigned char, so an Aster char function must
# drop into a C translation unit and obey the same AAPCS64 rules, with no shim.
printf '%s\n' '[3/9] Independent reader: C links Aster char fn, must match C linking C'
if [ "$have_qemu" != yes ]; then
    echo 'SKIP: no cross gcc or no qemu — the C-ABI link did not run'
else
cat > "$W/aster_charfn.ast" <<'AST'
fn toUpper(c: char) -> char { return char(c - 32); }
fn ord(c: char) -> i32 { return i32(c); }
AST
"$A" build-obj --pic "$W/aster_charfn.ast" -o "$W/aster_charfn.o" >"$W/aster_charfn.log" 2>&1 \
    || { echo 'FAIL: Aster char function does not build to an object:' >&2; cat "$W/aster_charfn.log" >&2; exit 1; }
cat > "$W/c_caller.c" <<'C'
extern unsigned char toUpper(unsigned char);
extern int ord(unsigned char);
int main(void){
    unsigned char u = toUpper('a');
    int o = ord('q');
    return (u == 'A' && o == 113) ? 0 : 1;
}
C
"$HOSTCC" -c "$W/c_caller.c" -o "$W/c_caller.o" >"$W/c_caller.clog" 2>&1 \
    || { echo 'FAIL: C caller does not compile:' >&2; cat "$W/c_caller.clog" >&2; exit 1; }
"$HOSTCC" "$W/aster_charfn.o" "$W/c_caller.o" -o "$W/hybrid" -static >"$W/hybrid.log" 2>&1 \
    || { echo 'FAIL: C caller cannot link Aster char function (ABI mismatch):' >&2; cat "$W/hybrid.log" >&2; exit 1; }
run "$W/hybrid" >/dev/null 2>&1 && hy=0 || hy=$?
[ "$hy" -gt 127 ] && hy=$((hy - 256))
[ "$hy" = 0 ] || { echo "FAIL: hybrid (C main -> Aster char fn) exited $hy, expected 0" >&2; exit 1; }
printf 'PASS: %-22s C links Aster char fn, exit %s\n' 'c_calls_aster_char' "$hy"
# The mirror: a pure-C program, same behaviour, must also exit 0.
cat > "$W/c_only.c" <<'C'
static unsigned char toUpper(unsigned char c){ return (unsigned char)(c - 32); }
static int ord(unsigned char c){ return (int)c; }
int main(void){
    unsigned char u = toUpper('a');
    int o = ord('q');
    return (u == 'A' && o == 113) ? 0 : 1;
}
C
"$HOSTCC" -O2 -fwrapv "$W/c_only.c" -o "$W/c_only" >/dev/null 2>&1 \
    || { echo 'FAIL: C-only oracle does not compile' >&2; exit 1; }
run "$W/c_only" >/dev/null 2>&1 && cy=0 || cy=$?
[ "$cy" -gt 127 ] && cy=$((cy - 256))
[ "$cy" = 0 ] || { echo "FAIL: C-only oracle exited $cy, expected 0" >&2; exit 1; }
printf 'PASS: %-22s C-only twin, exit %s\n' 'c_only_char' "$cy"
fi

# ---------------------------------------------------------------------------
# [4/9] The gcc differential. `char` is the model of C `unsigned char`, so every
# case has an Aster source and a C source and the two must agree on the exit
# status under qemu — never a hand-computed expectation.
printf '%s\n' '[4/9] gcc differential: Aster and C must agree on char behaviour'
diff_n=0
if [ "$have_qemu" != yes ]; then
    echo 'SKIP: no cross gcc or no qemu — the gcc differential did not run'
else
emit_case(){ # $1 = label
    n="$1"
    printf '%s\n' "$2" > "$W/$n.ast"
    printf '%s\n' "$3" > "$W/$n.c"
}
emit_case char_arith \
'fn main() -> i32 {
    let a: char = '"'"'A'"'"';
    let b: char = '"'"'B'"'"';
    let s: char = a + b;
    if (s == 131) { return 0; }
    return 1;
}' \
'int main(void){
    unsigned char a = '"'"'A'"'"'; unsigned char b = '"'"'B'"'"'; unsigned char s = a + b;
    if (s == 131) return 0;
    return 1;
}'
emit_case char_array \
'fn main() -> i32 {
    let arr: char[4] = 0;
    arr[0] = '"'"'x'"'"';
    arr[1] = '"'"'y'"'"';
    if (arr[0] == 120 && arr[1] == 121) { return 0; }
    return 1;
}' \
'int main(void){
    unsigned char arr[4] = {0};
    arr[0] = '"'"'x'"'"'; arr[1] = '"'"'y'"'"';
    if (arr[0] == 120 && arr[1] == 121) return 0;
    return 1;
}'
emit_case char_struct \
'struct S { c: char, n: i32 }
fn main() -> i32 {
    let s: S = S { '"'"'q'"'"', 7 };
    if (s.c == 113 && s.n == 7) { return 0; }
    return 1;
}' \
'struct S { unsigned char c; int n; };
int main(void){
    struct S s = { '"'"'q'"'"', 7 };
    if (s.c == 113 && s.n == 7) return 0;
    return 1;
}'
emit_case char_widen \
'fn main() -> i32 {
    let c: char = '"'"'m'"'"';
    let w: i32 = c;
    if (w == 109) { return 0; }
    return 1;
}' \
'int main(void){
    unsigned char c = '"'"'m'"'"'; int w = c;
    if (w == 109) return 0;
    return 1;
}'
emit_case char_narrow \
'fn main() -> i32 {
    let c: char = char(300);
    if (c == 44) { return 0; }
    return 1;
}' \
'int main(void){
    unsigned char c = (unsigned char)300;
    if (c == 44) return 0;
    return 1;
}'
emit_case char_param_ret \
'fn toUpper(c: char) -> char { return char(c - 32); }
fn main() -> i32 {
    let r: char = toUpper('"'"'a'"'"');
    if (r == 65) { return 0; }
    return 1;
}' \
'static unsigned char toUpper(unsigned char c){ return (unsigned char)(c - 32); }
int main(void){
    unsigned char r = toUpper('"'"'a'"'"');
    if (r == 65) return 0;
    return 1;
}'

DIFF_CASES='char_arith char_array char_struct char_widen char_narrow char_param_ret'
failed=0
for n in $DIFF_CASES; do
    if ! "$A" build-elf "$W/$n.ast" -o "$W/$n.a64" >"$W/$n.ab.log" 2>&1; then
        echo "FAIL: $n — Aster build failed:" >&2; cat "$W/$n.ab.log" >&2; failed=1; continue
    fi
    if ! "$HOSTCC" -O2 -fwrapv "$W/$n.c" -o "$W/$n.c64" >"$W/$n.cb.log" 2>&1; then
        echo "FAIL: $n — C oracle build failed:" >&2; cat "$W/$n.cb.log" >&2; failed=1; continue
    fi
    run "$W/$n.a64" >/dev/null 2>&1 && a=0 || a=$?
    run "$W/$n.c64" >/dev/null 2>&1 && c=0 || c=$?
    [ "$a" -gt 127 ] && a=$((a - 256))
    [ "$c" -gt 127 ] && c=$((c - 256))
    if [ "$a" != "$c" ]; then
        echo "FAIL: $n — Aster exit $a, C oracle exit $c" >&2; failed=1; continue
    fi
    diff_n=$((diff_n + 1))
    printf 'PASS: %-22s exit %s (matches C)\n' "$n" "$a"
done
[ "$failed" = 0 ] || exit 1
fi

# ---------------------------------------------------------------------------
# [5/9] The refusal matrix. `char` narrows the way C's unsigned char does, but
# Aster refuses silent narrowing at the source rather than warning. C only
# warns on these, so gcc does NOT reject them — they are pinned here as Aster's
# own (stricter) rule, each named by its exact message.
printf '%s\n' '[5/9] Refusal matrix: char will not silently narrow'
reject(){ # $1 = label, $2 = source, $3 = reason
    printf '%s\n' "$2" > "$W/rej.ast"
    if "$A" build-elf "$W/rej.ast" -o "$W/rej" >"$W/rej.log" 2>&1; then
        echo "FAIL: $1 — accepted, expected: $3" >&2; return 1
    fi
    if ! grep -qF "$3" "$W/rej.log"; then
        echo "FAIL: $1 — refused, but not with \"$3\":" >&2; head -2 "$W/rej.log" >&2; return 1
    fi
    printf 'PASS: %-30s %s\n' "$1" "$3"
    return 0
}
failed=0
rej_n=0
r(){ reject "$@" && rej_n=$((rej_n + 1)) || failed=1; }
r 'char: local init 300' \
'let c: char = 300; fn main() -> i32 { return 0; }' \
'does not fit in char'
r 'char: global init 300' \
'let g: char = 300; fn main() -> i32 { return 0; }' \
'does not fit in char'
r 'char: const init 300' \
'const c: char = 300; fn main() -> i32 { return 0; }' \
'does not fit in char'
r 'char: init -1' \
'let c: char = -1; fn main() -> i32 { return 0; }' \
'does not fit in char'
r 'char: init 300+1 (folded)' \
'fn main() -> i32 { let c: char = 300 + 1; return 0; }' \
'does not fit in char'
r 'char: assignment 300' \
'fn main() -> i32 { let c: char = 0; c = 300; return 0; }' \
'does not fit in char'
r 'char: return 300' \
'fn f() -> char { return 300; } fn main() -> i32 { return 0; }' \
'expected char, got i32'
r 'char: struct field 300' \
'struct S { c: char, n: i32 } fn main() -> i32 { let s: S = S { 300, 7 }; return 0; }' \
'expected char, got i32'
r 'char: return i32 param' \
'fn f(x: i32) -> char { return x; } fn main() -> i32 { return 0; }' \
'expected char, got i32'
r 'char: init from i32 var' \
'fn main() -> i32 { let x: i32 = 300; let c: char = x; return 0; }' \
'expected char, got i32'
r 'char: switch case 300' \
'fn main() -> i32 { let c: char = 0; switch (c) { case 300: return 0; } return 1; }' \
'case value does not fit the switch subject type'
[ "$failed" = 0 ] || exit 1
printf '  %-30s %s\n' "refusals held" "$rej_n"

# ---------------------------------------------------------------------------
# [6/9] The shipped example against its C twin.
printf '%s\n' '[6/9] The shipped example against its C twin'
if [ "$have_qemu" != yes ]; then
    echo 'SKIP: no cross gcc or no qemu — the example witness did not run'
else
ex=char_return; twin=tests/char-return-twin.c
if ! "$A" build-elf "examples/$ex.ast" -o "$W/$ex" >"$W/$ex.log" 2>&1; then
    echo "FAIL: examples/$ex.ast no longer builds:" >&2; cat "$W/$ex.log" >&2; exit 1
fi
if ! "$HOSTCC" -O2 -fwrapv "$twin" -o "$W/$ex.c64" >"$W/$ex.c.log" 2>&1; then
    echo "FAIL: $twin no longer builds:" >&2; cat "$W/$ex.c.log" >&2; exit 1
fi
run "$W/$ex" >/dev/null 2>&1 && ae=0 || ae=$?
run "$W/$ex.c64" >/dev/null 2>&1 && ce=0 || ce=$?
[ "$ae" -gt 127 ] && ae=$((ae - 256))
[ "$ce" -gt 127 ] && ce=$((ce - 256))
if [ "$ae" != "$ce" ]; then
    echo "FAIL: examples/$ex.ast exit $ae, $twin exit $ce" >&2; exit 1
fi
printf 'PASS: %-22s exit %s (matches C)\n' "$ex" "$ae"
fi

# ---------------------------------------------------------------------------
# [7/9] Coverage counting: the layers have to be carrying their weight.
printf '%s\n' '[7/9] Coverage: the layers are not vacuous'
[ "$guard_count" -ge 15 ] || { echo "FAIL: only $guard_count source guards, expected at least 15" >&2; exit 1; }
[ "$rej_n" -ge 10 ] || { echo "FAIL: only $rej_n refusals held, expected at least 10" >&2; exit 1; }
printf '  %-30s %s\n' "source guards" "$guard_count"
printf '  %-30s %s\n' "refusals" "$rej_n"
printf '  %-30s %s\n' "gcc differential cases" "$diff_n"

# ---------------------------------------------------------------------------
# [8/9] Mutations. Each piece has to be load-bearing.
printf '%s\n' '[8/9] The suite can still fail (six mutations)'
mutate(){ # $1 = label, $2 = sed script
    sed "$2" src/aster.cpp > "$OUT/$1.cpp"
    if cmp -s src/aster.cpp "$OUT/$1.cpp"; then
        echo "FAIL: mutation $1 did not apply — blind" >&2; exit 1
    fi
    $CXX -std=c++17 -O2 -w "$OUT/$1.cpp" -o "$OUT/$1" 2>/dev/null \
        || { echo "FAIL: mutation $1 no longer compiles" >&2; exit 1; }
}
# (a) A char slot must reject an out-of-range constant. The check rides on
# initializerFits(char), which has two paths: a bare-literal path (line ~873,
# `if(t==Ty::Char)return (uint64_t)e.n<=255u;`) and a folded-expression path
# (the switch case at ~894). Neutralise both so a literal assignment builds —
# proving the refusal is load-bearing.
mutate m1 '/static bool initializerFits/,/static bool caseValueFits/ { s/if(t==Ty::Char)return (uint64_t)e.n<=255u;/if(t==Ty::Char)return true;/; s/case Ty::Char:return folded>=0&&folded<=255;/case Ty::Char:return true;/; }'
printf '%s\n' 'fn main() -> i32 { let c: char = 0; c = 300; return 0; }' > "$W/m1.ast"
# The original refuses `c = 300`; the mutant accepts it, so it builds.
if "$OUT/m1" build-elf "$W/m1.ast" -o "$W/m1" >/dev/null 2>&1; then
    printf '  %-40s %s\n' 'a) char accepts out-of-range' 'noticed'
else
    echo 'FAIL: mutation (a) went unnoticed — the range fit is not what blocks the store' >&2; exit 1
fi
# (b) char is a type — mutate parseType so the CharType keyword is not a type.
mutate m2 's/case TK::CharType: out=Ty::Char; ++p; return true;/case TK::CharType: return false;/'
printf '%s\n' 'fn main() -> i32 { let a: char = 0; return 0; }' > "$W/m2.ast"
# The original builds; the mutant refuses `char` as a type, so it does not build.
if "$OUT/m2" build-elf "$W/m2.ast" -o "$W/m2" >/dev/null 2>&1; then
    echo 'FAIL: mutation (b) went unnoticed — parseType is not what admits char' >&2; exit 1
fi
printf '  %-40s %s\n' 'b) char ceases to be a type' 'noticed'
# (c) char is a cast target — mutate the cast guard so `char(x)` is not
# recognised as a cast at all. The original builds `char(300)` (truncating to
# 44); the mutant rejects the spelling, so it does not build.
mutate m3 's/||cur().k==TK::CharType//'
printf '%s\n' 'fn main() -> i32 { let c: char = char(300); return 0; }' > "$W/m3.ast"
# The original builds; the mutant refuses the char cast, so it does not build.
if "$OUT/m3" build-elf "$W/m3.ast" -o "$W/m3" >/dev/null 2>&1; then
    echo 'FAIL: mutation (c) went unnoticed — the cast site is not what admits char(x)' >&2; exit 1
fi
printf '  %-40s %s\n' 'c) char ceases to be a cast target' 'noticed'
# (d) A char subject's switch case must reject an out-of-range value. The check
# rides on caseValueFits(char) returning false for the case value. Neutralise it
# so a switch over a char with an out-of-range case builds — proving the case
# refusal is load-bearing.
mutate m4 '/static bool caseValueFits/,/^}/ s/case Ty::Char:return folded>=0&&folded<=255;/case Ty::Char:return true;/'
printf '%s\n' 'fn main() -> i32 { let c: char = 0; switch (c) { case 300: return 0; } return 1; }' > "$W/m4.ast"
# The original refuses `return 300;`; the mutant accepts it, so it builds.
if "$OUT/m4" build-elf "$W/m4.ast" -o "$W/m4" >/dev/null 2>&1; then
    printf '  %-40s %s\n' 'd) char fn returns out-of-range' 'noticed'
else
    echo 'FAIL: mutation (d) went unnoticed — caseValueFits is not what blocks the return' >&2; exit 1
fi
# (e) char is an integer for the operators — mutate tyIsInteger so char drops
# out. The original accepts `let a: char = 'A';` (a constant into a char slot);
# the mutant treats char as non-integer so tyAssignable to a char from an i32
# constant now fails, and the witness does not build.
mutate m5 's/|| t.k == Ty::Char //'
printf '%s\n' "fn main() -> i32 { let a: char = 'A'; return 0; }" > "$W/m5.ast"
# The original builds; the mutant refuses the char slot, so it does not build.
if "$OUT/m5" build-elf "$W/m5.ast" -o "$W/m5" >/dev/null 2>&1; then
    echo 'FAIL: mutation (e) went unnoticed — tyIsInteger is not what admits char arithmetic' >&2; exit 1
fi
printf '  %-40s %s\n' 'e) char ceases to be an integer' 'noticed'
# (f) char reuses the u8 codegen path — mutate every `u8 || char` codegen test
# to `u8` alone, so char falls through to the i32 path. The shipped example
# then compiles to DIFFERENT bytes, proving the u8/char sharing is load-bearing
# (without it, char would silently be a four-byte type).
mutate m6 's/t==Ty::U8||t==Ty::Char/t==Ty::U8/g'
"$A" build-elf examples/char_return.ast -o "$W/cr_orig" >/dev/null 2>&1 \
    || { echo 'FAIL: cannot build char example with the shipping compiler' >&2; exit 1; }
o_h=$(sha256sum "$W/cr_orig" | cut -d' ' -f1)
if ! "$OUT/m6" build-elf examples/char_return.ast -o "$W/cr_m6" >/dev/null 2>&1; then
    echo 'FAIL: mutation (f) no longer compiles the char example' >&2; exit 1
fi
m_h=$(sha256sum "$W/cr_m6" | cut -d' ' -f1)
if [ "$o_h" = "$m_h" ]; then
    echo 'FAIL: mutation (f) went unnoticed — char codegen is identical to i32' >&2; exit 1
fi
printf '  %-40s %s\n' 'f) char uses the u8 codegen path' 'noticed'

# ---------------------------------------------------------------------------
# [9/9] The byte baseline for the char example. The full example baseline is
# owned by alias-const-checks.sh; here we pin the three rows that this round
# adds (examples/char_return.ast in three modes) and require them to reproduce.
printf '%s\n' '[9/9] Byte baseline: the char example reproduces'
BASE=$(aster_baseline_file)
case $(uname -m) in aarch64|arm64) have_qemu=yes ;; esac
char_rows=$(grep '^char_return\.' "$BASE" | LC_ALL=C sort)
[ -n "$char_rows" ] || { echo "FAIL: no char_return rows in the frozen baseline" >&2; exit 1; }
printf '%s\n' "$char_rows" > "$W/char.rows.txt"
while IFS= read -r spec; do
    [ -z "$spec" ] && continue
    key=${spec% *}; val=${spec#* }
    mode=${key#*.}; base=${key%.*}
    case "$mode" in
        build-so) m='build-so' ;;
        build-elf) m='build-elf' ;;
        build-obj_--pic) m='build-obj --pic' ;;
    esac
    if "$A" $m "examples/$base.ast" -o "$W/$key" >/dev/null 2>&1; then
        got=$(sha256sum "$W/$key" | cut -d' ' -f1)
    else
        got=FAILED
    fi
    if [ "$got" != "$val" ]; then
        echo "FAIL: $key baseline moved: expected $val, got $got" >&2; exit 1
    fi
done < "$W/char.rows.txt"
printf '  %-30s %s\n' "char_return rows reproduced" "$(echo "$char_rows" | wc -l)"

printf '%s\n' 'PASS: all char checks'
