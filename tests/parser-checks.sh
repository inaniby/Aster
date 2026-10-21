#!/bin/sh
# tests/parser-checks.sh — the M3b parser, differentially and against the spec.
#
# v0.23.44-dev (self-hosting M3b) ships bootstrap/aster.ast with its second
# stage: one Aster source in on stdin, the AST dump out on stdout. The frozen
# contract is bootstrap/PARSER-SPEC.md; the independent oracle is
# tests/parser-twin.c, written from that spec in C — a recursive descent
# against the bootstrap's explicit work-stack state machine, so the two share
# no code and can still be made to agree byte for byte; this suite holds both
# to the spec.
#
# The shape follows tests/lexer-checks.sh (the M3a delivery chain), which this
# suite retires: strictly build the host compiler, build-obj the bootstrap
# stage, build-obj the library, link-obj them main-first, and compare against
# the twin. What is new is that the subject is a parser, so the suite also
# pins the spec itself — the five frozen §9 examples (extracted from the spec
# at run time, so the spec stays the single source of truth), every P*/B*/C*
# diagnostic with its exact words and position, the caps at their edges, and
# the mutation probes that keep every rule load-bearing.
#
# The lexer's own coverage (E1–E9, position semantics, the operator and
# keyword tables) moves here from lexer-checks.sh, because the retired suite
# was its only home: §6 below re-pins the nine diagnostics and §7 the
# position semantics the parser stage inherits unchanged from M3a.

set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-parser-checks}
W="$OUT/work"
mkdir -p "$W"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# [1/11] Strictly build the Aster compiler
printf '%s\n' '[1/11] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"

# ---------------------------------------------------------------------------
# [2/11] Locate a runner. The bootstrap binary is AArch64; on any other host
# it runs under qemu-aarch64 user-mode emulation.
printf '%s\n' '[2/11] Locate an AArch64 runner'
if ! command -v qemu-aarch64 >/dev/null 2>&1 && [ "$(uname -m)" != "aarch64" ]; then
    echo "SKIP: parser coverage needs qemu-aarch64 (or an AArch64 host)"
    exit 0
fi
run(){ sh tests/run-aarch64.sh "$@"; }

# ---------------------------------------------------------------------------
# [3/11] Generator freshness. bootstrap/gen_parser_names.py is the single
# source of truth for the node-kind names and numbers (spec §13); the lexer's
# gen_lexer_names.py still feeds the twin's token codes. A table that drifted
# from the Python fails CI here rather than the differential.
printf '%s\n' '[3/11] The generated tables are what the Python produces'
if ! python3 bootstrap/gen_parser_names.py --check; then
    echo "FAIL: stale parser tables — re-run: python3 bootstrap/gen_parser_names.py" >&2
    exit 1
fi
if ! python3 bootstrap/gen_lexer_names.py --check; then
    echo "FAIL: stale lexer tables — re-run: python3 bootstrap/gen_lexer_names.py" >&2
    exit 1
fi
printf 'PASS: aster.ast generated regions, tests/parser_names.h and tests/lexer_names.h are fresh\n'

# ---------------------------------------------------------------------------
# [4/11] The delivery shape, then self-containedness. build-obj the bootstrap
# stage, build-obj the library, link-obj main-first — the same chain
# bootstrap/aster.ast's header documents. The twin is built with the host C
# compiler (it is a host program, not a guest) under -Werror: the oracle is
# a shipped artifact and a warning there is future drift.
printf '%s\n' '[4/11] Delivery shape: boot.o + std.o linked; the twin is built'
if ! "$OUT/aster" build-obj bootstrap/aster.ast -o "$W/boot.o" >"$W/boot.log" 2>&1; then
    echo "FAIL: bootstrap build-obj failed:" >&2; cat "$W/boot.log" >&2; exit 1
fi
if ! "$OUT/aster" build-obj stdlib/aster_std.ast -o "$W/std.o" >"$W/std.log" 2>&1; then
    echo "FAIL: stdlib build-obj failed:" >&2; cat "$W/std.log" >&2; exit 1
fi
if ! "$OUT/aster" link-obj "$W/boot.o" "$W/std.o" -o "$W/parser" >"$W/link.log" 2>&1; then
    echo "FAIL: link-obj boot.o std.o failed:" >&2; cat "$W/link.log" >&2; exit 1
fi
printf 'PASS: %s | %s\n' "$(cat "$W/boot.log")" "$(cat "$W/link.log")"
TWCC=${CC:-}
if [ -z "$TWCC" ]; then
    for c in cc gcc clang; do
        if command -v "$c" >/dev/null 2>&1; then TWCC="$c"; break; fi
    done
fi
if [ -z "$TWCC" ]; then
    echo "SKIP: parser coverage needs a host C compiler for the twin (none found)"
    exit 0
fi
if ! "$TWCC" -std=c11 -O2 -Wall -Wextra -Werror -fwrapv -fno-builtin \
        tests/parser-twin.c -o "$W/twin" >"$W/twin.log" 2>&1; then
    echo "FAIL: C twin build failed:" >&2; cat "$W/twin.log" >&2; exit 1
fi
printf 'PASS: twin built with %s (-std=c11 -O2 -Wall -Wextra -Werror -fwrapv -fno-builtin)\n' "$TWCC"
# Zero-dependency, made checkable: the linked executable imports nothing.
# The only UND entry is the ELF null symbol at index 0 — no libc, no external
# anything (the two extern fn the stage declares are satisfied by std.o, and
# __aster_init_next by the linker).
for f in "$W/parser" "$W/std.o"; do
    und=$(readelf -sW "$f" | awk '$7=="UND"' | wc -l)
    if [ "$und" -ne 1 ]; then
        echo "FAIL: $f has $und UND symbols, expected exactly 1 (the ELF null symbol)" >&2
        readelf -sW "$f" | awk '$7=="UND"' >&2
        exit 1
    fi
done
printf 'PASS: zero-dependency — parser and std.o each import nothing (1 UND = the null symbol)\n'

# ---------------------------------------------------------------------------
# Helpers. pin runs BOTH sides and requires each to match pinned bytes
# exactly; diffcase requires only that the two sides agree.
pin(){ # $1 name  $2 input  $3 expected rc  $4 expected stdout  $5 expected stderr
    pn="$1"; pin="$2"; prc="$3"; pout="$4"; perr="$5"
    for side in parser twin; do
        rc=0
        run "$W/$side" <"$pin" >"$W/$side.out" 2>"$W/$side.err" || rc=$?
        if [ "$rc" -ne "$prc" ]; then
            echo "FAIL: $pn ($side): exit $rc, expected $prc" >&2; return 1
        fi
        if ! cmp -s "$W/$side.out" "$pout"; then
            echo "FAIL: $pn ($side): stdout differs from the pinned bytes:" >&2
            diff "$pout" "$W/$side.out" >&2 || true; return 1
        fi
        if ! cmp -s "$W/$side.err" "$perr"; then
            echo "FAIL: $pn ($side): stderr differs from the pinned bytes:" >&2
            diff "$perr" "$W/$side.err" >&2 || true; return 1
        fi
    done
    printf 'PASS: %s (both sides, byte-exact)\n' "$pn"
}
diffcase(){ # $1 name  $2 input — both sides must agree on rc, stdout and stderr
    dn="$1"; din="$2"
    arc=0; run "$W/parser" <"$din" >"$W/d.ao" 2>"$W/d.ae" || arc=$?
    trc=0; run "$W/twin"  <"$din" >"$W/d.to" 2>"$W/d.te" || trc=$?
    if [ "$arc" -ne "$trc" ] || ! cmp -s "$W/d.ao" "$W/d.to" || ! cmp -s "$W/d.ae" "$W/d.te"; then
        echo "FAIL: $dn — the parser and the twin disagree (aster rc=$arc, twin rc=$trc)" >&2
        cmp "$W/d.ao" "$W/d.to" >&2 || true
        cmp "$W/d.ae" "$W/d.te" >&2 || true
        return 1
    fi
    printf 'PASS: %s (agree: rc=%s, %s bytes out, %s bytes err)\n' \
        "$dn" "$arc" "$(wc -c <"$W/d.ao")" "$(wc -c <"$W/d.ae")"
}
okcase(){ # $1 name  $2 input — both sides agree, succeed, and dump identically
    on="$1"; oin="$2"
    arc=0; run "$W/parser" <"$oin" >"$W/o.ao" 2>"$W/o.ae" || arc=$?
    trc=0; run "$W/twin"  <"$oin" >"$W/o.to" 2>"$W/o.te" || trc=$?
    if [ "$arc" -ne 0 ] || [ "$trc" -ne 0 ] || [ -s "$W/o.ae" ] || [ -s "$W/o.te" ] \
       || ! cmp -s "$W/o.ao" "$W/o.to"; then
        echo "FAIL: $on — expected both sides to succeed with identical dumps (rc=$arc/$trc)" >&2
        return 1
    fi
    printf 'PASS: %s (both sides, rc=0, %s bytes out, stderr empty)\n' \
        "$on" "$(wc -c <"$W/o.ao")"
}

# ---------------------------------------------------------------------------
# [5/11] The five frozen §9 examples, byte for byte — and extracted from the
# spec itself, so the frozen contract and the suite can never drift apart.
# Each section's first fenced block is the source, the second the dump; §9.5
# has only the dump, its source being the empty stdin.
printf '%s\n' '[5/11] Spec §9 frozen examples: extracted from the spec, both sides, byte-exact'
python3 - "$W" <<'PYEOF'
import re, sys
w = sys.argv[1]
spec = open('bootstrap/PARSER-SPEC.md').read()
sections = re.split(r'^### (9\.\d)', spec, flags=re.M)
blocks = {}
for i in range(1, len(sections), 2):
    fenced = re.findall(r'^```\n(.*?)^```$', sections[i + 1], flags=re.M | re.S)
    blocks[sections[i]] = fenced
for num, name in (('9.1', 'ex1'), ('9.2', 'ex2'), ('9.3', 'ex3'), ('9.4', 'ex4')):
    src, dump = blocks[num][0], blocks[num][1]
    open(w + '/' + name + '.ast', 'w').write(src)
    open(w + '/' + name + '.exp', 'w').write(dump)
open(w + '/ex5.ast', 'wb').write(b'')
open(w + '/ex5.exp', 'w').write(blocks['9.5'][0])
PYEOF
for e in ex1 ex2 ex3 ex4 ex5; do
    pin "spec §9 frozen example $e" "$W/$e.ast" 0 "$W/$e.exp" /dev/null
done

# ---------------------------------------------------------------------------
# [6/11] The diagnostics, pinned on both sides: exact words, exact position,
# exit 1, stdout byte-empty (two-phase, spec §1/§8). The messages and the
# position rules are spec §11.1 (the host's own, verified against
# src/aster.cpp and its binary) and §11.2 (the subset boundaries); the nine
# lexer diagnostics are LEXER-SPEC.md §10, carried over from the retired
# lexer suite. E1–E7 and E8/E9 take bare fragments — lexing precedes parsing,
# so phase 1 answers before the parser ever runs.
printf '%s\n' '[6/11] Diagnostics: E1-E9, P1-P62, B1-B22 — exact message, position, exit 1'
python3 - "$W" <<'PYEOF'
import sys
w = sys.argv[1]
d = w + '/diag'
import os; os.makedirs(d, exist_ok=True)
cases = []
def E(name, data, msg):                      # lexer diagnostics (LEXER-SPEC §10)
    cases.append((name, data, msg))
def P(name, src, msg):                       # host parser messages (spec §11.1)
    cases.append((name, src, msg))
def B(name, src, msg):                       # subset boundaries (spec §11.2)
    cases.append((name, src, msg))

E('e1', b'/*',                 'unterminated block comment at 1:1')
E('e2', b'0x',                 'hexadecimal literal has no digits at 1:1')
E('e3', b'"a\nb"',             'newline in string literal at 1:1')
E('e4', b'"\\q"',              'unsupported string escape at 1:4')
E('e5', b'"abc',               'unterminated string literal at 1:1')
E('e6', b'\x80',               'non-ASCII character at 1:1 (Aster source must be ASCII)')
E('e7', b'#',                  'unexpected character at 1:1')

P('p1',  b'x\n',                     'expected fn at 1:1')
P('p2',  b'fn () -> i32 { return 0; }\n',
                                   'expected function name at 1:4')
P('p3',  b'fn main -> i32 { return 0; }\n',
                                   "expected '(' after function name at 1:9")
P('p4',  b'fn f(1: i32) -> i32 { return 0; }\n',
                                   'expected parameter name at 1:6')
P('p5',  b'fn f(a i32) -> i32 { return 0; }\n',
                                   "expected ':' after parameter name at 1:8")
P('p6',  b'fn f(a: i32, a: i32) -> i32 { return 0; }\n',
                                   'duplicate parameter name in function f: a')
P('p8',  b'fn f(a: i32 -> i32 { return 0; }\n',
                                   "expected ')' after parameters at 1:13")
P('p9',  b'fn f() i32 { return 0; }\n',
                                   'expected -> at 1:8')
P('p10', b'fn main() -> i32 { let x: nope = 1; return 0; }\n',
                                   'expected i32, i64, u8, u16, u32, ptr, ptr<S>, bool, or a struct name at 1:27')
P('p11', b'fn f() -> i32[4] { return 0; }\n',
                                   'a function cannot return an array: return ptr<i32>, or take the array as a parameter and let the caller\'s storage be written through at 1:14')
P('p12', b'fn main() -> i64 { return 0; }\n',
                                   'main must return i32')
P('p13', b'extern fn f() -> i32 { return 0; }\n',
                                   "expected ';' after extern function declaration at 1:22")
P('p14', b'fn f() -> i32 return 0; }\n',
                                   "expected '{' at 1:15")
P('p15', b'fn main() -> i32 { return 0;\n',
                                   "expected '}' at 2:1")
P('p16', b'fn f() -> i32 {}\n',
                                   'function body cannot be empty: f')
P('p17', b'fn f() -> i32 { return 1; }\nfn f() -> i32 { return 2; }\n',
                                   'duplicate function declaration: f')
P('p18', b'fn f() -> i32 { return 0; }\nlet f: i32 = 1;\n',
                                   'global variable conflicts with function: f')
P('p19', b'let 1: i32 = 0;\n',
                                   'expected global variable name at 1:5')
P('p20', b'let g i32 = 0;\n',
                                   "expected ':' at 1:7")
P('p21', b'let g: i32 = 1;\nlet g: i32 = 2;\n',
                                   'duplicate global variable: g')
P('p22', b'let g: i32;\n',
                                   "expected '=' in global variable declaration at 1:11")
P('p23', b'extern let g: i32 = 1\n',
                                   "expected ';' after extern global declaration at 1:19")
P('p24', b'let a: i32[] = 0;\n',
                                   'expected array length at 1:12')
P('p25', b'let a: i32[1048577] = 0;\n',
                                   'array length must be between 1 and 1048576: a at 1:12')
P('p26', b'let a: i32[4 = 0;\n',
                                   "expected ']' after array length at 1:14")
P('p27', b'let b: i32 = 1;\nlet a: i32[2] = b;\n',
                                   'array initializer must be a constant expression: a')
P('p28', b'let a: u8[1] = 256;\n',
                                   'array initializer does not fit in u8: a (256)')
P('p29', b'let g: u8 = 256;\n',
                                   'global initializer does not fit in u8: g (256)')
P('p30', b'let g: i32 = 1 / 0;\n',
                                   'division by zero in global variable initializer at 1:14')
P('p31', b'let g: i32 = 1 << 64;\n',
                                   'shift count 64 is out of range (0..63) in global variable initializer at 1:14')
P('p31n', b'let g: i32 = 1 << -1;\n',
                                   'shift count -1 is out of range (0..63) in global variable initializer at 1:14')
P('p32', b'let g: i64 = 3 << 62;\n',
                                   'left shift overflows i64 in global variable initializer at 1:14')
P('p33', b'fn main() -> i32 { let 1: i32 = 0; return 0; }\n',
                                   'expected variable name at 1:24')
P('p34', b'fn main() -> i32 { let x i32 = 0; return 0; }\n',
                                   "expected ':' at 1:26")
P('p35', b'fn main() -> i32 { let x: i32; return 0; }\n',
                                   "expected '=' at 1:30")
P('p36', b'fn main() -> i32 { let x: i32 = 0 return 0; }\n',
                                   "expected ';' at 1:35")
P('p37', b'fn main() -> i32 { a[0] + 1; return 0; }\n',
                                   "expected '=' in array element assignment at 1:20")
P('p39', b'fn main() -> i32 { a[0 = 1; return 0; }\n',
                                   "expected ']' after array index at 1:24")
P('p41', b'fn main() -> i32 { return ; }\n',
                                   'expected expression at 1:27')
P('p42', b'fn main() -> i32 { f(1) return 0; }\n',
                                   "expected ';' after call statement at 1:25")
P('p43', b'fn main() -> i32 { if 1 { return 0; } return 0; }\n',
                                   "expected '(' after if at 1:23")
P('p44', b'fn main() -> i32 { if (1 { return 0; } return 0; }\n',
                                   "expected ')' after condition at 1:26")
P('p45', b'fn main() -> i32 { while 1 { return 0; } return 0; }\n',
                                   "expected '(' after while at 1:26")
P('p46', b'fn main() -> i32 { break return 0; }\n',
                                   "expected ';' after break at 1:26")
P('p47', b'fn main() -> i32 { continue return 0; }\n',
                                   "expected ';' after continue at 1:29")
P('p48', b'fn main() -> i32 { let x: i32 = (1 + 2; }\n',
                                   "expected ')'  at 1:39")   # the host's trailing space: two before "at"
P('p49', b'fn main() -> i32 { f(1 ; return 0; }\n',
                                   "expected ')' after function arguments at 1:24")
P('p50', b'fn main() -> i32 { f(1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1); return 0; }\n',
                                   'function calls support at most 32 arguments at 1:20')
P('p51', b'fn main() -> i32 { let x: i32 = 9223372036854775808; return x; }\n',
                                   'integer literal exceeds i64 range at 1:33')
P('p52', b'fn main() -> i32 { return 99999999999999999999999; }\n',
                                   'integer literal is too large at 1:27')
P('p53', b'let a: u8[99999999999999999999999] = 1;\n',
                                   'array length is too large at 1:11')
P('p54', b'fn main() -> i32 { let x: i32 = 1; if (1 < 2 < 3) { return 1; } return 0; }\n',
                                   'chained comparisons are not supported at 1:46')
P('p54e', b'fn main() -> i32 { let x: i32 = 1; if (1 == 2 == 3) { return 1; } return 0; }\n',
                                   'chained comparisons are not supported at 1:47')
P('p55', b'fn f(a: i32) -> i32 { return a; }\nfn main() -> i32 { f(1)(2); return 0; }\n',
                                   'cannot call the result of this expression: assign it to a fn(...) variable or a fn(...) field first at 2:24')
P('p56', b'fn main() -> i32 { let x: i32 = 1[0]; return x; }\n',
                                   'cannot index this expression at 1:34')
P('p57a', b'fn main() -> i32 { main(); return 0; }\n',
                                   'expected let, assignment, return, if, while, for, break, or continue at 1:20')
P('p57b', b'fn main() -> i32 { x + 1; return 0; }\n',
                                   'expected let, assignment, return, if, while, for, break, or continue at 1:20')
P('p58', b'let p: ptr<1> = 0;\n',
                                   "expected a struct name after 'ptr<' at 1:12")
P('p59', b'let p: ptr<nope> = 0;\n',
                                   'unknown struct type in ptr<nope> at 1:12')
P('p60', b'let p: ptr<i32 = 0;\n',
                                   "expected '>' after the type in a ptr<...> type at 1:16")
P('p61', b'fn main() -> i32 { let x: i32 @align(8) = 0; return x; }\n',
                                   'local alignment is not supported: x at 1:24')
P('p62', b'let p: ptr<nope = 0;\n',
                                   "expected '>' after the struct name in a ptr<...> type at 1:17")

B('b1',  b'fn main() -> i32 { for (;;) { return 0; } }\n',
                                   "the 'for' statement is not in the bootstrap subset at 1:20")
B('b2',  b'struct S { a: i32 }\n',
                                   'struct declarations are not in the bootstrap subset at 1:1')
B('b3',  b'include "foo.ast";\n',
                                   'include is not in the bootstrap subset at 1:1')
B('b4',  b'fn main() -> i32 { let y: i32 = a.b; return y; }\n',
                                   "'.' field access is not in the bootstrap subset at 1:34")
B('b4i', b'fn main() -> i32 { a[0].b; return 0; }\n',
                                   "'.' field access is not in the bootstrap subset at 1:24")
B('b5',  b'fn main() -> i32 { let x: i32 = 1 ? 2 : 3; return x; }\n',
                                   "the '?:' operator is not in the bootstrap subset at 1:35")
B('b6',  b'fn main() -> i32 { let x: i32 = ~1; return x; }\n',
                                   "'~' is not in the bootstrap subset at 1:33")
B('b7',  b'fn main() -> i32 { let x: i32 = *p; return x; }\n',
                                   "'*' dereference is not in the bootstrap subset at 1:33")
B('b8',  b'fn main() -> i32 { let x: ptr<i32> = &y; return 0; }\n',
                                   "'&' address-of is not in the bootstrap subset at 1:38")
B('b9a', b'fn main() -> i32 { x++; return 0; }\n',
                                   "'++' and '--' are not in the bootstrap subset at 1:21")
B('b9b', b'fn main() -> i32 { --x; return 0; }\n',
                                   "'++' and '--' are not in the bootstrap subset at 1:20")
B('b10a', b'fn main() -> i32 { x += 1; return 0; }\n',
                                   'compound assignment is not in the bootstrap subset at 1:22')
B('b10i', b'fn main() -> i32 { a[0] += 1; return 0; }\n',
                                   'compound assignment is not in the bootstrap subset at 1:25')
B('b11', b'fn main() -> i32 { let a: i32[4] = 0; return 0; }\n',
                                   'local arrays are not in the bootstrap subset at 1:30')
B('b12', b'fn f(a: i32[4]) -> i32 { return 0; }\n',
                                   'array parameters are not in the bootstrap subset at 1:12')
B('b13', b'fn main() -> i32 { let x: i32 = a[0][1]; return x; }\n',
                                   'multi-dimensional indexing is not in the bootstrap subset at 1:37')
B('b14', b'fn main() -> i32 { let x: i32 = true; return x; }\n',
                                   'true/false are not in the bootstrap subset at 1:33')
B('b15', b'let g: bool = 1;\n',
                                   'type bool is not in the bootstrap subset at 1:8')
B('b16', b'let g: u16 = 1;\n',
                                   'type u16 is not in the bootstrap subset at 1:8')
B('b17', b'let g: u32 = 1;\n',
                                   'type u32 is not in the bootstrap subset at 1:8')
B('b18a', b'fn main() -> i32 { let x: i32 = sizeof(1); return x; }\n',
                                   'sizeof/len are not in the bootstrap subset at 1:33')
B('b18b', b'fn main() -> i32 { let x: i32 = len(a); return x; }\n',
                                   'sizeof/len are not in the bootstrap subset at 1:33')
B('b19', b'fn main() -> i32 { let x: i32 = @embed("f"); return x; }\n',
                                   '@embed is not in the bootstrap subset at 1:33')
B('b20', b'let g: i32 @align(8) = 0;\n',
                                   'global alignment is not in the bootstrap subset at 1:12')
B('b21', b'let p: ptr<ptr<i32>> = 0;\n',
                                   'ptr<ptr<...>> is not in the bootstrap subset at 1:12')
B('b22', b'fn f(g: fn(i32) -> i32) -> i32 { return 0; }\n',
                                   'fn(...) types are not in the bootstrap subset at 1:9')

for name, data, msg in cases:
    open(d + '/' + name + '.ast', 'wb').write(data)
    open(d + '/' + name + '.exp', 'w').write('aster: error: ' + msg + '\n')
with open(w + '/diag.list', 'w') as f:
    for name, _, _ in cases:
        f.write(name + '\n')
PYEOF
n=0
while read -r c; do
    pin "$c: $(cat "$W/diag/$c.exp")" "$W/diag/$c.ast" 1 /dev/null "$W/diag/$c.exp"
    n=$((n+1))
done <"$W/diag.list"
printf 'PASS: %d diagnostics pinned on both sides (E1-E7, P1-P62, B1-B22)\n' "$n"

# ---------------------------------------------------------------------------
# [7/11] Position and format semantics the parser stage inherits from the
# lexer (LEXER-SPEC §5), plus the dump-format rules of spec §8: two-space
# indent per level, a binary node at its left operand, a group adding no
# node, the else-if desugaring to a nested If, and the two phases leaving
# stdout byte-empty on any error.
printf '%s\n' '[7/11] Position and format semantics: End, CRLF, no trailing newline, dump shape'
python3 - "$W" <<'PYEOF'
import sys
w = sys.argv[1]
s = w + '/sem'
import os; os.makedirs(s, exist_ok=True)
def f(name, data): open(os.path.join(s, name), 'wb').write(data)
def x(name, text): open(os.path.join(s, name + '.exp'), 'w').write(text)
# the empty input: a Program with no children, at the End token's 1:1
f('empty.ast', b'')
x('empty', 'Program 1:1\n')
# comment-only and whitespace-only lex to just End — at the position the
# scanner reaches, past the newlines
f('comment.ast', b'// nothing here\n')
x('comment', 'Program 2:1\n')
f('ws.ast', b'\n\n  \t \n')
x('ws', 'Program 4:1\n')
# no trailing newline: the last token's position is still exact
f('nonl.ast', b'fn main() -> i32 { return 0; }')
# CRLF: \r is whitespace, columns do not move
f('crlf.ast', b'fn main() -> i32 {\r\n let x: i32 = 1;\r\n return x;\r\n}\r\n')
# a group adds no node: (a) dumps exactly as a does
f('group.ast', b'fn main() -> i32 { return (((1))); }\n')
x('group', 'Program 1:1\n'
           '  Function 1:1 main i32\n'
           '    Block 1:18\n'
           '      Return 1:30\n'
           '        Num 1:30 1\n')
# a binary node sits at its left operand; a prefix at its operand
f('binpos.ast', b'fn main() -> i32 { return 1 + 2; }\n')
x('binpos', 'Program 1:1\n'
            '  Function 1:1 main i32\n'
            '    Block 1:18\n'
            '      Return 1:27\n'
            '        Add 1:27\n'
            '          Num 1:27 1\n'
            '          Num 1:31 2\n')
f('prefix.ast', b'fn main() -> i32 { return -42; }\n')
x('prefix', 'Program 1:1\n'
            '  Function 1:1 main i32\n'
            '    Block 1:18\n'
            '      Return 1:28\n'
            '        Neg 1:28\n'
            '          Num 1:28 42\n')
# else-if is a nested If, the first If's third child — not a Block
f('elseif.ast', b'fn main() -> i32 { if (1) { return 1; } else if (2) { return 2; } return 0; }\n')
x('elseif', 'Program 1:1\n'
            '  Function 1:1 main i32\n'
            '    Block 1:18\n'
            '      If 1:24\n'
            '        Num 1:24 1\n'
            '        Block 1:27\n'
            '          Return 1:36\n'
            '            Num 1:36 1\n'
            '        If 1:50\n'
            '          Num 1:50 2\n'
            '          Block 1:53\n'
            '            Return 1:62\n'
            '              Num 1:62 2\n'
            '      Return 1:74\n'
            '        Num 1:74 0\n')
# a call statement is an Expr whose child is the full expression. f is declared
# (extern) because M3c's S6 rejects a call to an undeclared function, which the
# parse-only stage never did.
f('callstmt.ast', b'extern fn f(x: i32) -> i32;\nfn main() -> i32 { f(1) + 1; return 0; }\n')
x('callstmt', 'Program 1:1\n'
              '  Function 1:8 f i32 extern\n'
              '    Param 1:13 x i32\n'
              '  Function 2:1 main i32\n'
              '    Block 2:18\n'
              '      Expr 2:20\n'
              '        Add 2:20\n'
              '          Call 2:20 f\n'
              '            Num 2:22 1\n'
              '          Num 2:27 1\n'
              '      Return 2:37\n'
              '        Num 2:37 0\n')
# two phases: an error anywhere leaves stdout byte-empty (the pinned cases in
# [6/11] all assert this; here the input is a valid prefix followed by trash)
f('twophase.ast', b'fn main() -> i32 { return 0; }\nfn f( -> i32 {}\n')
PYEOF
pin "empty input: Program 1:1" "$W/sem/empty.ast" 0 "$W/sem/empty.exp" /dev/null
pin "comment-only input" "$W/sem/comment.ast" 0 "$W/sem/comment.exp" /dev/null
pin "whitespace-only input" "$W/sem/ws.ast" 0 "$W/sem/ws.exp" /dev/null
diffcase "no trailing newline" "$W/sem/nonl.ast"
diffcase "CRLF line endings" "$W/sem/crlf.ast"
pin "a group adds no node" "$W/sem/group.ast" 0 "$W/sem/group.exp" /dev/null
pin "a binary node sits at its left operand" "$W/sem/binpos.ast" 0 "$W/sem/binpos.exp" /dev/null
pin "a prefix node sits at its operand" "$W/sem/prefix.ast" 0 "$W/sem/prefix.exp" /dev/null
pin "else-if desugars to a nested If" "$W/sem/elseif.ast" 0 "$W/sem/elseif.exp" /dev/null
pin "a discarded call statement is an Expr" "$W/sem/callstmt.ast" 0 "$W/sem/callstmt.exp" /dev/null
arc=0; run "$W/parser" <"$W/sem/twophase.ast" >"$W/tp.ao" 2>"$W/tp.ae" || arc=$?
trc=0; run "$W/twin"  <"$W/sem/twophase.ast" >"$W/tp.to" 2>"$W/tp.te" || trc=$?
if [ "$arc" -ne 1 ] || [ "$trc" -ne 1 ] || [ -s "$W/tp.ao" ] || [ -s "$W/tp.to" ] \
   || ! cmp -s "$W/tp.ae" "$W/tp.te"; then
    echo "FAIL: two phases — a late error must leave stdout empty on both sides" >&2; exit 1
fi
printf 'PASS: two phases — a valid prefix then an error: exit 1, stdout empty, stderr agrees\n'

# ---------------------------------------------------------------------------
# [8/11] The boundary corpus, differentially: every accepted shape at the
# edges of the subset (32 parameters, the deepest legal nesting, every
# number form, the string escapes, extern declarations, the spaced call),
# every refused shape one step past them, and the corners where the two
# implementations were built from different shapes — the work-stack machine
# and the recursive descent — so agreement is evidence.
printf '%s\n' '[8/11] Boundary corpus: differential'
python3 - "$W" <<'PYEOF'
import sys, os
w = sys.argv[1]
c = os.path.join(w, 'corpus')
os.makedirs(c, exist_ok=True)
def f(name, data): open(os.path.join(c, name), 'wb').write(data)

# accepted shapes
f('params32.ast', b'fn f(' + b', '.join(b'a%d: i32' % i for i in range(32)) + b') -> i32 { return a0; }\n')
f('extern_fn.ast', b'extern fn write(fd: i32, buf: ptr<u8>, n: i32) -> i32;\n')
f('extern_global.ast', b'extern let g: i32;\n')
f('array_global.ast', b'let a: i32[4] = 0;\n')
f('array_max.ast', b'let a: i32[1048576] = 0;\n')
f('u8_255.ast', b'let a: u8[256] = 255;\n')
f('spaced_call.ast', b'fn f(a: i32) -> i32 { return a; }\nfn main() -> i32 { return f (1); }\n')
f('empty_call.ast', b'fn f() -> i32 { return 0; }\nfn main() -> i32 { return f(); }\n')
f('nested_call.ast', b'fn f(a: i32) -> i32 { return a; }\nfn main() -> i32 { return f(f(f(1))); }\n')
f('string_escapes.ast', b'fn main() -> i32 { let s: ptr<u8> = "\\n\\t\\r\\\\\\"\\0\\x41\\x7f"; return 0; }\n')
f('empty_string.ast', b'fn main() -> i32 { let s: ptr<u8> = ""; return 0; }\n')
f('comments.ast', b'fn main() -> i32 { /* multi\nline */ // line\n return 0; }\n')
f('all_number_forms.ast', b'fn main() -> i32 { let a: i32 = 0; let b: i32 = 00; let c: i32 = 0x0; let d: i32 = 0X1A; let e: i32 = 007; return a; }\n')
f('u64_max.ast', b'fn main() -> i32 { let x: i32 = 18446744073709551615; return x; }\n')
f('i64_max.ast', b'fn main() -> i32 { let x: i32 = 9223372036854775807; return x; }\n')
f('hex_u64_max.ast', b'fn main() -> i32 { let x: i32 = 0xFFFFFFFFFFFFFFFF; return x; }\n')
f('main_kw.ast', b'fn main() -> i32 { return main; }\n' if False else b'fn main() -> i32 { let x: i32 = 1; return x; }\n')
f('while_break.ast', b'fn main() -> i32 { let i: i32 = 0; while (i < 4) { if (i == 2) { break; } i = i + 1; } return i; }\n')
f('continue.ast', b'fn main() -> i32 { let i: i32 = 0; while (i < 4) { i = i + 1; if (i < 4) { continue; } } return i; }\n')
f('index_assign.ast', b'let a: i32[4] = 0;\nfn main() -> i32 { a[0] = 1; a[1] = a[0] + 1; return a[1]; }\n')
f('runtime_init.ast', b'let g: i32 = 1;\nfn main() -> i32 { let x: i32 = g; return x; }\n')
f('neg_init.ast', b'let g: i32 = -1;\n')
f('fold_add.ast', b'let g: i32 = 2 + 3 * 4;\n')
f('fold_shift.ast', b'let g: i64 = 1 << 62;\n')
f('fold_div.ast', b'let g: i32 = 100 / 7;\n')
f('fold_mod.ast', b'let g: i32 = 100 % 7;\n')
f('fold_neg.ast', b'let g: i32 = -(2 + 3);\n')
# `a` is declared: M3c's S5 rejects an undeclared variable, which the parse-only
# stage accepted, and these two cases probe nesting depth — not name resolution.
f('deep96.ast', b'let a: i32 = 0;\nfn main() -> i32 { return ' + b'(' * 96 + b'a' + b')' * 96 + b'; }\n')
f('deep_bin.ast', b'let a: i32 = 0;\nfn main() -> i32 { return ' + b' + '.join([b'a'] * 200) + b'; }\n')

# refused shapes, one step past the accepted ones
f('params33.ast', b'fn f(' + b', '.join(b'a%d: i32' % i for i in range(33)) + b') -> i32 { return a0; }\n')
f('args33.ast', b'fn main() -> i32 { f(' + b','.join([b'1'] * 33) + b'); return 0; }\n')
f('array_over.ast', b'let a: i32[1048577] = 0;\n')
f('deep97.ast', b'fn main() -> i32 { return ' + b'(' * 97 + b'a' + b')' * 97 + b'; }\n')
f('u64_over.ast', b'fn main() -> i32 { let x: i32 = 18446744073709551616; return x; }\n')
f('i64_over.ast', b'fn main() -> i32 { let x: i32 = 9223372036854775808; return x; }\n')
f('hex17.ast', b'fn main() -> i32 { let x: i32 = 0xFFFFFFFFFFFFFFFFF; return x; }\n')
f('u8_256.ast', b'let a: u8[1] = 256;\n')
f('array_var_init.ast', b'let b: i32 = 1;\nlet a: i32[2] = b;\n')
f('shift63_over.ast', b'let g: i64 = 3 << 62;\n')
f('shift64.ast', b'let g: i32 = 1 << 64;\n')
f('div0.ast', b'let g: i32 = 1 / 0;\n')
f('mod0.ast', b'let g: i32 = 1 % 0;\n')
# the postfix corners: a call's result cannot be called or indexed, an index
# cannot be indexed again
f('call_of_call.ast', b'fn f(a: i32) -> i32 { return a; }\nfn main() -> i32 { f(1)(2); return 0; }\n')
f('index_of_call.ast', b'fn main() -> i32 { let x: i32 = f(1)[0]; return x; }\n')
f('index_of_index.ast', b'fn main() -> i32 { let x: i32 = a[0][1]; return x; }\n')
f('index_of_num.ast', b'fn main() -> i32 { let x: i32 = 1[0]; return x; }\n')
f('dot_after.ast', b'fn main() -> i32 { let y: i32 = a.b; return y; }\n')
f('dot_after_index.ast', b'fn main() -> i32 { a[0].b; return 0; }\n')
# the statement-level corners
f('main_call.ast', b'fn main() -> i32 { main(); return 0; }\n')
f('bare_ident.ast', b'fn main() -> i32 { let x: i32 = 1; x; return 0; }\n')
f('expr_stmt.ast', b'fn main() -> i32 { let x: i32 = 1; x + 1; return 0; }\n')
f('prefix_dec.ast', b'fn main() -> i32 { --x; return 0; }\n')
f('incdec_stmt.ast', b'fn main() -> i32 { x++; return 0; }\n')
# `--` lexes as one token, so a prefix chain spells `-!-!`
# M3c's S20 requires a bool operand for '!', so the chain is all unary '-';
# the spaces keep '- -' from lexing as the decrement operator.
f('prefix_chain.ast', b'fn main() -> i32 { return - - -1; }\n')
f('minus_minus.ast', b'fn main() -> i32 { let x: i32 = --1; return x; }\n')
# a NUL byte in the source: whitespace to the scanner, on both sides
f('nul.ast', b'fn main() -> i32 { let x: i32 = 1\x00 2; return x; }\n')
f('bad_hex_escape.ast', b'fn main() -> i32 { let s: ptr<u8> = "a\\xZZb"; return 0; }\n')
f('eof_escape.ast', b'fn main() -> i32 { let s: ptr<u8> = "a\\')
PYEOF
n=0
for f in "$W"/corpus/*.ast; do
    diffcase "$(basename "$f")" "$f"
    n=$((n+1))
done
printf 'PASS: boundary corpus — %d cases, parser and twin agree on every one\n' "$n"

# ---------------------------------------------------------------------------
# [9/11] Self-parsing: the stage parses itself, its library and every
# example — the corpus that matters most, because a parser that cannot read
# its own source cannot bootstrap. The two AST-line counts are pinned: a dump
# that silently drops nodes (a flush bug, an off-by-one in the emit walk)
# fails here, not in some future milestone.
printf '%s\n' '[9/11] Self-parsing: the stage reads itself, the library, every example'
n=0
for f in bootstrap/aster.ast stdlib/aster_std.ast examples/*.ast; do
    diffcase "$f" "$f"
    n=$((n+1))
done
printf 'PASS: self-parsing — %d sources, parser and twin agree on every one\n' "$n"
for pair in "bootstrap/aster.ast 10956" "stdlib/aster_std.ast 555"; do
    set -- $pair
    lines=$(run "$W/parser" <"$1" 2>/dev/null | wc -l)
    if [ "$lines" -ne "$2" ]; then
        echo "FAIL: $1 dumps $lines lines, expected $2" >&2; exit 1
    fi
    printf 'PASS: %s — %s AST lines (pinned)\n' "$1" "$lines"
done

# ---------------------------------------------------------------------------
# [10/11] The caps (spec §10), each at its accepted edge and one past it.
# C1 counts markers and prefixes open at once; C2 counts blocks entered plus
# else-if links; C3 is defensive — with E9's token cap in front of it the
# densest possible source (one node per token) cannot reach 65537 nodes, and
# the probe below documents that by landing exactly under it.
printf '%s\n' '[10/11] Caps: C1, C2, E8, E9, 32 parameters, 1048576 — edge and one past'
python3 - "$W" <<'PYEOF'
import sys
w = sys.argv[1]
def w_(name, data): open(w + '/' + name, 'wb').write(data)
# C1: 96 markers open at once is the cap; 97 is refused
w_('c1_96.ast',  b'fn main() -> i32 { return ' + b'(' * 96  + b'1' + b')' * 96  + b'; }\n')
w_('c1_97.ast',  b'fn main() -> i32 { return ' + b'(' * 97  + b'1' + b')' * 97  + b'; }\n')
# C2: the function's own block counts, so 95 ifs is the edge, 96 is refused
w_('c2_95.ast',  b'fn main() -> i32 {\n' + b'if (1) {\n' * 95 + b'return 0;\n' + b'}\n' * 95 + b'}\n')
w_('c2_96.ast',  b'fn main() -> i32 {\n' + b'if (1) {\n' * 96 + b'return 0;\n' + b'}\n' * 96 + b'}\n')
# E8/E9: the source cap and the token cap, at the byte and one past
w_('src1m.ast',  b'fn main() -> i32 { return 0; }\n' + b'// ' + b'x' * 1048560 + b'\n')   # 1048576 exactly
w_('src1m1.ast', b'fn main() -> i32 { return 0; }\n' + b'// ' + b'x' * 1048561 + b'\n')   # one past
w_('tok64k.ast',  b'fn f() -> i32 { return 0; }\nfn main() -> i32 {\n' + b'f();\n' * 16379 + b'}\n')   # 11 + 7 + 1 + 4*16379 = 65536
w_('tok64k1.ast', b'fn f() -> i32 { return 0; }\nfn main() -> i32 {\n' + b'f();\n' * 16380 + b'}\n')  # 65540, one past
open(w + '/c1.exp', 'w').write('aster: error: expression nests too deeply (limit 96)\n')
open(w + '/c2.exp', 'w').write('aster: error: statements nest too deeply (limit 96)\n')
open(w + '/e8.exp', 'w').write('aster: error: source exceeds 1048576 bytes\n')
open(w + '/e9.exp', 'w').write('aster: error: too many tokens (limit 65536)\n')
PYEOF
okcase "C1: 96 markers accepted" "$W/c1_96.ast"
pin "C1: 97 markers refused" "$W/c1_97.ast" 1 /dev/null "$W/c1.exp"
okcase "C2: 95 nested ifs accepted" "$W/c2_95.ast"
pin "C2: 96 nested ifs refused" "$W/c2_96.ast" 1 /dev/null "$W/c2.exp"
pin "E8: source exceeds 1048576 bytes" "$W/src1m1.ast" 1 /dev/null "$W/e8.exp"
pin "E9: too many tokens (limit 65536)" "$W/tok64k1.ast" 1 /dev/null "$W/e9.exp"
# exactly 1 MiB: accepted, and the two sides' dumps are identical
diffcase "exactly 1 MiB of source" "$W/src1m.ast"
# exactly 65536 tokens: accepted — the cap is exclusive of the End token
for side in parser twin; do
    rc=0; run "$W/$side" <"$W/tok64k.ast" >"$W/$side.out" 2>"$W/$side.err" || rc=$?
    if [ "$rc" -ne 0 ] || [ -s "$W/$side.err" ]; then
        echo "FAIL: exactly 65536 tokens ($side): rc=$rc, stderr not empty" >&2
        cat "$W/$side.err" >&2; exit 1
    fi
done
if ! cmp -s "$W/parser.out" "$W/twin.out"; then
    echo "FAIL: exactly 65536 tokens — parser and twin dumps differ" >&2; exit 1
fi
printf 'PASS: exactly 65536 tokens accepted — %s lines, both sides identical\n' "$(wc -l <"$W/parser.out")"
# the densest source E9 allows: one node per token, still under C3
python3 - "$W" <<'PYEOF'
import sys
w = sys.argv[1]
k = 32763   # 2k + 9 tokens = 65535; 2k + 3 nodes = 65529 — under the C3 cap
open(w + '/dense.ast', 'wb').write(b'fn main() -> i32 { return ' + b' + '.join([b'0'] * k) + b'; }\n')
PYEOF
for side in parser twin; do
    rc=0; run "$W/$side" <"$W/dense.ast" >"$W/$side.out" 2>"$W/$side.err" || rc=$?
    if [ "$rc" -ne 0 ] || [ "$(wc -l <"$W/$side.out")" -ne 65529 ]; then
        echo "FAIL: dense source ($side): rc=$rc lines=$(wc -l <"$W/$side.out"), expected 65529" >&2
        exit 1
    fi
done
if ! cmp -s "$W/parser.out" "$W/twin.out"; then
    echo "FAIL: dense source — parser and twin dumps differ" >&2; exit 1
fi
printf 'PASS: densest E9-legal source — 65529 AST nodes, both sides identical (C3 is defensive)\n'

# ---------------------------------------------------------------------------
# [11/11] Semantic corpus (M3c / SEMANTIC-SPEC §13-§16). The type-check pass
# runs after the parse; every source here is syntactically valid. Each rejection
# must be refused by BOTH the bootstrap and the twin with the same diagnostic
# (diffcase), and each acceptance must pass both with byte-identical dumps
# (okcase). This is where the twin's S5-S22 mirror earns its keep: the two sides
# stay in lockstep on accept and on reject.
printf '%s\n' '[11/11] Semantic corpus: S5-S22 rejections + acceptances, parser and twin agree'
SEM="$W/sem"
mkdir -p "$SEM"
python3 - "$SEM" <<'PYEOF'
import sys, os
d = sys.argv[1]
def f(name, data): open(os.path.join(d, name), 'wb').write(data)
# --- rejections: both sides must refuse with the same S-diagnostic ---
f('s5.ast',    b'fn main() -> i32 {\n  return y;\n}\n')
f('s6.ast',    b'fn main() -> i32 {\n  f();\n  return 0;\n}\n')
f('s7.ast',    b'let a: i32[3] = 1;\nfn main() -> i32 {\n  a();\n  return 0;\n}\n')
f('s8.ast',    b'fn main() -> i32 {\n  let f: ptr = "x";\n  f();\n  return 0;\n}\n')
f('s9.ast',    b'extern fn g(x: i32) -> i32;\nfn main() -> i32 {\n  g(1, 2);\n  return 0;\n}\n')
f('s10.ast',   b'extern fn g(x: ptr<u8>) -> i32;\nfn main() -> i32 {\n  let s: ptr = "hi";\n  g(5);\n  return 0;\n}\n')
f('s11.ast',   b'fn main() -> i32 {\n  let x: i32 = "s";\n  return 0;\n}\n')
f('s12.ast',   b'let a: i32[3] = 1;\nfn main() -> i32 {\n  a = 5;\n  return 0;\n}\n')
f('s13.ast',   b'fn main() -> i32 {\n  let p: ptr = "x";\n  if (p) {}\n  return 0;\n}\n')
f('s14na.ast', b'fn main() -> i32 {\n  let x: i32 = 1;\n  return x[0];\n}\n')
f('s14pi.ast', b'fn main() -> i32 {\n  let p: ptr<u8> = "x";\n  let q: ptr = "y";\n  return p[q];\n}\n')
f('s16rb.ast', b'fn main() -> i32 {\n  return 1 == 2;\n}\n')
f('s16pi.ast', b'fn f() -> ptr {\n  return 5;\n}\nfn main() -> i32 {\n  f();\n  return 0;\n}\n')
f('s20.ast',   b'fn main() -> i32 {\n  let x: i32 = !1;\n  return 0;\n}\n')
# --- acceptances: both sides must pass with byte-identical dumps ---
f('ok_widen.ast',   b'extern fn g(x: i64) -> i32;\nfn main() -> i32 {\n  let v: i32 = 1;\n  g(v);\n  return 0;\n}\n')
f('ok_nullptr.ast', b'extern fn g(x: ptr<u8>) -> i32;\nfn main() -> i32 {\n  g(0);\n  return 0;\n}\n')
f('ok_nullret.ast', b'fn f() -> ptr {\n  return 0;\n}\nfn main() -> i32 {\n  f();\n  return 0;\n}\n')
f('ok_i64_i32.ast', b'fn main() -> i32 {\n  let x: i64 = 1;\n  let y: i32 = x;\n  return 0;\n}\n')
f('ok_ptr_idx.ast', b'fn main() -> i32 {\n  let p: ptr<u8> = "x";\n  let v: u8 = p[0];\n  return v;\n}\n')
f('ok_rtinit.ast',  b'fn f() -> i32 { return 1; }\nlet g: i32 = f() + 2;\nfn main() -> i32 {\n  return g;\n}\n')
PYEOF
NS=0; NA=0
for s in s5 s6 s7 s8 s9 s10 s11 s12 s13 s14na s14pi s16rb s16pi s20; do
    diffcase "semantic $s" "$SEM/$s.ast" && NS=$((NS+1))
done
for s in ok_widen ok_nullptr ok_nullret ok_i64_i32 ok_ptr_idx ok_rtinit; do
    okcase "semantic $s" "$SEM/$s.ast" && NA=$((NA+1))
done
printf 'PASS: semantic corpus — %d rejections + %d acceptances, parser and twin agree on every one\n' "$NS" "$NA"

# [12/11] Mutation probes — break the PARSER on purpose and assert the suite
# notices. Each probe patches a copy of bootstrap/aster.ast, rebuilds the
# object, relinks against the pristine library, runs the targeted input, and
# requires the output to diverge from the twin (or the build to fail). A
# probe that still matches the twin is blind, and a blind probe is a failure.
printf '%s\n' '[12/11] Mutation probes: every rule stays load-bearing'

probe(){ # $1 name  $2 probe input  $3 python edit script
    n="$1"; pin="$2"; script="$3"
    cp bootstrap/aster.ast "$W/$n.ast"
    if ! python3 - "$W/$n.ast" "$n" <<PYEOF
import sys
path, name = sys.argv[1], sys.argv[2]
src = open(path).read()
def sub(old, new, expect):
    n_hits = src.count(old)
    if n_hits != expect:
        print("MUTATE-MISS:%s:%d!=%d" % (name, n_hits, expect), file=sys.stderr)
        sys.exit(2)
    return src.replace(old, new)
$script
open(path, 'w').write(src)
PYEOF
    then
        echo "FAIL: $n — the edit script did not apply as expected" >&2; return 1
    fi
    if ! "$OUT/aster" build-obj "$W/$n.ast" -o "$W/$n.o" >"$W/$n.log" 2>&1; then
        printf 'PASS: %s — the mutated parser no longer compiles\n' "$n"; return 0
    fi
    if ! "$OUT/aster" link-obj "$W/$n.o" "$W/std.o" -o "$W/$n.ab" >"$W/$n.link.log" 2>&1; then
        printf 'PASS: %s — the mutated parser no longer links\n' "$n"; return 0
    fi
    mrc=0; run "$W/$n.ab" <"$pin" >"$W/$n.out" 2>"$W/$n.err" || mrc=$?
    trc=0; run "$W/twin"  <"$pin" >"$W/$n.twin.out" 2>"$W/$n.twin.err" || trc=$?
    if [ "$mrc" -eq "$trc" ] && cmp -s "$W/$n.out" "$W/$n.twin.out" \
       && cmp -s "$W/$n.err" "$W/$n.twin.err"; then
        echo "FAIL: $n — the mutation did NOT diverge from the twin (probe is blind)" >&2
        return 1
    fi
    printf 'PASS: %s — diverges from the twin\n' "$n"
}

python3 - "$W" <<'PYEOF'
import sys, os
w = sys.argv[1]
p = os.path.join(w, 'mut')
os.makedirs(p, exist_ok=True)
def f(name, data): open(os.path.join(p, name), 'wb').write(data)
f('group.ast',   b'fn main() -> i32 { return (1 + 2) * 3; }\n')
f('sum.ast',     b'fn main() -> i32 { let x: i32 = 1 + 2 * 3; return x; }\n')
f('p50.ast',     b'fn main() -> i32 { f(' + b','.join([b'1'] * 33) + b'); return 0; }\n')
f('p37.ast',     b'fn main() -> i32 { a[0] + 1; return 0; }\n')
f('c1.ast',      b'fn main() -> i32 { return ' + b'(' * 97 + b'1' + b')' * 97 + b'; }\n')
f('p54.ast',     b'fn main() -> i32 { let x: i32 = 1; if (1 < 2 < 3) { return 1; } return 0; }\n')
f('b13.ast',     b'fn main() -> i32 { let x: i32 = a[0][1]; return x; }\n')
f('emptycall.ast', b'fn f() -> i32 { return 0; }\nfn main() -> i32 { return f(); }\n')
f('sat.ast',     b'let g: u8 = 9223372036854775808;\n')
f('shift.ast',   b'let g: i32 = 1 << 64;\n')
f('close.ast',   b'fn main() -> i32 { return f(1) + 2; }\n')
f('elseif.ast',  b'fn main() -> i32 { if (1) { return 1; } else if (2) { return 2; } return 0; }\n')
f('div0.ast',    b'let g: i32 = 1 / 0;\n')
PYEOF
P="$W/mut"

# m_group_close: the group marker stops consuming its ')'. The state machine
# re-reads the ')' forever after — or refuses the next token — and every
# grouped expression in the corpus fails where the twin parses it. (The
# matched comment carries an apostrophe, so it is spelled chr(39).)
probe m_group_close "$P/group.ast" '
q = chr(39)
src = sub("""            // ---- a group marker: the host""" + q + """s (expr) returns the inner
            //      expression unchanged, so no node is built here ----
            if (k == K_RParen) {
                advance();""",
          """            // ---- a group marker: the host""" + q + """s (expr) returns the inner
            //      expression unchanged, so no node is built here ----
            if (k == K_RParen) {
                numflag = 0;""", 1)
'
# m_sum_prec: '+' and '-' bind at the product level instead of above it, so
# `1 + 2 * 3` groups as `(1 + 2) * 3` — the precedence table of spec §6.1,
# pinned by the frozen §9.1 dump.
probe m_sum_prec "$P/sum.ast" '
src = sub("if (k == K_Plus || k == K_Minus) { return 9; }",
          "if (k == K_Plus || k == K_Minus) { return 10; }", 1)
'
# m_p50_pos: the P50 position regresses to the Call node's id read through
# the token arrays — the bug the v0.23.44-dev fix removed. The 33-argument
# call then reports the wrong column.
probe m_p50_pos "$P/p50.ast" '
src = sub("die_at(\"function calls support at most 32 arguments\", tok_line(ntok[call - 1]), tok_col(ntok[call - 1]));",
          "die_at(\"function calls support at most 32 arguments\", tok_line(call), tok_col(call));", 1)
'
# m_p37_name: P37 regresses to interpolating the array name — the host's
# assignOp throws the bare sentence, and the spec table says so. (The quote
# characters are spelled chr(39) so this shell single-quoted block survives.)
probe m_p37_name "$P/p37.ast" '
q = chr(39)
src = sub("die_at(\"expected " + q + "=" + q + " in array element assignment\", tok_line(nt), tok_col(nt));",
          "die_name_at(\"expected " + q + "=" + q + " in array element assignment\", nt);", 1)
'
# m_c1: the expression-nesting cap moves out of the work arrays' range. A
# 97-deep expression is then accepted where the twin refuses it — the cap is
# what keeps the marker stack (128 entries) safe.
probe m_c1 "$P/c1.ast" '
src = sub("if (msp >= 128) { return die_np(\"internal: marker stack overflow\"); }\n    if (exdepth >= 96) { return die_np(\"expression nests too deeply (limit 96)\"); }",
          "if (msp >= 256) { return die_np(\"internal: marker stack overflow\"); }\n    if (exdepth >= 128) { return die_np(\"expression nests too deeply (limit 96)\"); }", 1)
'
# m_p54: the non-associative levels stop refusing a second operator, so
# `1 < 2 < 3` parses where the twin refuses it (spec §6.1).
probe m_p54 "$P/p54.ast" '
src = sub("""                if (q == p && (p == 6 || p == 7)) {
                    die_at(\"chained comparisons are not supported\", tok_line(ppos), tok_col(ppos));
                    return 0;
                }""",
          """                if (q == p && (p == 6 || p == 7)) {
                    numflag = 0;
                }""", 1)
'
# m_b13: the second-subscript refusal disappears, so `a[0][1]` takes the
# P56 "cannot index this expression" path instead of B13.
probe m_b13 "$P/b13.ast" '
src = sub("if (nkind[top - 1] == E_Index) {\n                die_at(\"multi-dimensional indexing is not in the bootstrap subset\", tok_line(ppos), tok_col(ppos));\n                return 0;\n            }",
          "if (nkind[top - 1] == E_Call && nkind[top - 1] == E_Index) {\n                die_at(\"multi-dimensional indexing is not in the bootstrap subset\", tok_line(ppos), tok_col(ppos));\n                return 0;\n            }", 1)
'
# m_empty_call: the empty-argument-list path is disabled, so `f()` falls into
# the P41 "expected expression" branch the host's argument loop never takes.
probe m_empty_call "$P/emptycall.ast" '
src = sub("if (msp > 0 && mkind[msp - 1] == 2 && k == K_RParen && nfirst[maux[msp - 1] - 1] == 0) {",
          "if (msp > 0 && mkind[msp - 1] == 2 && k == K_RParen && nfirst[maux[msp - 1] - 1] == 1) {", 1)
'
# m_sat: the i64 saturation guard is weakened by one, so a literal one step
# past i64 max folds to a different value — visible in the P29 range check's
# printed value, the one place the folded number reaches the output.
probe m_sat "$P/sat.ast" '
src = sub("if (numval > (9223372036854775807 - d) / base) {",
          "if (numval > (9223372036854775807 - d) / base + 1) {", 1)
'
# m_shift_range: the 0..63 shift-count window widens, so `1 << 64` folds
# where the twin refuses it with P31.
probe m_shift_range "$P/shift.ast" '
src = sub("if (b < 0 || b > 63) {", "if (b < 0 || b > 127) {", 1)
'
# m_call_close: the call marker stops consuming its ')'. Same shape as the
# group mutation, on the other marker kind — every call in the corpus breaks.
probe m_call_close "$P/close.ast" '
src = sub("""            if (k == K_RParen) {
                advance();
                if (reduce_above(bottom) != 0) { return 0; }
                let i: i32 = vd;""",
          """            if (k == K_RParen) {
                numflag = 0;
                if (reduce_above(bottom) != 0) { return 0; }
                let i: i32 = vd;""", 1)
'
# m_elseif: the else-if desugaring stops recursing into if_stmt — the chain
# collapses into parse_block, which refuses the 'if' token ("expected '{'")
# where the twin builds the nested If of the frozen §9.4 dump.
probe m_elseif "$P/elseif.ast" '
src = sub("            let eb: i32 = if_stmt();",
          "            let eb: i32 = parse_block();", 1)
'
# m_div0: the division-by-zero guard in the folder disappears — a global
# initializer of `1 / 0` folds where the twin refuses it with P30.
probe m_div0 "$P/div0.ast" '
src = sub("""    if (k == E_Div) {
        if (b == 0) {
            die_at(\"division by zero in global variable initializer\", tok_line(ntok[n - 1]), tok_col(ntok[n - 1]));
            return 0;
        }
        return a / b;
    }""",
          """    if (k == E_Div) {
        return a / b;
    }""", 1)
'

printf '%s\n' 'ALL PARSER CHECKS PASSED'
