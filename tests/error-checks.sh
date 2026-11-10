#!/bin/sh
set -eu
CXX=${CXX:-g++}
$CXX -std=c++17 -O2 -Wall -Wextra -pedantic src/aster.cpp -o aster
check_error() {
  source=$1
  expected=$2
  output=$(./aster build-elf "$source" -o tmp-error 2>&1 && { echo "expected compiler failure for $source"; exit 1; } || true)
  printf '%s\n' "$output" | grep -F "$expected" >/dev/null || { echo "wrong diagnostic for $source: $output"; exit 1; }
  echo "PASS: diagnostic $source"
}
cat > tmp-unknown.ast <<'AST'
fn main() -> i32 { return missing; }
AST
cat > tmp-duplicate.ast <<'AST'
fn main() -> i32 { let x: i32 = 1; let x: i32 = 2; return x; }
AST
cat > tmp-fallthrough.ast <<'AST'
fn main() -> i32 { let x: i32 = 1; }
AST
check_error tmp-unknown.ast 'unknown variable: missing'
check_error tmp-duplicate.ast 'duplicate variable in scope: x'
check_error tmp-fallthrough.ast 'main may fall through without returning i32'
cat > tmp-break-outside.ast <<'AST'
fn main() -> i32 { break; return 0; }
AST
check_error tmp-break-outside.ast 'break used outside a loop'
cat > tmp-continue-outside.ast <<'AST'
fn main() -> i32 { continue; return 0; }
AST
check_error tmp-continue-outside.ast 'continue used outside a loop'
cat > tmp-wrong-arity.ast <<'AST'
fn main() -> i32 { return add(1); }
fn add(a: i32, b: i32) -> i32 { return a + b; }
AST
check_error tmp-wrong-arity.ast 'wrong argument count calling add: expected 2, got 1'
cat > tmp-undeclared-call.ast <<'AST'
fn main() -> i32 { return missing(1); }
AST
check_error tmp-undeclared-call.ast 'call to undeclared function: missing'
# v0.23.77-dev: a misspelt callee gets a hint, and an unknown one does not.
# The message keeps its exact prefix, so every older grep still matches.
cat > tmp-typo-call.ast <<'AST'
fn print(x: i32) -> i32 { return x; }
fn main() -> i32 { return prnt(1); }
AST
check_error tmp-typo-call.ast "did you mean 'print'?"
# v0.23.77-dev: the same hint for a variable, from every live scope.
cat > tmp-typo-var.ast <<'AST'
fn main() -> i32 {
    let counter: i32 = 1;
    return cuonter;
}
AST
check_error tmp-typo-var.ast "did you mean 'counter'?"
cat > tmp-far-var.ast <<'AST'
fn main() -> i32 { return zzzz; }
AST
if ./aster build-elf tmp-far-var.ast -o tmp-nohint2 >/dev/null 2>tmp-nohint2.err; then :; fi
if grep -qF 'did you mean' tmp-nohint2.err; then
    echo 'FAIL: an unknown variable with nothing close must not get a hint' >&2; exit 1
fi
cat > tmp-prefix-call.ast <<'AST'
fn parse_thing(x: i32) -> i32 { return x; }
fn main() -> i32 { return parse(1); }
AST
check_error tmp-prefix-call.ast "did you mean 'parse_thing'?"
if ./aster build-elf tmp-undeclared-call.ast -o tmp-nohint >/dev/null 2>tmp-nohint.err; then :; fi
if grep -qF 'did you mean' tmp-nohint.err; then
    echo 'FAIL: a name nothing is close to must not get a hint' >&2; exit 1
fi
cat > tmp-duplicate-param.ast <<'AST'
fn main() -> i32 { return add(1, 2); }
fn add(a: i32, a: i32) -> i32 { return a; }
AST
check_error tmp-duplicate-param.ast 'duplicate parameter name in function add: a'
cat > tmp-huge-literal.ast <<'AST'
fn main() -> i32 { return 999999999999999999999999999999999999999999999999999999999999; }
AST
check_error tmp-huge-literal.ast 'integer literal is too large at 1:27'
cat > tmp-huge-array.ast <<'AST'
let buf: i32[999999999999999999999999999999999999999999999999999999999999] = 0;
fn main() -> i32 { return 0; }
AST
check_error tmp-huge-array.ast 'array length is too large at 1:14'
cat > tmp-huge-align.ast <<'AST'
let value: i32 @align(999999999999999999999999999999999999999999999999999999999999) = 0;
fn main() -> i32 { return value; }
AST
check_error tmp-huge-align.ast 'alignment value is too large at 1:23'
rm -f tmp-unknown.ast tmp-duplicate.ast tmp-fallthrough.ast tmp-break-outside.ast tmp-continue-outside.ast tmp-wrong-arity.ast tmp-undeclared-call.ast tmp-duplicate-param.ast tmp-huge-literal.ast tmp-huge-array.ast tmp-huge-align.ast tmp-error
