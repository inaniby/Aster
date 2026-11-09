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
    set +e; "$OUT/$name.elf" "$@" >/dev/null 2>&1; got=$?; set -e
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

printf '%s\n' '[2/7] literals and arithmetic'
build_run f_add 'fn main() -> i32 { let x: f64 = 1.5; let y: f64 = x * 2.0; return i32(y); }' 3
build_run f_prec 'fn main() -> i32 { let x: f64 = 1.0 + 2.0 * 3.0; return i32(x); }' 7
build_run f_sub 'fn main() -> i32 { let x: f64 = 5.0; let y: f64 = 1.5; return i32(x - y); }' 3
build_run f_div 'fn main() -> i32 { let x: f64 = 9.0; let y: f64 = 2.0; return i32(x / y); }' 4
build_run f_div2 'fn main() -> i32 { let x: f64 = 1.0 / 4.0; return i32(x * 100.0); }' 25
build_run f_neg 'fn main() -> i32 { let x: f64 = 1.5; let y: f64 = -x; return i32(y) + 5; }' 4
build_run f_loop 'fn main() -> i32 { let x: f64 = 0.0; let i: i32 = 0; while (i < 4) { x = x + 0.25; i = i + 1; } return i32(x); }' 1
ok 'five operators, precedence, negation, a loop'

printf '%s\n' '[3/7] comparisons'
build_run f_gt 'fn main() -> i32 { let x: f64 = 1.5; if (x > 1.0) { return 42; } return 0; }' 42
build_run f_ge 'fn main() -> i32 { let x: f64 = 2.0; if (x >= 2.0) { return 5; } return 0; }' 5
build_run f_lt 'fn main() -> i32 { let x: f64 = 1.5; if (x < 1.0) { return 1; } return 3; }' 3
build_run f_le 'fn main() -> i32 { let x: f64 = 2.0; if (x <= 1.0) { return 5; } return 0; }' 0
build_run f_eq 'fn main() -> i32 { let x: f64 = 1.5; if (x == 1.5) { return 7; } return 0; }' 7
build_run f_ne 'fn main() -> i32 { let x: f64 = 2.0; if (x != 2.0) { return 5; } return 0; }' 0
build_run f_bool 'fn main() -> i32 { let x: f64 = 1.0; let b: bool = x < 2.0; if (b) { return 9; } return 0; }' 9
ok 'six relations, as a branch and as a bool'

printf '%s\n' '[4/7] conversions'
build_run c_trunc 'fn main() -> i32 { let x: f64 = 2.9; return i32(x); }' 2
build_run c_truncn 'fn main() -> i32 { let x: f64 = -2.9; return 0 - i32(x); }' 2
build_run c_fromi 'fn main() -> i32 { let n: i32 = 7; let x: f64 = f64(n) / 2.0; return i32(x); }' 3
build_run c_from64 'fn main() -> i32 { let n: i64 = 9; let x: f64 = f64(n) / 2.0; return i32(x * 2.0); }' 9
build_run c_narrow 'fn main() -> i32 { let x: f64 = 250.9; let b: u8 = u8(i32(x)); return b; }' 250
build_run c_i64back 'fn main() -> i32 { let x: f64 = 3.99; let n: i64 = i64(x); return i32(n); }' 3
ok 'truncation, i32/i64 sources, u8 narrowing'

printf '%s\n' '[5/7] storage and reassignment'
build_run s_local 'fn main() -> i32 { let x: f64 = 1.0; x = x + 2.0; x = x * 2.0; return i32(x); }' 6
build_run s_field 'struct P { x: f64, y: f64 } fn main() -> i32 { let p: P = P { 1.5, 2.5 }; return i32(p.x + p.y); }' 4
build_run s_array 'fn main() -> i32 { let a: f64[2] = 0; a[0] = 1.5; a[1] = 0.5; return i32(a[0] + a[1]); }' 2
build_run s_array2 'fn main() -> i32 { let a: f64[3] = 0; a[1] = 2.25; return i32(a[1] * 4.0); }' 9
ok 'a local, two struct fields, an array element'

printf '%s\n' '[6/7] what the slice refuses'
build_reject r_mix 'fn main() -> i32 { let x: f64 = 1.5; let n: i32 = 2; return i32(x + n); }' 'f64 arithmetic needs two f64'
build_reject r_cmp 'fn main() -> i32 { let x: f64 = 1.5; if (x > 1) { return 2; } return 1; }' 'comparing f64 with an integer'
build_reject r_mod 'fn main() -> i32 { let x: f64 = 1.5; let y: f64 = x % 1.0; return i32(y); }' 'not defined on f64'
build_reject r_param 'fn h(x: f64) -> i32 { return i32(x); } fn main() -> i32 { return h(1.5); }' 'f64 parameters arrive with the ABI slice'
build_reject r_ret 'fn g() -> f64 { return 1.5; } fn main() -> i32 { return 1; }' 'an f64 return arrives'
build_reject r_global 'let g: f64 = 1.5; fn main() -> i32 { return i32(g); }' 'an f64 global arrives with the ABI slice'
ok 'six diagnostics, each naming the slice'

printf '%s\n' '[7/7] no compiler change: the baseline reproduces'
. tests/lib/baseline.sh
base=$(aster_baseline_file)
rows=$(wc -l < "$base")
[ "$rows" = 393 ] || fail "the baseline has $rows rows, expected 393"
ok '393 baseline rows unchanged'

echo 'PASS: f64 slice 1 (arithmetic, relations, conversions, storage, refusals)'
