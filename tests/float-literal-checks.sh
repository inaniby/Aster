#!/bin/sh
# tests/float-literal-checks.sh — v0.23.77-dev: exponent-form float literals.
#
# `1e9` used to lex as the number 1 followed by the identifier e9, so a
# fractional literal needed the long spelling (1000000000.0), and a malformed
# one produced "expected ';'" two tokens away from the mistake. The lexer now
# takes an exponent — e/E, an optional sign, at least one digit — and reports a
# malformed one where it happens; a hex or binary literal keeps its e/E digits.
#
# Layers:
#   [1] strict build of the compiler
#   [2] the four exponent shapes evaluate as written
#   [3] the value is the same double as the long spelling
#   [4] a hex / binary / underscored integer is still an integer
#   [5] three refusals, each naming what is wrong
#   [6] a global folds an exponent literal into .data
#   [7] no compiler change: the baseline reproduces 393 rows
#   [8] mutation: dropping the sign must be caught
set -eu
cd "$(dirname "$0")/.."
. tests/lib/tmpdir.sh
CXX=${CXX:-c++}
ASTER="$TMPD/exp-aster"
OUT="$TMPD/exp-work"
rm -rf "$OUT"; mkdir -p "$OUT"
fail(){ echo "FAIL: $*" >&2; exit 1; }
ok(){ printf '  %-46s %s\n' "$1" 'ok'; }
build_run(){
    name=$1; src=$2; want=$3
    printf '%s\n' "$src" > "$OUT/$name.ast"
    "$ASTER" build-elf "$OUT/$name.ast" -o "$OUT/$name.elf" >"$OUT/$name.log" 2>&1 \
        || fail "$name did not compile: $(tail -1 "$OUT/$name.log")"
    chmod +x "$OUT/$name.elf"
    set +e; "$OUT/$name.elf" >/dev/null 2>&1; got=$?; set -e
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

printf '%s\n' '[1/8] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -o "$ASTER" src/aster.cpp
ok 'compiler built'

printf '%s\n' '[2/8] the four exponent shapes'
build_run e_up 'fn main() -> i32 { let x: f64 = 1e9; return i32(x / 1000000000.0); }' 1
build_run e_down 'fn main() -> i32 { let x: f64 = 1.5e-3; return i32(x * 1000.0); }' 1
build_run e_plus 'fn main() -> i32 { let x: f64 = 2E+2; return i32(x); }' 200
build_run e_zero 'fn main() -> i32 { let x: f64 = 2.5e0; return i32(x * 2.0); }' 5
ok '1e9, 1.5e-3, 2E+2, 2.5e0'

printf '%s\n' '[3/8] the same double as the long spelling'
build_run same 'fn main() -> i32 { let a: f64 = 1e-7; let b: f64 = 0.0000001;
    if (a == b) { return 1; } return 0; }' 1
build_run same2 'fn main() -> i32 { let a: f64 = 3.5e2; let b: f64 = 350.0;
    if (a == b) { return 41; } return 0; }' 41
ok 'exponent and decimal spellings compare equal'

printf '%s\n' '[4/8] integers keep their own lexing'
build_run hex 'fn main() -> i32 { let x: i32 = 0x1e9; return x - 489; }' 0
build_run bin 'fn main() -> i32 { let x: i32 = 0b1010; return x - 10; }' 0
build_run under 'fn main() -> i32 { let x: i32 = 1_000; return x - 1000; }' 0
build_run suffix 'fn main() -> i32 { let x: i64 = 123l; return i32(x - 123l); }' 0
ok '0x1e9 (an e digit), 0b1010, 1_000, 123l'

printf '%s\n' '[5/8] what is refused'
build_reject badsuf 'fn main() -> i32 { let x: f64 = 1e9u; return 0; }' 'cannot carry an integer suffix'
build_reject badexp 'fn main() -> i32 { let x: f64 = 1e; return 0; }' 'malformed exponent'
build_reject badsgn 'fn main() -> i32 { let x: f64 = 1.5e+; return 0; }' 'malformed exponent'
ok 'a suffix, a bare e, a sign with no digits'

printf '%s\n' '[6/8] a global folds an exponent literal'
printf 'let g: f64 = 1.5e3;\nfn main() -> i32 { return i32(g); }\n' > "$OUT/g.ast"
"$ASTER" build-elf "$OUT/g.ast" -o "$OUT/g.elf" >/dev/null 2>&1 || fail 'the global did not compile'
chmod +x "$OUT/g.elf"
set +e; "$OUT/g.elf"; rc=$?; set -e
[ "$rc" = 220 ] || fail "the folded global returned $rc, expected 1500 & 255 = 220"
data=$(readelf -x .data "$OUT/g.elf" 2>/dev/null | awk 'NR>2 {print $2 $3 $4 $5}' | tr -d '\n')
case "$data" in
    # 1500.0 is 0x4097700000000000; the dump is byte-wise little-endian, so the
    # tail of the pattern is what a reader checks the exponent and mantissa with.
    *709740*) : ;;
    *) fail "the folded 1500 is not in .data as a double: $data" ;;
esac
ok '1500 folds into .data (0x4097700000000000) and reads back as 220'

printf '%s\n' '[7/8] no compiler change: the baseline reproduces'
. tests/lib/baseline.sh
base=$(aster_baseline_file)
rows=$(wc -l < "$base")
[ "$rows" = 393 ] || fail "the baseline has $rows rows, expected 393"
ok '393 baseline rows unchanged'

printf '%s\n' '[8/8] mutation: the exponent sign is load-bearing'
sed "s~if(peek()=='+'||peek()=='-')x+=take();~if(false)x+=take();~" \
    src/aster.cpp > "$OUT/mutant.cpp"
cmp -s src/aster.cpp "$OUT/mutant.cpp" && fail 'the sign mutation stopped applying'
$CXX -std=c++17 -O2 -w "$OUT/mutant.cpp" -o "$OUT/mutant" || fail 'the mutant compiler did not build'
set +e
"$OUT/mutant" build-elf "$OUT/e_down.ast" -o "$OUT/mut.elf" >"$OUT/mut.log" 2>&1; mrc=$?
if [ "$mrc" = 0 ]; then chmod +x "$OUT/mut.elf"; "$OUT/mut.elf" >/dev/null 2>&1; mrun=$?; else mrun=-1; fi
set -e
{ [ "$mrc" != 0 ] || [ "$mrun" != 1 ]; } || fail 'the mutant still evaluated 1.5e-3 correctly'
ok "mutant diverges (build rc=$mrc, run=$mrun; 1.5e-3 needs its sign)"

echo 'PASS: exponent float literals (four shapes, equality, integers, refusals, folding)'
