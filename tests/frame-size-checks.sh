#!/bin/sh
# tests/frame-size-checks.sh — v0.23.77-dev: `--compact-frames`.
#
# The default build keeps the historical 8 KiB frame byte for byte; the flag
# sizes a function's frame to its own locals (plus the saved return address)
# when the function neither calls nor copies or returns an aggregate. Those
# functions are exactly the ones whose frame holds nothing but their variables.
#
# Layers:
#   [1] strict build of the compiler
#   [2] default: one SUB #8192, X30 at 8184 (the historical shape, pinned)
#   [3] compact: a leaf function shrinks; frame 16-aligned; X30 at frame-8
#   [4] compact: a calling function keeps 8192 (its call scratch still lives there)
#   [5] compact: every example still runs with the same exit code as the default
#   [6] compact: stack arguments still arrive (the shipped stack_arg_abi witness)
#   [7] compact: -g's FDE reports the function's own frame
#   [8] compact: main(argc, argv) still reads the initial stack
#   [9] mutation: dropping the call/aggregate guard must break the examples
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
ASTER="$TMPD/frame-aster"
OUT="$TMPD/frame-work"
rm -rf "$OUT"; mkdir -p "$OUT"
fail(){ echo "FAIL: $*" >&2; exit 1; }
prologue(){ # <elf> <symbol> -> the leading SUB SP instructions (one, or a pair)
    llvm-objdump -d --no-show-raw-insn "$1" 2>/dev/null \
        | awk -v sym="<$2>:" '
            $2==sym {f=1; next}
            f {
                if ($2=="sub") {print; next}
                exit
            }'
}
frame_of(){ # <elf> <symbol> -> SUM of the SUB immediates in bytes
    prologue "$1" "$2" | awk '
        function hexval(h,   i,c,d,n){ n=0; for(i=1;i<=length(h);i++){ c=substr(h,i,1); d=index("0123456789abcdef",c)-1; if(d<0)break; n=n*16+d } return n }
        /#0x2, lsl #12/ { s += 8192; next }
        /#0x1, lsl #12/ { s += 4096; next }
        /lsr|lsl/ { next }
        /#0x[0-9a-f]+/ { v=$0; sub(/.*#0x/,"",v); sub(/[^0-9a-f].*/,"",v); s += hexval(v) }
        END { print s }'
}
ra_off(){ # <elf> <symbol> -> the offset X30 is saved at, or empty
    llvm-objdump -d --no-show-raw-insn "$1" 2>/dev/null \
        | awk -v sym="<$2>:" 'function hexval(h,   i,c,d,n){ n=0; for(i=1;i<=length(h);i++){ c=substr(h,i,1); d=index("0123456789abcdef",c)-1; if(d<0)break; n=n*16+d } return n } $2==sym{f=1;next} f&&/str[ \t]+x30/{ v=$0; sub(/.*#0x/,"",v); sub(/[^0-9a-f].*/,"",v); print hexval(v); exit }'
}

printf '%s\n' '[1/10] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -o "$ASTER" src/aster.cpp
printf '  %-40s %s\n' 'compiler built' 'ok'

cat > "$OUT/leaf.ast" <<'AST'
fn leaf(a: i32) -> i32 { let x: i32 = a + 1; return x; }
fn caller(a: i32) -> i32 { return leaf(a) + 1; }
fn main() -> i32 { return caller(40); }
AST
cat > "$OUT/rec.ast" <<'AST'
fn f(n: i32) -> i32 { if (n == 0) { return 0; } return 1 + f(n - 1); }
fn main() -> i32 { return f(100); }
AST
cat > "$OUT/args.ast" <<'AST'
fn main(argc: i32, argv: ptr) -> i32 { return argc; }
AST

printf '%s\n' '[2/10] default: the historical frame is untouched'
"$ASTER" build-elf "$OUT/leaf.ast" -o "$OUT/def.elf" >/dev/null 2>&1 || fail 'the default build failed'
[ "$(frame_of "$OUT/def.elf" leaf)" = 8192 ] || fail "the default leaf frame is $(frame_of "$OUT/def.elf" leaf), expected 8192"
[ "$(ra_off "$OUT/def.elf" leaf)" = 8184 ] || fail "the default RA slot is $(ra_off "$OUT/def.elf" leaf), expected 8184"
chmod +x "$OUT/def.elf"
set +e; "$RUNNER" "$OUT/def.elf"; defrc=$?; set -e
[ "$defrc" = 42 ] || fail 'the default program returned the wrong value'
printf '  %-40s %s\n' 'SUB #8192, X30 at 8184, exit 42' 'ok'

printf '%s\n' '[3/10] compact: a leaf function shrinks'
"$ASTER" build-elf --compact-frames "$OUT/leaf.ast" -o "$OUT/cmp.elf" >/dev/null 2>&1 || fail 'the compact build failed'
lf=$(frame_of "$OUT/cmp.elf" leaf)
[ "$lf" -lt 8192 ] || fail "the compact leaf frame is still $lf"
[ $(( lf % 16 )) = 0 ] || fail "the compact leaf frame ($lf) is not 16-byte aligned"
[ "$(ra_off "$OUT/cmp.elf" leaf)" = $(( lf - 8 )) ] || fail "X30 is not at frame-8 ($(ra_off "$OUT/cmp.elf" leaf) vs $(( lf - 8 )))"
chmod +x "$OUT/cmp.elf"
set +e; "$RUNNER" "$OUT/cmp.elf"; cmprc=$?; set -e
[ "$cmprc" = 42 ] || fail 'the compact program returned the wrong value'
printf '  %-40s %s\n' "leaf frame ${lf} bytes, 16-aligned, X30 at frame-8" 'ok'

printf '%s\n' '[4/10] compact: a calling function shrinks, an aggregate one does not'
pf=$(frame_of "$OUT/cmp.elf" caller)
[ "$pf" -lt 8192 ] || fail "the calling function's frame is $pf — the call grid did not move"
[ $(( pf % 16 )) = 0 ] || fail "the calling function's frame ($pf) is not 16-byte aligned"
cat > "$OUT/agg.ast" <<'AST'
struct S { x: i32, y: i32 }
fn f() -> S { return S { 3, 4 }; }
fn main() -> i32 { let s: S = f(); return s.x + s.y; }
AST
"$ASTER" build-elf --compact-frames "$OUT/agg.ast" -o "$OUT/agg.elf" >/dev/null 2>&1 || fail 'the aggregate build failed'
af=$(frame_of "$OUT/agg.elf" f)
[ "$af" = 8192 ] || fail "the aggregate-returning function's frame is $af, expected the 8 KiB tail layout"
printf '  %-40s %s\n' "caller frame ${pf} (moved grid), aggregate f stays 8192" 'ok'

printf '%s\n' '[5/10] compact: the examples agree with the default build'
n=0; bad=0
for f in examples/arithmetic.ast examples/condition.ast examples/loops.ast examples/structs.ast \
         examples/arrays.ast examples/pointers.ast examples/switch.ast examples/unions.ast \
         examples/narrow_args.ast examples/stack_arg_abi.ast examples/tls_demo.ast examples/globals.ast; do
    [ -f "$f" ] || continue
    b=$(basename "$f" .ast)
    "$ASTER" build-elf "$f" -o "$OUT/d-$b" >/dev/null 2>&1 || continue
    "$ASTER" build-elf --compact-frames "$f" -o "$OUT/c-$b" >/dev/null 2>&1 || fail "the compact build of $b failed"
    chmod +x "$OUT/d-$b" "$OUT/c-$b"
    set +e
    "$RUNNER" "$OUT/d-$b" >/dev/null 2>&1; a=$?
    "$RUNNER" "$OUT/c-$b" >/dev/null 2>&1; b2=$?
    set -e
    n=$((n+1))
    [ "$a" = "$b2" ] || { bad=$((bad+1)); echo "  $b: default=$a compact=$b2" >&2; }
done
[ "$bad" = 0 ] || fail "$bad example(s) changed exit status under --compact-frames"
printf '  %-40s %s\n' "$n examples: identical exit status" 'ok'

printf '%s\n' '[6/10] compact: stack arguments still arrive'
"$ASTER" build-elf --compact-frames examples/stack_arg_abi.ast -o "$OUT/sa" >/dev/null 2>&1 || fail 'stack_arg_abi did not build'
chmod +x "$OUT/sa"; set +e; "$RUNNER" "$OUT/sa"; rc=$?; set -e
[ "$rc" = 15 ] || fail "stack_arg_abi returned $rc under --compact-frames, expected 15"
printf '  %-40s %s\n' 'nine-argument and aggregate-on-stack calls' 'ok'

printf '%s\n' '[7/10] compact: -g reports the function frame'
"$ASTER" build-elf -g --compact-frames "$OUT/leaf.ast" -o "$OUT/dbg.elf" >/dev/null 2>&1 || fail 'the -g compact build failed'
# Every function's FDE must report that function's own frame: compare the
# sorted list of CFA offsets with the sorted list of prologue frame sizes.
want=""
for sym in $(llvm-readelf -sW "$OUT/dbg.elf" | awk '$4=="FUNC" && $7!="UND" && $8!="main" {print $8}'; echo main); do
    want="$want $(frame_of "$OUT/dbg.elf" "$sym")"
done
got=$(llvm-dwarfdump --eh-frame "$OUT/dbg.elf" 2>/dev/null | grep -o 'def_cfa_offset: +[0-9]*' | tr -dc '0-9\n' | sort -n | tr '\n' ' ')
want=$(printf '%s\n' $want | sort -n | tr '\n' ' ')
[ "$got" = "$want" ] || fail "the FDEs report [$got] but the prologues allocate [$want]"
printf '  %-40s %s\n' "FDE CFA list == prologue frame list ([$got])" 'ok'

printf '%s\n' '[8/10] compact: main(argc, argv) still reads the initial stack'
"$ASTER" build-elf --compact-frames "$OUT/args.ast" -o "$OUT/args.elf" >/dev/null 2>&1 || fail 'the compact args build failed'
chmod +x "$OUT/args.elf"; set +e; "$RUNNER" "$OUT/args.elf" x y; rc=$?; set -e
[ "$rc" = 3 ] || fail "the compact entry saw argc=$rc, expected 3"
printf '  %-40s %s\n' 'argc = 3 with two arguments' 'ok'

printf '%s\n' '[9/10] mutation: the fixup recording is what lets the grid move'
sed 's|if(!recordingScratch)return;|if(true)return;|' \
    src/aster.cpp > "$OUT/mutant.cpp"
grep -q 'if(true)return;' "$OUT/mutant.cpp" || fail 'the fixup-recording mutation stopped applying'
$CXX -std=c++17 -O2 -w "$OUT/mutant.cpp" -o "$OUT/mutant" || fail 'the mutant no longer compiles'
"$OUT/mutant" build-elf --compact-frames "$OUT/leaf.ast" -o "$OUT/mut" >/dev/null 2>&1 || fail 'the mutant refused the caller example'
mf=$(frame_of "$OUT/mut" caller)
[ "$mf" = 8192 ] || fail "with no fixups recorded the caller's frame is $mf — the grid move is not driven by the recording"
set +e; "$RUNNER" "$OUT/mut" >/dev/null 2>&1; mrc=$?; set -e
[ "$mrc" = 42 ] || fail "the un-rebased mutant changed behaviour (exit $mrc) — the fallback must stay correct"
printf '  %-40s %s\n' "mutant falls back to 8192 (frame ${mf}) and still returns 42" 'ok'

printf '%s\n' '[10/10] compact: recursion goes far deeper than the 8 KiB layout allows'
cat > "$OUT/deep.ast" <<'AST'
fn f(n: i32) -> i32 { if (n == 0) { return 0; } return 1 + f(n - 1); }
fn main() -> i32 { return f(20000) & 255; }
AST
"$ASTER" build-elf "$OUT/deep.ast" -o "$OUT/deep-def.elf" >/dev/null 2>&1 || fail 'the default deep build failed'
"$ASTER" build-elf --compact-frames "$OUT/deep.ast" -o "$OUT/deep-cmp.elf" >/dev/null 2>&1 || fail 'the compact deep build failed'
chmod +x "$OUT/deep-def.elf" "$OUT/deep-cmp.elf"
set +e
"$RUNNER" "$OUT/deep-def.elf" >/dev/null 2>&1; def_deep=$?
"$RUNNER" "$OUT/deep-cmp.elf" >/dev/null 2>&1; cmp_deep=$?
set -e
[ "$def_deep" = 139 ] || fail "the default layout survived depth 20000 (exit $def_deep) — the witness is not measuring the frame"
[ "$cmp_deep" != 139 ] || fail 'the compact layout also overflowed at depth 20000'
[ "$cmp_deep" = $(( 20000 & 255 )) ] || fail "the compact deep run returned $cmp_deep, expected $(( 20000 & 255 ))"
printf '  %-40s %s\n' "default=139 (overflow), compact=${cmp_deep} at depth 20000" 'ok'

echo 'PASS: frame sizing (default pinned, compact leaf, stack args, CFI, mutation)'
