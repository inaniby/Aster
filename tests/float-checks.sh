#!/bin/sh
# tests/float-checks.sh — v0.23.77-dev: the f64 slice.
#
# Slice 1 is locals, arithmetic, comparisons, conversions and aggregate
# *storage* (a struct field and an array element hold a double). Parameters,
# returns and global initializers arrive with the ABI slice and are refused
# with a diagnostic, which layer [6] pins.
#
# Layers:
#   [1] strict build of the compiler
#   [2] literals, + - * /, precedence, negation
#   [3] comparisons, both as a branch and as a bool value
#   [4] conversions: f64 <-> i32/i64, truncation toward zero, narrowing
#   [5] storage and reassignment: a local, a struct field, an array element
#   [6] what the slice refuses, and the message it refuses with
#   [7] no compiler change: the baseline reproduces 393 rows
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
ASTER="$TMPD/float-aster"
OUT="$TMPD/float-work"
rm -rf "$OUT"; mkdir -p "$OUT"
fail(){ echo "FAIL: $*" >&2; exit 1; }
ok(){ printf '  %-44s %s\n' "$1" 'ok'; }
# build_run <name> <source> <expected exit> [args...]
build_run(){
    name=$1; src=$2; want=$3; shift 3
    printf '%s' "$src" > "$OUT/$name.ast"
    "$ASTER" build-elf "$OUT/$name.ast" -o "$OUT/$name.elf" >"$OUT/$name.log" 2>&1 \
        || fail "$name did not compile: $(tail -1 "$OUT/$name.log")"
    chmod +x "$OUT/$name.elf"
    set +e; "$RUNNER" "$OUT/$name.elf" "$@" >/dev/null 2>&1; got=$?; set -e
    [ "$got" = "$want" ] || fail "$name returned $got, expected $want"
}
build_reject(){
    name=$1; src=$2; needle=$3
    printf '%s' "$src" > "$OUT/$name.ast"
    if "$ASTER" build-elf "$OUT/$name.ast" -o "$OUT/$name.elf" >"$OUT/$name.log" 2>&1; then
        fail "$name compiled but the slice should refuse it"
    fi
    grep -qF "$needle" "$OUT/$name.log" \
        || fail "$name's diagnostic does not mention '$needle': $(tail -1 "$OUT/$name.log")"
}

printf '%s\n' '[1/7] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -o "$ASTER" src/aster.cpp
ok 'compiler built'

printf '%s\n' '[2/9] literals and arithmetic'
build_run f_add 'fn main() -> i32 { let x: f64 = 1.5; let y: f64 = x * 2.0; return i32(y); }' 3
build_run f_prec 'fn main() -> i32 { let x: f64 = 1.0 + 2.0 * 3.0; return i32(x); }' 7
build_run f_sub 'fn main() -> i32 { let x: f64 = 5.0; let y: f64 = 1.5; return i32(x - y); }' 3
build_run f_div 'fn main() -> i32 { let x: f64 = 9.0; let y: f64 = 2.0; return i32(x / y); }' 4
build_run f_div2 'fn main() -> i32 { let x: f64 = 1.0 / 4.0; return i32(x * 100.0); }' 25
build_run f_neg 'fn main() -> i32 { let x: f64 = 1.5; let y: f64 = -x; return i32(y) + 5; }' 4
build_run f_loop 'fn main() -> i32 { let x: f64 = 0.0; let i: i32 = 0; while (i < 4) { x = x + 0.25; i = i + 1; } return i32(x); }' 1
ok 'five operators, precedence, negation, a loop'

printf '%s\n' '[3/9] comparisons'
build_run f_gt 'fn main() -> i32 { let x: f64 = 1.5; if (x > 1.0) { return 42; } return 0; }' 42
build_run f_ge 'fn main() -> i32 { let x: f64 = 2.0; if (x >= 2.0) { return 5; } return 0; }' 5
build_run f_lt 'fn main() -> i32 { let x: f64 = 1.5; if (x < 1.0) { return 1; } return 3; }' 3
build_run f_le 'fn main() -> i32 { let x: f64 = 2.0; if (x <= 1.0) { return 5; } return 0; }' 0
build_run f_eq 'fn main() -> i32 { let x: f64 = 1.5; if (x == 1.5) { return 7; } return 0; }' 7
build_run f_ne 'fn main() -> i32 { let x: f64 = 2.0; if (x != 2.0) { return 5; } return 0; }' 0
build_run f_bool 'fn main() -> i32 { let x: f64 = 1.0; let b: bool = x < 2.0; if (b) { return 9; } return 0; }' 9
ok 'six relations, as a branch and as a bool'

printf '%s\n' '[4/9] conversions'
build_run c_trunc 'fn main() -> i32 { let x: f64 = 2.9; return i32(x); }' 2
build_run c_truncn 'fn main() -> i32 { let x: f64 = -2.9; return 0 - i32(x); }' 2
build_run c_fromi 'fn main() -> i32 { let n: i32 = 7; let x: f64 = f64(n) / 2.0; return i32(x); }' 3
build_run c_from64 'fn main() -> i32 { let n: i64 = 9; let x: f64 = f64(n) / 2.0; return i32(x * 2.0); }' 9
build_run c_narrow 'fn main() -> i32 { let x: f64 = 250.9; let b: u8 = u8(i32(x)); return b; }' 250
build_run c_i64back 'fn main() -> i32 { let x: f64 = 3.99; let n: i64 = i64(x); return i32(n); }' 3
ok 'truncation, i32/i64 sources, u8 narrowing'

printf '%s\n' '[5/9] storage and reassignment'
build_run s_local 'fn main() -> i32 { let x: f64 = 1.0; x = x + 2.0; x = x * 2.0; return i32(x); }' 6
build_run s_field 'struct P { x: f64, y: f64 } fn main() -> i32 { let p: P = P { 1.5, 2.5 }; return i32(p.x + p.y); }' 4
build_run s_array 'fn main() -> i32 { let a: f64[2] = 0; a[0] = 1.5; a[1] = 0.5; return i32(a[0] + a[1]); }' 2
build_run s_array2 'fn main() -> i32 { let a: f64[3] = 0; a[1] = 2.25; return i32(a[1] * 4.0); }' 9
build_run s_global 'let g: f64 = 1.5; fn main() -> i32 { return i32(g * 2.0); }' 3
build_run s_fold 'let g: f64 = 0.1 + 0.2; fn main() -> i32 { return i32(g * 10.0); }' 3
build_run s_garr 'let t: f64[2] = 1.5; fn main() -> i32 { return i32(t[1] * 2.0); }' 3
build_run s_gzero 'let z: f64 = 0.0; fn main() -> i32 { return i32(z) + 5; }' 5
ok 'a local, two struct fields, an array element, three globals'

printf '%s\n' '[6/9] f32 — the four-byte single'
build_run g_arith 'fn main() -> i32 { let x: f32 = f32(1.5); let y: f32 = x * f32(2.0); return i32(y); }' 3
build_run g_div 'fn main() -> i32 { let x: f32 = f32(9.0); let y: f32 = x / f32(2.0); return i32(y); }' 4
build_run g_cmp 'fn main() -> i32 { let x: f32 = f32(1.5); if (x > f32(1.0)) { return 42; } return 0; }' 42
build_run g_neg 'fn main() -> i32 { let x: f32 = f32(-1.5); return i32(x) + 5; }' 4
build_run g_trunc 'fn main() -> i32 { let x: f32 = f32(2.9); return i32(x); }' 2
build_run g_fromint 'fn main() -> i32 { let n: i32 = 7; let x: f32 = f32(n) / f32(2.0); return i32(x); }' 3
build_run g_widen 'fn main() -> i32 { let s: f32 = f32(1.5); let d: f64 = f64(s); return i32(d * 2.0); }' 3
build_run g_narrow 'fn main() -> i32 { let d: f64 = 1.5; let s: f32 = f32(d); return i32(s * f32(2.0)); }' 3
build_run g_param 'fn half(x: f32) -> f32 { return x / f32(2.0); } fn main() -> i32 { return i32(half(f32(9.0))); }' 4
build_run g_mix 'fn f(n: i32, x: f32) -> i32 { return n + i32(x); } fn main() -> i32 { return f(10, f32(2.5)); }' 12
build_run g_global 'let g: f32 = f32(1.5); fn main() -> i32 { return i32(g * f32(2.0)); }' 3
build_run g_array 'fn main() -> i32 { let a: f32[2] = 0; a[0] = f32(1.5); a[1] = f32(0.5); return i32(a[0] + a[1]); }' 2
build_run g_field 'struct P { x: f32, y: f32 } fn main() -> i32 { let p: P = P { f32(1.5), f32(2.5) }; return i32(p.x + p.y); }' 4
ok 'arithmetic, relations, four conversions, parameters, a global and aggregates'

printf '%s\n' '[7/9] the FP calling convention'
build_run a_half 'fn half(x: f64) -> f64 { return x / 2.0; } fn main() -> i32 { return i32(half(9.0)); }' 4
build_run a_two 'fn add(a: f64, b: f64) -> f64 { return a + b; } fn main() -> i32 { return i32(add(1.5, 2.25) * 10.0); }' 37
build_run a_mix1 'fn mix(n: i32, x: f64) -> i32 { return n + i32(x); } fn main() -> i32 { return mix(10, 5.9); }' 15
build_run a_mix2 'fn mix2(x: f64, n: i32) -> f64 { return x * f64(n); } fn main() -> i32 { return i32(mix2(2.5, 4)); }' 10
build_run a_nine 'fn f(a: f64, b: f64, c: f64, d: f64, e: f64, g: f64, h: f64, i: f64, j: f64) -> f64 { return j - a; } fn main() -> i32 { return i32(f(1.0,2.0,3.0,4.0,5.0,6.0,7.0,8.0,9.0)); }' 8
build_run a_branch 'fn f(x: f64) -> f64 { if (x > 2.0) { return 10.0; } return 20.0; } fn main() -> i32 { return i32(f(3.0) + f(1.0)); }' 30
build_run a_nest 'fn f(x: f64) -> f64 { return x * x; } fn main() -> i32 { return i32(f(f(2.0))); }' 16
build_run a_mixedcall 'fn g() -> i32 { return 2; } fn f(x: f64) -> f64 { return x + f64(g()); } fn main() -> i32 { return i32(f(1.5) * 2.0); }' 7
build_run a_three 'fn add3(a: f64, b: f64, c: f64) -> f64 { return a + b + c; } fn main() -> i32 { let r: f64 = add3(0.5, 1.25, 2.25); return i32(r * 4.0); }' 16
ok 'd0-d7 parameters, d0 return, mixed integer/FP calls, nine doubles'

printf '%s\n' '[8/9] what the slice refuses'
build_reject r_mix 'fn main() -> i32 { let x: f64 = 1.5; let n: i32 = 2; return i32(x + n); }' 'needs two operands of the same type'
build_reject r_cmp 'fn main() -> i32 { let x: f64 = 1.5; if (x > 1) { return 2; } return 1; }' 'needs two of the same type'
build_reject r_mod 'fn main() -> i32 { let x: f64 = 1.5; let y: f64 = x % 1.0; return i32(y); }' 'not defined on a floating-point type'
build_reject r_gnconst 'fn f() -> f64 { return 1.5; } let g: f64 = f(); fn main() -> i32 { return i32(g); }' 'f64 global initializer must be a constant expression'
build_reject r_f32mix 'fn main() -> i32 { let s: f32 = f32(1.0); let d: f64 = 1.0; return i32(s + d); }' 'needs two operands of the same type'
build_reject r_f32int 'fn main() -> i32 { let s: f32 = f32(1.0); let n: i32 = 2; return i32(s + n); }' 'needs two operands of the same type'
build_reject r_f32cmp 'fn main() -> i32 { let s: f32 = f32(1.0); if (s == 1.0) { return 1; } return 0; }' 'needs two of the same type'
ok 'seven diagnostics, each naming the rule'

printf '%s\n' '[9/9] no compiler change: the baseline reproduces'
. tests/lib/baseline.sh
base=$(aster_baseline_file)
rows=$(wc -l < "$base")
[ "$rows" = 393 ] || fail "the baseline has $rows rows, expected 393"
ok '393 baseline rows unchanged'

echo 'PASS: f64 and f32 (arithmetic, relations, conversions, storage, the FP calling convention, refusals)'
