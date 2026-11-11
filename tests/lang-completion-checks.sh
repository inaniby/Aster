#!/bin/sh
# tests/lang-completion-checks.sh — v0.23.77-dev: `do { } while (cond);` and
# `main(argc, argv[, envp])`.
#
# Layers:
#   [1] strict build of the compiler
#   [2] do-while behaviour: test-last, body-once, continue → condition, break
#   [3] do-while labels: `continue outer` from a nested do
#   [4] do-while refusals: a missing `while`, a missing `;`
#   [5] main(argc, argv): argc is the real count, argv[i] is the argument
#   [6] main(argc, argv, envp): the three-parameter form runs
#   [7] main refusals: one parameter, wrong first type
#   [8] the token generator agrees with the compiler (`do`, 84 kinds, 33 words)
#   [9] mutation: a `continue` pointed at the body instead of the condition is
#       caught by layer [2]
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
ASTER="$TMPD/lang-aster"
OUT="$TMPD/lang-work"
rm -rf "$OUT"; mkdir -p "$OUT"

fail(){ echo "FAIL: $*" >&2; exit 1; }
build_run(){ # <name> <source> [args...] ; echoes the exit status
    name=$1; src=$2
    shift 2
    printf '%s\n' "$src" > "$OUT/$name.ast"
    "$ASTER" build-elf "$OUT/$name.ast" -o "$OUT/$name.elf" >/dev/null 2>"$OUT/$name.err" || {
        fail "$name did not compile: $(head -1 "$OUT/$name.err")"; }
    chmod +x "$OUT/$name.elf"
    set +e
    "$RUNNER" "$OUT/$name.elf" "$@" >/dev/null 2>&1
    rc=$?
    set -e
    echo "$rc"
}

printf '%s\n' '[1/9] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -o "$ASTER" src/aster.cpp
printf '  %-40s %s\n' 'compiler built' 'ok'

printf '%s\n' '[2/9] do-while behaviour'
r=$(build_run dw_once 'fn main() -> i32 { let i: i32 = 0; do { i = i + 1; } while (i < 3); return i; }')
[ "$r" = 3 ] || fail "do-while counted to $r, expected 3"
r=$(build_run dw_body_once 'fn main() -> i32 { let i: i32 = 9; do { i = i + 1; } while (i < 3); return i; }')
[ "$r" = 10 ] || fail "the body did not run exactly once ($r, expected 10)"
r=$(build_run dw_continue 'fn main() -> i32 { let i: i32 = 0; let s: i32 = 0; do { i = i + 1; if (i == 2) { continue; } s = s + i; } while (i < 5); return s; }')
[ "$r" = 13 ] || fail "continue skipped the wrong iterations ($r, expected 13)"
r=$(build_run dw_break 'fn main() -> i32 { let i: i32 = 0; do { i = i + 1; if (i == 3) { break; } } while (i < 10); return i; }')
[ "$r" = 3 ] || fail "break left at $r, expected 3"
# continue must reach the condition, not the body: the third iteration exits
r=$(build_run dw_continue_exit 'fn main() -> i32 { let i: i32 = 0; let s: i32 = 0; do { i = i + 1; if (i == 3) { continue; } s = s + 1; } while (i < 3); return s * 10 + i; }')
[ "$r" = 23 ] || fail "continue did not reach the condition ($r, expected 23)"
printf '  %-40s %s\n' 'test-last, once-only, continue, break' 'ok'

printf '%s\n' '[3/9] do-while labels'
r=$(build_run dw_label 'fn main() -> i32 { let i: i32 = 0; outer: do { i = i + 1; let j: i32 = 0; do { j = j + 1; if (j == 2) { continue outer; } } while (j < 5); } while (i < 3); return i * 10 + 1; }')
[ "$r" = 31 ] || fail "continue outer gave $r, expected 31"
printf '  %-40s %s\n' 'continue outer from a nested do' 'ok'

printf '%s\n' '[4/9] do-while refusals'
printf 'fn main() -> i32 { do { } while; return 0; }\n' > "$OUT/bad1.ast"
if "$ASTER" build-elf "$OUT/bad1.ast" -o "$OUT/bad1.elf" >"$OUT/bad1.log" 2>&1; then
    fail 'a do-while without a condition compiled'; fi
grep -q "expected '(' after while" "$OUT/bad1.log" || fail "wrong refusal: $(head -1 "$OUT/bad1.log")"
printf 'fn main() -> i32 { do { } while (0) return 0; }\n' > "$OUT/bad2.ast"
if "$ASTER" build-elf "$OUT/bad2.ast" -o "$OUT/bad2.elf" >"$OUT/bad2.log" 2>&1; then
    fail 'a do-while without its `;` compiled'; fi
grep -q "expected ';' after do-while condition" "$OUT/bad2.log" || fail "wrong refusal: $(head -1 "$OUT/bad2.log")"
printf '  %-40s %s\n' 'missing condition and missing semicolon refused' 'ok'

printf '%s\n' '[5/9] main(argc, argv)'
r=$(build_run m2 'fn main(argc: i32, argv: ptr) -> i32 { return argc; }')
[ "$r" = 1 ] || fail "argc was $r with no arguments, expected 1"
r=$(build_run m2 'fn main(argc: i32, argv: ptr) -> i32 { return argc; }' a b)
[ "$r" = 3 ] || fail "argc was $r with two arguments, expected 3"
r=$(build_run m2argv 'fn arg(i: i32, argv: ptr) -> ptr { return ptr(load_i64(argv + i * 8)); } fn main(argc: i32, argv: ptr) -> i32 { return i32(load_u8(arg(1, argv))); }' hello)
[ "$r" = 104 ] || fail "argv[1][0] gave $r, expected 104 (the byte of 'h')"
printf '  %-40s %s\n' 'argc counts, argv[i] resolves to the argument' 'ok'

printf '%s\n' '[6/9] main(argc, argv, envp)'
r=$(build_run m3 'fn main(argc: i32, argv: ptr, envp: ptr) -> i32 { if (argc != 2) { return 9; } return i32(load_u8(ptr(load_i64(envp)))); }' x)
[ "$r" != 9 ] || fail 'the three-parameter form did not receive argc'
printf '  %-40s %s\n' 'envp form runs with a real argc' 'ok'

printf '%s\n' '[7/9] main refusals'
printf 'fn main(a: i32) -> i32 { return a; }\n' > "$OUT/bad3.ast"
if "$ASTER" build-elf "$OUT/bad3.ast" -o "$OUT/bad3.elf" >"$OUT/bad3.log" 2>&1; then
    fail 'main with one parameter compiled'; fi
grep -q 'main must take no parameters' "$OUT/bad3.log" || fail "wrong refusal: $(head -1 "$OUT/bad3.log")"
printf 'fn main(argc: ptr, argv: ptr) -> i32 { return 0; }\n' > "$OUT/bad4.ast"
if "$ASTER" build-elf "$OUT/bad4.ast" -o "$OUT/bad4.elf" >"$OUT/bad4.log" 2>&1; then
    fail 'main(argc: ptr, …) compiled'; fi
grep -q 'main must take no parameters' "$OUT/bad4.log" || fail "wrong refusal: $(head -1 "$OUT/bad4.log")"
printf '  %-40s %s\n' 'one parameter and a ptr argc refused' 'ok'

printf '%s\n' '[8/9] the token generator agrees with the compiler'
python3 - <<'PY' || exit 1
import re
src = open('src/aster.cpp').read()
assert 'Do };' in src, 'TK::Do missing from the token enum'
assert 'else if(x=="do")k=TK::Do;' in src, 'the lexer does not map `do`'
gen = open('bootstrap/gen_lexer_names.py').read()
m = re.search(r'KEYWORDS = \[(.*?)\]', gen, re.S)
entries = re.findall(r'\("([^"]+)",', m.group(1))
assert len(entries) == 33, ('reserved-word count moved', len(entries))
assert 'do' in entries, 'do is not a reserved word'
assert 'Do' in re.search(r'TOKENS = \[(.*?)\]', gen, re.S).group(1), 'the Do kind is not in TOKENS'
hdr = open('tests/lexer_names.h').read()
assert '#define TK_COUNT 84' in hdr, 'TK_COUNT did not move to 84'
print('PASS: do is reserved, 84 token kinds, 33 keywords')
PY
python3 bootstrap/gen_lexer_names.py --check >/dev/null || fail 'the generated region drifted'
printf '  %-40s %s\n' '83 -> 84 kinds, 33 reserved words, --check clean' 'ok'

printf '%s\n' '[9/9] mutation: continue in a do-while must reach the condition'
sed 's|for(size_t at:loops.back().continues)patchBranch(at,condAt);|for(size_t at:loops.back().continues)patchBranch(at,bodyStart);|' \
    src/aster.cpp > "$OUT/mutant.cpp"
grep -q 'for(size_t at:loops.back().continues)patchBranch(at,bodyStart);' "$OUT/mutant.cpp" \
    || fail 'the continue-target mutation stopped applying'
$CXX -std=c++17 -O2 -w "$OUT/mutant.cpp" -o "$OUT/mutant" || fail 'the mutant no longer compiles'
printf 'fn main() -> i32 { let i: i32 = 0; let s: i32 = 0; do { i = i + 1; if (i == 3) { continue; } s = s + 1; } while (i < 3); return s * 10 + i; }\n' > "$OUT/mut.ast"
"$OUT/mutant" build-elf "$OUT/mut.ast" -o "$OUT/mut.elf" >/dev/null 2>&1 || fail 'the mutant refused the continue case'
chmod +x "$OUT/mut.elf"
set +e
"$RUNNER" "$OUT/mut.elf" >/dev/null 2>&1
mut_rc=$?
set -e
[ "$mut_rc" != 23 ] || fail 'the continue-target mutant still answered 23 — layer [2] cannot see the bug'
printf '  %-40s %s\n' 'mutant diverges (continue no longer reaches the test)' 'ok'

echo 'PASS: language completion (do-while, main arguments, token generator, mutation)'
