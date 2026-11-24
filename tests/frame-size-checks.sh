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
#   [10] compact: recursion goes far deeper than the 8 KiB layout allows
#   [11] compact: a syscall/write's spill + scratch are rebased with the grid
#       (P1-8, v0.23.80-dev) — they must not land in an ancestor's frame
#   [12] compact: a nested call's spill must not land on a live parameter
#       (M3 minimal repro, v0.23.81-dev) — same P1-8 rebase mechanism
#   [13] an i64 live temporary parked across a call keeps its upper half
#       (CODEGEN-SPEC §11 #3: storeLocal is dead code — the live park is
#       spillTemps at full width; this probe pins that behaviour)
#   [14] compact: a frame in (4096, 8191] uses the two-word encoding
#       (D-01, v0.23.82-dev) — no silent fallback to 8192, and the
#       incoming-argument base is patched with the same pair
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

printf '%s\n' '[1/14] Strictly build Aster compiler'
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

printf '%s\n' '[2/14] default: the historical frame is untouched'
"$ASTER" build-elf "$OUT/leaf.ast" -o "$OUT/def.elf" >/dev/null 2>&1 || fail 'the default build failed'
[ "$(frame_of "$OUT/def.elf" leaf)" = 8192 ] || fail "the default leaf frame is $(frame_of "$OUT/def.elf" leaf), expected 8192"
[ "$(ra_off "$OUT/def.elf" leaf)" = 8184 ] || fail "the default RA slot is $(ra_off "$OUT/def.elf" leaf), expected 8184"
chmod +x "$OUT/def.elf"
set +e; "$RUNNER" "$OUT/def.elf"; defrc=$?; set -e
[ "$defrc" = 42 ] || fail 'the default program returned the wrong value'
printf '  %-40s %s\n' 'SUB #8192, X30 at 8184, exit 42' 'ok'

printf '%s\n' '[3/14] compact: a leaf function shrinks'
"$ASTER" build-elf --compact-frames "$OUT/leaf.ast" -o "$OUT/cmp.elf" >/dev/null 2>&1 || fail 'the compact build failed'
lf=$(frame_of "$OUT/cmp.elf" leaf)
[ "$lf" -lt 8192 ] || fail "the compact leaf frame is still $lf"
[ $(( lf % 16 )) = 0 ] || fail "the compact leaf frame ($lf) is not 16-byte aligned"
[ "$(ra_off "$OUT/cmp.elf" leaf)" = $(( lf - 8 )) ] || fail "X30 is not at frame-8 ($(ra_off "$OUT/cmp.elf" leaf) vs $(( lf - 8 )))"
chmod +x "$OUT/cmp.elf"
set +e; "$RUNNER" "$OUT/cmp.elf"; cmprc=$?; set -e
[ "$cmprc" = 42 ] || fail 'the compact program returned the wrong value'
printf '  %-40s %s\n' "leaf frame ${lf} bytes, 16-aligned, X30 at frame-8" 'ok'

printf '%s\n' '[4/14] compact: a calling function shrinks, an aggregate one does not'
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

printf '%s\n' '[5/14] compact: the examples agree with the default build'
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

printf '%s\n' '[6/14] compact: stack arguments still arrive'
"$ASTER" build-elf --compact-frames examples/stack_arg_abi.ast -o "$OUT/sa" >/dev/null 2>&1 || fail 'stack_arg_abi did not build'
chmod +x "$OUT/sa"; set +e; "$RUNNER" "$OUT/sa"; rc=$?; set -e
[ "$rc" = 15 ] || fail "stack_arg_abi returned $rc under --compact-frames, expected 15"
printf '  %-40s %s\n' 'nine-argument and aggregate-on-stack calls' 'ok'

printf '%s\n' '[7/14] compact: -g reports the function frame'
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

printf '%s\n' '[8/14] compact: main(argc, argv) still reads the initial stack'
"$ASTER" build-elf --compact-frames "$OUT/args.ast" -o "$OUT/args.elf" >/dev/null 2>&1 || fail 'the compact args build failed'
chmod +x "$OUT/args.elf"; set +e; "$RUNNER" "$OUT/args.elf" x y; rc=$?; set -e
[ "$rc" = 3 ] || fail "the compact entry saw argc=$rc, expected 3"
printf '  %-40s %s\n' 'argc = 3 with two arguments' 'ok'

printf '%s\n' '[9/14] mutation: the fixup recording is what lets the grid move'
sed 's|if(!recordingScratch)return;|if(true)return;|' \
    src/aster.cpp > "$OUT/mutant.cpp"
grep -q 'if(true)return;' "$OUT/mutant.cpp" || fail 'the fixup-recording mutation stopped applying'
$CXX -std=c++17 -O2 -w -I src "$OUT/mutant.cpp" -o "$OUT/mutant" || fail 'the mutant no longer compiles'
"$OUT/mutant" build-elf --compact-frames "$OUT/leaf.ast" -o "$OUT/mut" >/dev/null 2>&1 || fail 'the mutant refused the caller example'
mf=$(frame_of "$OUT/mut" caller)
[ "$mf" = 8192 ] || fail "with no fixups recorded the caller's frame is $mf — the grid move is not driven by the recording"
set +e; "$RUNNER" "$OUT/mut" >/dev/null 2>&1; mrc=$?; set -e
[ "$mrc" = 42 ] || fail "the un-rebased mutant changed behaviour (exit $mrc) — the fallback must stay correct"
printf '  %-40s %s\n' "mutant falls back to 8192 (frame ${mf}) and still returns 42" 'ok'

# v0.23.82-dev (D-01): the incoming-argument base is patched with the
# framePairX16 two-word encoding, which holds frames up to 4096 + 4095 =
# 8191. A compact frame larger than a single ADD imm12 used to write the
# size into the Rn/Rd fields; it now compacts instead of staying at 8192.
grep -qF 'if(want<=8191u){' src/aster.cpp \
    || fail 'the compact frame no longer checks that its size fits the two-word encoding'

printf '%s\n' '[10/14] compact: recursion goes far deeper than the 8 KiB layout allows'
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

printf '%s\n' '[11/14] compact: a write() callee does not corrupt an ancestor frame'
cat > "$OUT/spill.ast" <<'AST'
fn helper(x: i32) -> i32 {
    let a: i32 = 111111;
    let b: i32 = 222222;
    let c: i32 = a + b + x + write(1, "hi", 2);
    return c;
}
fn mid(v: i32) -> i32 {
    let pad: i32[500] = 0;
    pad[499] = v;
    return helper(pad[499]);
}
fn big() -> i32 {
    let arr: i32[600] = 0;
    let i: i32 = 0;
    while (i < 600) { arr[i] = 1000 + i; i = i + 1; }
    let h: i32 = mid(5);
    let bad: i32 = 0;
    let j: i32 = 0;
    while (j < 600) { if (arr[j] != 1000 + j) { bad = bad + 1; } j = j + 1; }
    if (bad != 0) { return 99; }
    return 42;
}
fn main() -> i32 { return big(); }
AST
"$ASTER" build-elf --compact-frames "$OUT/spill.ast" -o "$OUT/spill-cmp.elf" >/dev/null 2>&1 || fail 'the compact spill build failed'
chmod +x "$OUT/spill-cmp.elf"
set +e; "$RUNNER" "$OUT/spill-cmp.elf" >/dev/null 2>&1; sp_rc=$?; set -e
[ "$sp_rc" = 42 ] || fail "the compact spill run returned $sp_rc, expected 42 (an ancestor's array was corrupted)"
printf '  %-40s %s\n' "write() spill + scratch rebased, ancestor array intact" 'ok'

printf '%s\n' '[12/14] compact: a nested call does not spill onto a live parameter'
# M3 nested-call segfault minimal repro (v0.23.81-dev): under
# --compact-frames the rebase underflowed and a spill slot landed on slot 0
# (the ptr parameter n), so the inner call's argument setup dereferenced a
# corrupted pointer (SIGSEGV, exit 139) on the pre-P1-8 compiler. P1-8 fixed
# the rebase; this probe must stay green. Fixture:
# tests/codegen-fixtures/compact_crash_nested_call.ast (byte-identical copy
# of ~/workspace/segfault-repro/compact-crash.ast).
cp tests/codegen-fixtures/compact_crash_nested_call.ast "$OUT/crash.ast"
"$ASTER" build-obj --compact-frames "$OUT/crash.ast" -o "$OUT/crash.obj" >/dev/null 2>&1 || fail 'the compact crash-probe build failed'
"$ASTER" link-obj "$OUT/crash.obj" -o "$OUT/crash.elf" >/dev/null 2>&1 || fail 'the compact crash-probe link failed'
chmod +x "$OUT/crash.elf"
set +e; "$RUNNER" "$OUT/crash.elf" >/dev/null 2>&1; cc_rc=$?; set -e
[ "$cc_rc" = 0 ] || fail "the nested-call probe returned $cc_rc, expected 0 (a spill corrupted the parameter)"
printf '  %-40s %s\n' 'nested call + 15 locals, exit 0' 'ok'

printf '%s\n' '[13/14] an i64 live temporary parked across a call keeps its upper half'
# CODEGEN-SPEC §11 #3 (W4, §6.3): the live park is spillTemps at full
# width, not the dead storeLocal. big = 5000000000 has nonzero high bits,
# so a 32-bit park would restore 705032704 and return 1.
# Fixture: tests/codegen-fixtures/i64_park_nested_call.ast
cp tests/codegen-fixtures/i64_park_nested_call.ast "$OUT/i64park.ast"
"$ASTER" build-elf "$OUT/i64park.ast" -o "$OUT/i64.elf" >/dev/null 2>&1 || fail 'the i64 park build failed'
"$ASTER" build-elf --compact-frames "$OUT/i64park.ast" -o "$OUT/i64c.elf" >/dev/null 2>&1 || fail 'the i64 park compact build failed'
chmod +x "$OUT/i64.elf" "$OUT/i64c.elf"
set +e; "$RUNNER" "$OUT/i64.elf" >/dev/null 2>&1; i64_rc=$?; "$RUNNER" "$OUT/i64c.elf" >/dev/null 2>&1; i64c_rc=$?; set -e
[ "$i64_rc" = 0 ] || fail "the i64 park run returned $i64_rc, expected 0 (the high half was lost)"
[ "$i64c_rc" = 0 ] || fail "the i64 park compact run returned $i64c_rc, expected 0 (the high half was lost)"
# The park at the spill base must be a full-width STR X, never a STR W.
llvm-objdump -d --no-show-raw-insn "$OUT/i64.elf" \
    | awk -v sym='<main>:' '$2==sym{f=1;next} f&&/^$/{exit} f{print}' \
    | grep -qE 'str[[:space:]]+x[0-9]+, \[sp, #0xfc0\]' \
    || fail 'no full-width STR X park at [SP, #4032] in the i64 probe'
llvm-objdump -d --no-show-raw-insn "$OUT/i64.elf" \
    | awk -v sym='<main>:' '$2==sym{f=1;next} f&&/^$/{exit} f{print}' \
    | grep -qE 'str[[:space:]]+w[0-9]+, \[sp, #0xfc0\]' \
    && fail 'a 32-bit STR W park at [SP, #4032] truncates the live i64 temporary'
printf '  %-40s %s\n' 'i64 live across nested calls, exit 0, STR X park' 'ok'

printf '%s\n' '[14/14] compact: a frame in (4096, 8191] uses the two-word encoding'
# D-01 (v0.23.82-dev): the pre-fix compiler silently fell back to an 8192
# frame here (correct result, no warning). The frame must now land in
# (4096, 8191], 16-aligned, X30 at frame-8, and the incoming-argument base
# must be the ADD X16, SP, #4096 + ADD X16, X16, #rest pair.
# Fixture: tests/codegen-fixtures/compact_frame_midrange.ast
cp tests/codegen-fixtures/compact_frame_midrange.ast "$OUT/mid.ast"
"$ASTER" build-elf --compact-frames "$OUT/mid.ast" -o "$OUT/mid.elf" >/dev/null 2>&1 || fail 'the midrange build failed'
mf=$(frame_of "$OUT/mid.elf" big)
[ "$mf" -gt 4096 ] || fail "the midrange frame is $mf, expected (4096, 8191] — the silent fallback is still in force"
[ "$mf" -lt 8192 ] || fail "the midrange frame is $mf, expected (4096, 8191]"
[ $(( mf % 16 )) = 0 ] || fail "the midrange frame ($mf) is not 16-byte aligned"
[ "$(ra_off "$OUT/mid.elf" big)" = $(( mf - 8 )) ] || fail 'X30 is not at frame-8 in the midrange frame'
rest=$(( mf - 4096 )); resthex=$(printf '%x' "$rest")
llvm-objdump -d --no-show-raw-insn "$OUT/mid.elf" \
    | awk -v sym='<big>:' '$2==sym{f=1;next} f&&/^$/{exit} f{print}' \
    | grep -q 'add[[:space:]]*x16, sp, #0x1, lsl #12' \
    || fail 'the incoming-base pair has no ADD X16, SP, #4096 first half'
llvm-objdump -d --no-show-raw-insn "$OUT/mid.elf" \
    | awk -v sym='<big>:' '$2==sym{f=1;next} f&&/^$/{exit} f{print}' \
    | grep -q "add[[:space:]]*x16, x16, #0x${resthex}" \
    || fail "the incoming-base pair is not ADD X16, SP, #4096 + ADD X16, X16, #${rest}"
chmod +x "$OUT/mid.elf"
set +e; "$RUNNER" "$OUT/mid.elf" >/dev/null 2>&1; mid_rc=$?; set -e
[ "$mid_rc" = 0 ] || fail "the midrange run returned $mid_rc, expected 0 (a stack argument or the frame is wrong)"
# Edge: a function that keeps the 8192 frame and still takes stack
# arguments needs ADD #4096 + ADD #4096 (the wide second word).
cat > "$OUT/edge.ast" <<'AST'
struct S { x: i32, y: i32, z: i32 }
fn f(p1: i32, p2: i32, p3: i32, p4: i32, p5: i32, p6: i32, p7: i32, p8: i32, p9: i32, p10: i32) -> S { return S { p9, p10, p1 }; }
fn main() -> i32 {
    let s: S = f(1, 2, 3, 4, 5, 6, 7, 8, 9, 10);
    if (s.x == 9) { if (s.y == 10) { if (s.z == 1) { return 0; } } }
    return 1;
}
AST
"$ASTER" build-elf --compact-frames "$OUT/edge.ast" -o "$OUT/edge.elf" >/dev/null 2>&1 || fail 'the 8192-frame edge build failed'
[ "$(frame_of "$OUT/edge.elf" f)" = 8192 ] || fail "the aggregate function's frame is $(frame_of "$OUT/edge.elf" f), expected the 8 KiB tail layout"
llvm-objdump -d --no-show-raw-insn "$OUT/edge.elf" \
    | awk -v sym='<f>:' '$2==sym{f=1;next} f&&/^$/{exit} f{print}' \
    | grep -q 'add[[:space:]]*x16, x16, #0x1, lsl #12' \
    || fail 'the 8192-frame incoming base is not ADD #4096 + ADD #4096'
chmod +x "$OUT/edge.elf"
set +e; "$RUNNER" "$OUT/edge.elf" >/dev/null 2>&1; edge_rc=$?; set -e
[ "$edge_rc" = 0 ] || fail "the 8192-frame edge run returned $edge_rc, expected 0 (a stack argument was lost)"
# -g: the FDE must report the midrange frame too.
"$ASTER" build-elf -g --compact-frames "$OUT/mid.ast" -o "$OUT/mid-dbg.elf" >/dev/null 2>&1 || fail 'the -g midrange build failed'
llvm-dwarfdump --eh-frame "$OUT/mid-dbg.elf" 2>/dev/null | grep -q "def_cfa_offset: +${mf}" \
    || fail "no FDE reports the midrange frame (+${mf})"
printf '  %-40s %s\n' "midrange frame ${mf} bytes, base pair + edge 8192, FDE +${mf}" 'ok'

echo 'PASS: frame sizing (default pinned, compact leaf, stack args, CFI, mutation, nested-call spill probe, i64 park, midrange frame)'
