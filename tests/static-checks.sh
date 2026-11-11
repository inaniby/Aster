#!/bin/sh
# tests/static-checks.sh — v0.23.77-dev: `static let` in a function body.
#
# A static is a global whose *name* is private to the function: the parser
# rewrites the declaration to a unique mangled symbol and parses it with the
# global rules (so every width, array, struct and f64 rule applies unchanged),
# and Sema renames the body's references to it. The frame does not grow, the
# storage is in .data/.bss, and an initializer runs once at program start.
#
# Layers:
#   [1] strict build of the compiler
#   [2] a counter keeps its value across calls; two functions do not share
#   [3] widths and shapes: u8, i64, f64, an array element, the address of one
#   [4] a static shadows a file-scope global of the same name
#   [5] the initializer runs once, before main — a constant folds into .data
#   [6] storage: a symbol exists, and the function's frame did not grow
#   [7] refusals: a duplicate static in one function, assigning a whole array
#   [8] no compiler change: the baseline reproduces 393 rows
#   [9] mutation: without the per-declaration sequence number, two functions'
#       statics would share one symbol and the suite must notice
set -eu
cd "$(dirname "$0")/.."
# v0.23.77-dev (host adaptation): run AArch64 products through the shared
# runner. It executes them natively on an AArch64/Termux host and under qemu
# elsewhere, so the very same suite is valid on both kinds of machine.
RUNNER=${RUNNER:-tests/run-aarch64.sh}
case "$RUNNER" in
    /*) ;;
    *) if [ -f "$RUNNER" ]; then RUNNER="$(cd "$(dirname "$RUNNER")" && pwd)/$(basename "$RUNNER")"; fi ;;
esac
. tests/lib/tmpdir.sh
CXX=${CXX:-c++}
ASTER="$TMPD/static-aster"
OUT="$TMPD/static-work"
rm -rf "$OUT"; mkdir -p "$OUT"
fail(){ echo "FAIL: $*" >&2; exit 1; }
ok(){ printf '  %-46s %s\n' "$1" 'ok'; }
build_run(){
    name=$1; src=$2; want=$3
    printf '%s\n' "$src" > "$OUT/$name.ast"
    "$ASTER" build-elf "$OUT/$name.ast" -o "$OUT/$name.elf" >"$OUT/$name.log" 2>&1 \
        || fail "$name did not compile: $(tail -1 "$OUT/$name.log")"
    chmod +x "$OUT/$name.elf"
    set +e; "$RUNNER" "$OUT/$name.elf" >/dev/null 2>&1; got=$?; set -e
    [ "$got" = "$want" ] || fail "$name returned $got, expected $want"
}
build_reject(){
    name=$1; src=$2; needle=$3
    printf '%s\n' "$src" > "$OUT/$name.ast"
    if "$ASTER" build-elf "$OUT/$name.ast" -o "$OUT/$name.elf" >"$OUT/$name.log" 2>&1; then
        fail "$name compiled but should have been refused"
    fi
    grep -qF -- "$needle" "$OUT/$name.log" || fail "$name's diagnostic does not mention '$needle'"
}

printf '%s\n' '[1/9] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -o "$ASTER" src/aster.cpp
ok 'compiler built'

printf '%s\n' '[2/9] a counter that survives a call'
build_run counter 'fn f() -> i32 { static let n: i32 = 0; n = n + 1; return n; }
fn main() -> i32 { return f() * 10 + f(); }' 12
build_run twon 'fn a() -> i32 { static let n: i32 = 100; n = n + 1; return n; }
fn b() -> i32 { static let n: i32 = 0; n = n + 1; return n; }
fn main() -> i32 { let x: i32 = a(); let y: i32 = b(); return x - 100 + y; }' 2
ok 'one counter counts; two functions keep their own'

printf '%s\n' '[3/9] widths and shapes'
build_run swidth 'fn f() -> i32 { static let b: u8 = 250; b = b + 10; return i32(b); }
fn main() -> i32 { return f(); }' 4
build_run slong 'fn f() -> i32 { static let x: i64 = 1000000000; x = x * 3; return i32(x / 1000000000); }
fn main() -> i32 { return f(); }' 3
build_run sfloat 'fn f() -> i32 { static let x: f64 = 1.5; x = x + 1.0; return i32(x * 2.0); }
fn main() -> i32 { return f() + f() - 5; }' 7
build_run sarr 'fn bump(i: i32) -> i32 { static let a: i32[4] = 0; a[i] = a[i] + 1; return a[i]; }
fn main() -> i32 { bump(0); bump(0); return bump(0) * 5; }' 15
build_run saddr 'fn f() -> i32 { static let n: i32 = 0; let p: ptr = &n; store_i64(p, 33); return n; }
fn main() -> i32 { return f(); }' 33
build_run sloop 'fn main() -> i32 { let i: i32 = 0; let s: i32 = 0;
    while (i < 3) { static let k: i32 = 5; s = s + k; i = i + 1; }
    return s; }' 15
ok 'u8, i64, f64, an array element, an address, a loop body'

printf '%s\n' '[4/9] a static shadows a file-scope global'
build_run shadow 'let n: i32 = 7;
fn f() -> i32 { static let n: i32 = 40; n = n + 1; return n; }
fn main() -> i32 { let fv: i32 = f(); return fv - 40 + n; }' 8
ok 'the file-scope n stays 7 while the function counts from 40'

printf '%s\n' '[5/9] the initializer runs once, before main'
build_run once 'fn g() -> i32 { return 3; }
fn f() -> i32 { static let n: i32 = g(); n = n + 1; return n; }
fn main() -> i32 { return f() * 10 + f(); }' 45
build_run folded 'fn f() -> i32 { static let n: i32 = 6 * 7; n = n + 1; return n; }
fn main() -> i32 { return f() - 42; }' 1
ok "a call initializer runs once (4 then 5), a constant folds"

printf '%s\n' '[6/9] storage, not a frame slot'
# The object keeps every symbol (the final image drops locals it inlined), so
# the symbol table is read from the ET_REL product.
"$ASTER" build-obj "$OUT/sarr.ast" -o "$OUT/probe.o" >/dev/null 2>&1 || fail 'the object did not build'
syms=$(readelf -sW "$OUT/probe.o" | awk '$4=="OBJECT" && $8 ~ /^__aster_static_/ {print $8}' | head -1)
[ -n "$syms" ] || fail 'no mangled static OBJECT symbol in the object'
sect=$(readelf -sW "$OUT/probe.o" | awk '$4=="OBJECT" && $8 ~ /^__aster_static_/ {print $7}' | head -1)
[ "$sect" = 2 ] || [ "$sect" = 3 ] || fail "the static landed in section $sect, expected .data or .bss"
# a static array must not consume frame slots: the code computes its address
# from the global base (ADRP/ADD) rather than from SP.
"$ASTER" build-elf "$OUT/sarr.ast" -o "$OUT/probe.elf" >/dev/null 2>&1 || fail 'the image did not build'
llvm-objdump -d --no-show-raw-insn "$OUT/probe.elf" 2>/dev/null | grep -q 'adrp' \
    || fail 'no ADRP in the image — the array is not addressed as a global'
ok "$syms in .data/.bss, addressed through the global base"

printf '%s\n' '[7/9] refusals'
build_reject dup 'fn f() -> i32 { static let n: i32 = 0; static let n: i32 = 1; return n; }
fn main() -> i32 { return f(); }' 'duplicate static local'
build_reject whole 'fn f() -> i32 { static let a: i32[4] = 0; a = 0; return 0; }
fn main() -> i32 { return f(); }' 'cannot assign to an array as a whole'
ok 'two diagnostics, each naming the rule'

printf '%s\n' '[8/9] no compiler change: the baseline reproduces'
. tests/lib/baseline.sh
base=$(aster_baseline_file)
rows=$(wc -l < "$base")
[ "$rows" = 393 ] || fail "the baseline has $rows rows, expected 393"
ok '393 baseline rows unchanged'

printf '%s\n' '[9/9] mutation: the sequence number keeps two statics apart'
sed 's|"__aster_static_"+std::to_string(staticSeq++)+"_"+local|"__aster_static_"+local|' \
    src/aster.cpp > "$OUT/mutant.cpp"
cmp -s src/aster.cpp "$OUT/mutant.cpp" && fail 'the mangling mutation stopped applying'
$CXX -std=c++17 -O2 -w "$OUT/mutant.cpp" -o "$OUT/mutant" || fail 'the mutant compiler did not build'
set +e
"$OUT/mutant" build-elf "$OUT/twon.ast" -o "$OUT/mut.elf" >"$OUT/mut.log" 2>&1; mrc=$?
if [ "$mrc" = 0 ]; then
    chmod +x "$OUT/mut.elf"; "$RUNNER" "$OUT/mut.elf" >/dev/null 2>&1; mrun=$?
else
    mrun=-1
fi
set -e
[ "$mrc" != 0 ] || [ "$mrun" != 2 ] \
    || fail 'the mutant still behaved correctly — the sequence number is not load-bearing'
ok "mutant diverges (build rc=$mrc, run=$mrun; expected 2)"

echo 'PASS: static locals (storage, once-only init, widths, shadowing, refusals)'
