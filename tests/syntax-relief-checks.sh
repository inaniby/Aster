#!/bin/sh
# tests/syntax-relief-checks.sh — the grammar's two most-felt gaps, closed.
#
# v0.23.22-dev ships pure syntax relief: `else` is now optional, and integer
# literals may be written in hexadecimal. Neither touches codegen — the parser
# change leaves elseBody empty when `else` is absent (codegen's `block({})`
# emits nothing, and sema's `definitelyReturns` already demands both branches),
# and the lexer change only widens the text unsignedLiteral accepts. That is
# what keeps every pre-existing example byte-identical, and tests/struct-checks.sh
# [4/8] proves it on the full 276-row baseline.
#
# Why these two, and why together: both are places where the language asked the
# programmer to write noise. `else` used to be mandatory, so real code carried
# filler — examples/icon_text_demo.ast has an `} else { }` whose only purpose is
# to satisfy the grammar — and `else { if … }`, the explicit spelling of what
# `else if` desugars to, did not even parse unless the inner `if` also dragged
# an else along. And the lexer only ever accepted decimal digits, so the bit
# patterns this compiler exists to emit (masks, addresses, wide integers) had
# to be written in base 10 or not at all.
#
# The discipline that matters (carried over from narrow-value-coverage.sh and
# write-output-checks.sh): every behavioural case below has an Aster source AND
# an equivalent C source, and the oracle is aarch64-linux-gnu-gcc -O2 -fwrapv
# run under qemu — never a hand-computed expectation. A wrong expectation
# cannot make a case pass.
#
# Layers: strict build; source guards pinning the two parser/lexer shapes and
# the absence of the two old ones; the if/else shape battery (differential);
# the hex-value battery (differential, including the 64-bit path); the
# rejection matrix; and a mutation layer that puts each old restriction back
# and requires the batteries to go red.

set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-syntax-relief-checks}
W="$OUT/work"
mkdir -p "$W"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# [1/7] Strictly build the Aster compiler
printf '%s\n' '[1/7] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"

# ---------------------------------------------------------------------------
# [2/7] Source guards. A regression that reintroduces either old restriction
# must fail here, before a behavioural check has to explain it. Each guard
# pins the new shape; two more assert the old shapes are gone for good.
printf '%s\n' '[2/7] Source guards: optional else, hexadecimal literals'
grep -qF 'if(eat(TK::Else)){' src/aster.cpp \
    || { echo 'FAIL: the if statement no longer treats else as optional' >&2; exit 1; }
if grep -qF 'need(TK::Else,"expected else branch")' src/aster.cpp; then
    echo 'FAIL: the mandatory-else diagnostic is back — else must be optional' >&2; exit 1
fi
grep -qF "if(x==\"0\"&&(peek()=='x'||peek()=='X')){" src/aster.cpp \
    || { echo 'FAIL: the lexer no longer recognises the 0x/0X prefix' >&2; exit 1; }
grep -qF 'hexadecimal literal has no digits at ' src/aster.cpp \
    || { echo 'FAIL: the bare-0x diagnostic is missing' >&2; exit 1; }
grep -qF 'const bool hex=tok.s.size()>1&&tok.s[0]=='\''0'\''&&(tok.s[1]=='\''x'\''||tok.s[1]=='\''X'\'');' src/aster.cpp \
    || { echo 'FAIL: unsignedLiteral no longer detects the hexadecimal prefix' >&2; exit 1; }
grep -qF 'hex?16:10' src/aster.cpp \
    || { echo 'FAIL: unsignedLiteral no longer selects base 16 for hex' >&2; exit 1; }
if grep -qF 'std::stoull(tok.s,&used,10)' src/aster.cpp; then
    echo 'FAIL: unsignedLiteral is back to a hardcoded base 10' >&2; exit 1
fi
echo 'OK: guards hold — else optional, hex lexed and parsed, both old shapes absent'

# ---------------------------------------------------------------------------
# [3/7] Locate the tools: an AArch64 C compiler (the independent oracle) and
# something to run AArch64 ELFs with. The batteries compare against gcc, so
# without both they SKIP cleanly; the guards above already ran.
printf '%s\n' '[3/7] Locate an AArch64 C compiler and a runner'
HOSTCC=${HOSTCC:-}
if [ -z "$HOSTCC" ] && command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    HOSTCC=aarch64-linux-gnu-gcc
fi
if [ -z "$HOSTCC" ]; then
    echo "SKIP: syntax-relief coverage needs an AArch64 C compiler (none found)"
    exit 0
fi
printf 'int main(){return 0;}\n' > "$W/hostprobe.c"
if ! "$HOSTCC" -O2 -fwrapv "$W/hostprobe.c" -o "$W/hostprobe" 2>/dev/null \
   || ! readelf -h "$W/hostprobe" 2>/dev/null | grep -q 'AArch64'; then
    echo "SKIP: $HOSTCC does not emit AArch64 ELF (cross-compile toolchain missing)"
    exit 0
fi
if ! command -v qemu-aarch64 >/dev/null 2>&1 && [ "$(uname -m)" != "aarch64" ]; then
    echo "SKIP: syntax-relief coverage needs qemu-aarch64 (or an AArch64 host)"
    exit 0
fi
run(){ sh tests/run-aarch64.sh "$@"; }

# ---------------------------------------------------------------------------
# [4/7] if/else shape battery. Every shape that used to be a compile error
# (or ugly filler) now parses, and every one is checked against the C twin of
# the same shape — gcc computes the expected exit status, nobody writes a
# number down.
#
# The battery is deliberately shape-complete:
#   no else at all (condition true and false),
#   else-if chains with and without a tail else,
#   the explicit `else { if … }` spelling (the form the user called out), alone
#       and nested two deep,
#   the `} else { }` filler the icon demo still carries (legal, unchanged),
#   if-without-else nested inside a then branch, inside a while, inside a for,
#   the early-return guard (`if (bad) { return …; } return …;`), and
#   the both-branches-return form that sema's definitelyReturns accepts with
#       no trailing return.
printf '%s\n' '[4/7] if/else shapes: every form, against the C oracle'
SHAPE_CASES="plain_no_else plain_no_else_false else_if_no_tail else_if_no_tail_false \
else_if_tail else_block_if else_block_if_chain empty_else nested_if_in_then \
while_if_no_else for_if_no_else early_return_guard both_branches_return"

emit_shape(){
    n="$1"
    case "$n" in
    plain_no_else)
        ast='fn main() -> i32 {
    let x: i32 = 1;
    if (x == 1) {
        x = 2;
    }
    return x;
}'
        c='int main(void){ int x=1; if(x==1){ x=2; } return x; }' ;;
    plain_no_else_false)
        ast='fn main() -> i32 {
    let x: i32 = 1;
    if (x == 9) {
        x = 2;
    }
    return x;
}'
        c='int main(void){ int x=1; if(x==9){ x=2; } return x; }' ;;
    else_if_no_tail)
        ast='fn main() -> i32 {
    let x: i32 = 1;
    if (x == 0) {
        x = 10;
    } else if (x == 1) {
        x = 20;
    }
    return x;
}'
        c='int main(void){ int x=1; if(x==0){ x=10; } else if(x==1){ x=20; } return x; }' ;;
    else_if_no_tail_false)
        ast='fn main() -> i32 {
    let x: i32 = 5;
    if (x == 0) {
        x = 10;
    } else if (x == 1) {
        x = 20;
    }
    return x;
}'
        c='int main(void){ int x=5; if(x==0){ x=10; } else if(x==1){ x=20; } return x; }' ;;
    else_if_tail)
        ast='fn main() -> i32 {
    let x: i32 = 5;
    if (x == 0) {
        x = 10;
    } else if (x == 1) {
        x = 20;
    } else {
        x = 30;
    }
    return x;
}'
        c='int main(void){ int x=5; if(x==0){ x=10; } else if(x==1){ x=20; } else { x=30; } return x; }' ;;
    else_block_if)
        # The explicit spelling of what `else if` desugars to. It used to be a
        # compile error whenever the inner if had no else of its own.
        ast='fn main() -> i32 {
    let x: i32 = 1;
    if (x == 0) {
        x = 10;
    } else {
        if (x == 1) {
            x = 20;
        }
    }
    return x;
}'
        c='int main(void){ int x=1; if(x==0){ x=10; } else { if(x==1){ x=20; } } return x; }' ;;
    else_block_if_chain)
        ast='fn main() -> i32 {
    let x: i32 = 7;
    if (x == 0) {
        x = 10;
    } else {
        if (x == 1) {
            x = 20;
        } else {
            if (x == 7) {
                x = 42;
            }
        }
    }
    return x;
}'
        c='int main(void){ int x=7; if(x==0){ x=10; } else { if(x==1){ x=20; } else { if(x==7){ x=42; } } } return x; }' ;;
    empty_else)
        # The filler block examples/icon_text_demo.ast carries: still legal,
        # still emitting nothing.
        ast='fn main() -> i32 {
    let x: i32 = 1;
    if (x == 1) {
        x = 5;
    } else {
    }
    return x;
}'
        c='int main(void){ int x=1; if(x==1){ x=5; } else {} return x; }' ;;
    nested_if_in_then)
        ast='fn main() -> i32 {
    let x: i32 = 3;
    if (x > 0) {
        if (x == 3) {
            x = 7;
        }
    }
    return x;
}'
        c='int main(void){ int x=3; if(x>0){ if(x==3){ x=7; } } return x; }' ;;
    while_if_no_else)
        ast='fn main() -> i32 {
    let i: i32 = 0;
    let s: i32 = 0;
    while (i < 5) {
        if (i % 2 == 0) {
            s = s + i;
        }
        i = i + 1;
    }
    return s;
}'
        c='int main(void){ int i=0,s=0; while(i<5){ if(i%2==0){ s=s+i; } i=i+1; } return s; }' ;;
    for_if_no_else)
        ast='fn main() -> i32 {
    let s: i32 = 0;
    for (let i: i32 = 0; i < 4; i = i + 1) {
        if (i != 2) {
            s = s + i;
        }
    }
    return s;
}'
        c='int main(void){ int s=0; for(int i=0;i<4;i=i+1){ if(i!=2){ s=s+i; } } return s; }' ;;
    early_return_guard)
        ast='fn main() -> i32 {
    let x: i32 = 0;
    if (x < 0) {
        return 1;
    }
    return 0;
}'
        c='int main(void){ int x=0; if(x<0){ return 1; } return 0; }' ;;
    both_branches_return)
        # Both branches return, so the function needs no trailing return —
        # sema's definitelyReturns path, unchanged by optional else.
        ast='fn main() -> i32 {
    let x: i32 = 1;
    if (x == 1) {
        return 11;
    } else {
        return 22;
    }
}'
        c='int main(void){ int x=1; if(x==1){ return 11; } else { return 22; } }' ;;
    esac
    printf '%s\n' "$ast" > "$W/$n.ast"
    printf '%s\n' "$c" > "$W/$n.c"
}

check_shape(){
    n="$1"
    if ! "$OUT/aster" build-elf "$W/$n.ast" -o "$W/$n.a64" >/dev/null 2>&1; then
        echo "FAIL: $n — Aster rejected a shape that must parse" >&2; return 1
    fi
    "$HOSTCC" -O2 -fwrapv "$W/$n.c" -o "$W/$n.c64" 2>/dev/null
    run "$W/$n.a64" >/dev/null 2>&1 && a=0 || a=$?
    run "$W/$n.c64" >/dev/null 2>&1 && c=0 || c=$?
    [ "$a" -gt 127 ] && a=$((a-256))
    [ "$c" -gt 127 ] && c=$((c-256))
    if [ "$a" != "$c" ]; then
        echo "FAIL: $n — Aster exit $a, C oracle exit $c" >&2; return 1
    fi
    printf 'PASS: %-24s exit %s (matches C)\n' "$n" "$a"
}

for n in $SHAPE_CASES; do emit_shape "$n"; done
failed=0
for n in $SHAPE_CASES; do check_shape "$n" || failed=1; done
[ "$failed" = 0 ] || exit 1

# ---------------------------------------------------------------------------
# [5/7] Hexadecimal battery. The value of each literal is observed through an
# expression whose result the C oracle computes, so a mis-lexed digit (a
# dropped nibble, a wrong base) fails a case. The wide cases ride the 64-bit
# path v0.23.18-dev built: a literal whose value exceeds i32 makes the
# operation 64-bit, and the i64 result is narrowed on return — both pinned
# here against gcc, both previously untestable because the lexer refused hex.
#
# A comparison against the same literal would prove nothing (garbage would
# compare equal to itself); every observable is arithmetic.
printf '%s\n' '[5/7] Hex literals: every width, against the C oracle'
HEX_CASES="hex_zero hex_small hex_upper hex_neg hex_arith hex_mask hex_i32_max \
hex_i32_edge hex_i64_big hex_i64_max hex_arrlen hex_upper_arrlen hex_call_arg hex_shift"

emit_hex(){
    n="$1"
    case "$n" in
    hex_zero)
        ast='fn main() -> i32 {
    let x: i32 = 0x0;
    return x % 251;
}'
        c='int main(void){ int x=0x0; return x%251; }' ;;
    hex_small)
        ast='fn main() -> i32 {
    let x: i32 = 0x10;
    return x % 251;
}'
        c='int main(void){ int x=0x10; return x%251; }' ;;
    hex_upper)
        ast='fn main() -> i32 {
    let x: i32 = 0XABCD;
    return x % 251;
}'
        c='int main(void){ int x=0XABCD; return x%251; }' ;;
    hex_neg)
        ast='fn main() -> i32 {
    let x: i32 = -0x10;
    return (x + 32) % 251;
}'
        c='int main(void){ int x=-0x10; return (x+32)%251; }' ;;
    hex_arith)
        ast='fn main() -> i32 {
    let x: i32 = 0x10 + 0x20;
    return x % 251;
}'
        c='int main(void){ int x=0x10+0x20; return x%251; }' ;;
    hex_mask)
        ast='fn main() -> i32 {
    let mask: i32 = 0xF0;
    let v: i32 = 0xAB & mask;
    return v % 251;
}'
        c='int main(void){ int mask=0xF0; int v=0xAB&mask; return v%251; }' ;;
    hex_i32_max)
        ast='fn main() -> i32 {
    let x: i32 = 0x7FFFFFFF;
    return x % 251;
}'
        c='int main(void){ int x=0x7FFFFFFF; return x%251; }' ;;
    hex_i32_edge)
        # 0x80000000 does not fit i32; it truncates to the INT_MIN bit pattern
        # exactly as the decimal 2147483648 always did — hex changes the
        # spelling, not the rule, and the C twin is the witness.
        ast='fn main() -> i32 {
    let x: i32 = 0x80000000;
    return x % 251;
}'
        c='int main(void){ int x=0x80000000; return x%251; }' ;;
    hex_i64_big)
        ast='fn main() -> i32 {
    let x: i64 = 0x0102030405060708;
    return x % 251;
}'
        c='int main(void){ long long x=0x0102030405060708LL; return (int)(x%251); }' ;;
    hex_i64_max)
        ast='fn main() -> i32 {
    let x: i64 = 0x7FFFFFFFFFFFFFFF;
    return x % 251;
}'
        c='int main(void){ long long x=0x7FFFFFFFFFFFFFFFLL; return (int)(x%251); }' ;;
    hex_arrlen)
        # A hex array length: if 0x4 lexed as anything but 4, the constant-index
        # bounds check on a[3] would reject the program.
        ast='let a: i32[0x4] = 0;
fn main() -> i32 {
    a[3] = 77;
    return a[3];
}'
        c='int a[0x4];
int main(void){ a[3]=77; return a[3]; }' ;;
    hex_upper_arrlen)
        ast='let a: i32[0X2] = 0;
fn main() -> i32 {
    a[1] = 33;
    return a[1];
}'
        c='int a[0X2];
int main(void){ a[1]=33; return a[1]; }' ;;
    hex_call_arg)
        ast='fn f(v: i32) -> i32 {
    return v % 251;
}
fn main() -> i32 {
    return f(0x1F4);
}'
        c='static int f(int v){ return v%251; }
int main(void){ return f(0x1F4); }' ;;
    hex_shift)
        ast='fn main() -> i32 {
    let x: i32 = 1 << 0x4;
    return x;
}'
        c='int main(void){ int x=1<<0x4; return x; }' ;;
    esac
    printf '%s\n' "$ast" > "$W/$n.ast"
    printf '%s\n' "$c" > "$W/$n.c"
}

check_hex(){
    n="$1"
    if ! "$OUT/aster" build-elf "$W/$n.ast" -o "$W/$n.a64" >/dev/null 2>&1; then
        echo "FAIL: $n — Aster rejected a valid hex program" >&2; return 1
    fi
    "$HOSTCC" -O2 -fwrapv "$W/$n.c" -o "$W/$n.c64" 2>/dev/null
    run "$W/$n.a64" >/dev/null 2>&1 && a=0 || a=$?
    run "$W/$n.c64" >/dev/null 2>&1 && c=0 || c=$?
    [ "$a" -gt 127 ] && a=$((a-256))
    [ "$c" -gt 127 ] && c=$((c-256))
    if [ "$a" != "$c" ]; then
        echo "FAIL: $n — Aster exit $a, C oracle exit $c" >&2; return 1
    fi
    printf 'PASS: %-24s exit %s (matches C)\n' "$n" "$a"
}

for n in $HEX_CASES; do emit_hex "$n"; done
failed=0
for n in $HEX_CASES; do check_hex "$n" || failed=1; done
[ "$failed" = 0 ] || exit 1

# ---------------------------------------------------------------------------
# [6/7] Rejection matrix. Optional else does not make `if` a get-out-of-return
# free card: a then-branch that returns no longer proves the function returns,
# and the diagnostic still names the fix. Hex has its own rejects — a bare
# prefix, a value past i64 — and adjacency (`0x1G`) stays a parse error.
printf '%s\n' '[6/7] Rejections: the contracts still bite'
reject(){ # reject <name> <file> <expected message fragment>
    if "$OUT/aster" build-elf "$W/$2" -o "$W/$2.a64" >/dev/null 2>&1; then
        echo "FAIL: $1 — a program that must be rejected was accepted" >&2; return 1
    fi
    msg=$("$OUT/aster" build-elf "$W/$2" -o "$W/$2.a64" 2>&1 | head -1 || true)
    case "$msg" in
        *"$3"*) printf 'PASS: rejected — %s\n' "$1" ;;
        *) echo "FAIL: $1 — rejected, but with the wrong diagnostic: $msg" >&2; return 1 ;;
    esac
}
cat > "$W/rej_bare_hex.ast" <<'AST'
fn main() -> i32 {
    let x: i32 = 0x;
    return x;
}
AST
reject 'a bare 0x prefix' rej_bare_hex.ast 'hexadecimal literal has no digits at 2:18'
cat > "$W/rej_hex_overflow.ast" <<'AST'
fn main() -> i32 {
    let x: i64 = 0xFFFFFFFFFFFFFFFF;
    return 0;
}
AST
# v0.23.48-dev: 0xFFFFFFFFFFFFFFFF is a legal u64 literal now, so the parser
# takes it and the i64 slot rejects it — the diagnostic names the slot and the
# folded (-1) view, at the let statement rather than the literal token.
reject 'a hex value past i64' rej_hex_overflow.ast 'local initializer does not fit in i64: x (-1) at 2:9'
cat > "$W/rej_fallthrough.ast" <<'AST'
fn main() -> i32 {
    let x: i32 = 1;
    if (x == 1) {
        return 1;
    }
}
AST
reject 'a then-only return with no way out' rej_fallthrough.ast 'may fall through without returning i32'
cat > "$W/rej_adjacency.ast" <<'AST'
fn main() -> i32 {
    let x: i32 = 0x1G;
    return x;
}
AST
reject 'a hex digit run glued to an identifier' rej_adjacency.ast "expected ';' at 2:21"
cat > "$W/rej_bare_hex_arrlen.ast" <<'AST'
let a: i32[0x] = 0;
fn main() -> i32 {
    return a[0];
}
AST
reject 'a bare 0x as an array length' rej_bare_hex_arrlen.ast 'hexadecimal literal has no digits at 1:12'

# ---------------------------------------------------------------------------
# [7/7] Mutation layer. Put each old restriction back and require the
# batteries above to go red — a check that passes on a damaged compiler is not
# checking anything. Both mutations are exact reversions to v0.23.21-dev
# behaviour: the mandatory `else`, and the decimal-only lexer.
printf '%s\n' '[7/7] Mutation: the checks above must fail on a damaged compiler'
if ! sed 's/if(eat(TK::Else)){/need(TK::Else,"expected else branch");if(1){/' \
        src/aster.cpp > "$OUT/m1.cpp"; then
    echo 'FAIL: mutation 1 sed failed' >&2; exit 1
fi
if cmp -s src/aster.cpp "$OUT/m1.cpp"; then
    echo 'FAIL: mutation 1 did not change the source (the guard is stale)' >&2; exit 1
fi
if ! ${CXX:-c++} -std=c++17 -O0 -w "$OUT/m1.cpp" -o "$OUT/m1.aster" 2>"$OUT/m1.err"; then
    echo 'FAIL: mutant 1 does not build' >&2; sed -n '1,3p' "$OUT/m1.err" >&2; exit 1
fi
if "$OUT/m1.aster" build-elf "$W/plain_no_else.ast" -o "$OUT/m1.a64" >/dev/null 2>&1; then
    echo 'FAIL: with else mandatory again, a plain if still compiled — the shape battery does not test it' >&2; exit 1
fi
printf '  %-40s the plain if is rejected again\n' 'else re-mandated (v0.23.21-dev)'
if ! sed "s/if(x==\"0\"&&(peek()=='x'||peek()=='X')){/if(false){/" \
        src/aster.cpp > "$OUT/m2.cpp"; then
    echo 'FAIL: mutation 2 sed failed' >&2; exit 1
fi
if cmp -s src/aster.cpp "$OUT/m2.cpp"; then
    echo 'FAIL: mutation 2 did not change the source (the guard is stale)' >&2; exit 1
fi
if ! ${CXX:-c++} -std=c++17 -O0 -w "$OUT/m2.cpp" -o "$OUT/m2.aster" 2>"$OUT/m2.err"; then
    echo 'FAIL: mutant 2 does not build' >&2; sed -n '1,3p' "$OUT/m2.err" >&2; exit 1
fi
if "$OUT/m2.aster" build-elf "$W/hex_small.ast" -o "$OUT/m2.a64" >/dev/null 2>&1; then
    echo 'FAIL: with the hex branch disabled, 0x10 still compiled — the hex battery does not test it' >&2; exit 1
fi
printf '  %-40s 0x10 is a parse error again\n' 'hex branch disabled (v0.23.21-dev)'

printf '%s\n' 'ALL SYNTAX-RELIEF CHECKS PASSED'
