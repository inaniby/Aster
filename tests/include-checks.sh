#!/bin/sh
# `include` checks (P3.4).
#
# `include "path";` brings another file's declarations into this one. Before it
# existed, a multi-file program shared a signature by *retyping* it: you wrote
# `extern fn add2(n: i32) -> i32;` in main.ast and `fn add2(n: i32) -> i32` in
# defs.ast, and nothing in the toolchain ever compared the two — get the arity
# wrong and the linker is silent, because it matches by name. That is the class
# of bug this suite exists to make impossible: what crosses an include is the
# signature read out of the file that holds the body, so it cannot drift.
#
# What that implies, and what is checked here:
#
#   1. DECLARATIONS ONLY. A body and an initializer stay in the file that owns
#      them. The proof is not "the build succeeded" but byte-identity: an object
#      built from a file that includes defs.ast must be byte-identical to one
#      built from a file that hand-writes the same two `extern` lines.
#   2. THE PATH IS RELATIVE TO THE FILE THAT WROTE IT (C's #include rule), not
#      to the working directory — with --include-dir overriding, and an absolute
#      path ignoring both.
#   3. A CYCLE IS AN ERROR THAT NAMES THE CHAIN, and including the same file
#      twice is a no-op, not an error.
#   4. A DEFINITION IN THIS FILE SUPERSEDES AN INCLUDED DECLARATION, which is
#      what makes "include the header, then define the functions" legal.
#   5. -g IS NOT MISLED: an included file contributes no code, so no row of the
#      line table may ever name it.
#   6. COMPILER MUTATIONS, each a way to get one of the above subtly wrong.
set -eu
cd "$(dirname "$0")/.."
CXX=${CXX:-g++}
OUT=${OUT:-tmp-include-checks}
rm -rf "$OUT"; mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT HUP INT TERM

$CXX -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"
ASTER="$OUT/aster"
# Absolute forms, for the two checks that build from a different working directory.
HERE=$(pwd)
fail() { echo "FAIL: $1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Source guards: the syntax and the three rules it rests on
# ---------------------------------------------------------------------------
grep -q 'Include, *// v0.23.13-dev' src/aster.cpp \
    || fail 'the `include` keyword is gone from the token set'
grep -qF 'if(eat(TK::Include)){includeDirective();continue;}' src/aster.cpp \
    || fail '`include` is no longer handled at the top level'
grep -qF 'f.external=true;f.fromInclude=true;f.body.clear();' src/aster.cpp \
    || fail 'an included function is no longer reduced to a declaration'
grep -qF 'if(g.fromEmbed)continue;' src/aster.cpp \
    || fail 'an included file no longer keeps its @embed bytes to itself'
echo 'OK: source guards'

# ---------------------------------------------------------------------------
# 2. A two-file program compiles, links and runs
# ---------------------------------------------------------------------------
# The definition lives in a subdirectory, so "relative to the file that wrote
# the path" and "relative to the working directory" are genuinely different.
mkdir -p "$OUT/sub"
cat >"$OUT/sub/defs.ast" <<'AST'
let total: i32 = 7;

fn add2(n: i32) -> i32 {
    return n + 2;
}
AST
cat >"$OUT/main.ast" <<'AST'
include "sub/defs.ast";

fn main() -> i32 {
    return add2(total);
}
AST
# The same program with the declarations typed in by hand. Everything below
# compares against this: an `include` that does anything more than supply these
# two lines cannot come out identical to it.
cat >"$OUT/hand.ast" <<'AST'
extern let total: i32;
extern fn add2(n: i32) -> i32;

fn main() -> i32 {
    return add2(total);
}
AST

$ASTER build-obj "$OUT/main.ast" -o "$OUT/main.o" >/dev/null
$ASTER build-obj "$OUT/sub/defs.ast" -o "$OUT/defs.o" >/dev/null
$ASTER link-obj "$OUT/main.o" "$OUT/defs.o" -o "$OUT/linked.elf" >/dev/null
# `|| got=$?` rather than `got=$?`: under `set -e` an exit status the suite wants
# to inspect would otherwise abort it, and 9 is a *passing* answer here.
got=0
sh tests/run-aarch64.sh "$OUT/linked.elf" >/dev/null 2>&1 || got=$?
[ "$got" -eq 9 ] || fail "two-file program returned $got, expected add2(7) = 9"
echo 'OK: a two-file program compiles, links and runs (add2(7) = 9)'

# ---------------------------------------------------------------------------
# 3. Declarations only, proven by byte-identity with the hand-written extern
# ---------------------------------------------------------------------------
$ASTER build-obj "$OUT/hand.ast" -o "$OUT/hand.o" >/dev/null
cmp -s "$OUT/main.o" "$OUT/hand.o" \
    || fail 'an object built with `include` is not byte-identical to the hand-written extern version'
echo 'OK: `include` produces byte-identical output to hand-written extern declarations'

# ...and the declarations really are undefined here: main.o defines only main.
readelf -sW "$OUT/main.o" | grep -q 'UND.*add2' \
    || fail 'add2 is not an undefined reference in main.o (its body came across the include)'
readelf -sW "$OUT/main.o" | grep -q 'UND.*total' \
    || fail 'total is not an undefined reference in main.o (its initializer came across)'
echo 'OK: bodies and initializers stay in the file that owns them'

# ---------------------------------------------------------------------------
# 4. The path is relative to the file that wrote it, not to the working directory
# ---------------------------------------------------------------------------
# A decoy of the same relative name in the working directory. If resolution
# were cwd-based this is the file that would be opened, and it does not parse.
mkdir -p "$OUT/decoy/sub"
printf '%s\n' 'this file is not valid Aster source' >"$OUT/decoy/sub/defs.ast"
(cd "$OUT/decoy" && "$HERE/$OUT/aster" build-obj "$HERE/$OUT/main.ast" -o "$HERE/$OUT/from-decoy.o") >/dev/null 2>&1 \
    || fail 'building from another working directory failed (the path resolved against cwd, not the source)'
cmp -s "$OUT/from-decoy.o" "$OUT/hand.o" \
    || fail 'the build from another working directory did not use the neighbouring defs.ast'
echo 'OK: the path resolves against the including file, wherever the build runs from'

# ---------------------------------------------------------------------------
# 5. --include-dir overrides that, and is required when it is needed
# ---------------------------------------------------------------------------
mkdir -p "$OUT/elsewhere"
cat >"$OUT/elsewhere/far.ast" <<'AST'
include "defs.ast";

fn main() -> i32 {
    return add2(total);
}
AST
if $ASTER build-obj "$OUT/elsewhere/far.ast" -o "$OUT/far-bare.o" >/dev/null 2>&1; then
    fail 'far.ast found defs.ast without --include-dir (it sits next to the including file, not here)'
fi
$ASTER build-obj "$OUT/elsewhere/far.ast" --include-dir "$OUT/sub" -o "$OUT/far.o" >/dev/null \
    || fail '--include-dir did not supply the file'
cmp -s "$OUT/far.o" "$OUT/hand.o" \
    || fail '--include-dir produced a different object than the hand-written version'
echo 'OK: --include-dir overrides the including-file rule, and is needed when it is'

# ---------------------------------------------------------------------------
# 6. Including the same file twice is a no-op, not an error
# ---------------------------------------------------------------------------
cat >"$OUT/twice.ast" <<'AST'
include "sub/defs.ast";
include "sub/defs.ast";
include "./sub/defs.ast";

fn main() -> i32 {
    return add2(total);
}
AST
$ASTER build-obj "$OUT/twice.ast" -o "$OUT/twice.o" >/dev/null \
    || fail 'including the same file twice was rejected'
cmp -s "$OUT/twice.o" "$OUT/hand.o" \
    || fail 'repeating an include changed the output (it must be a no-op)'
# A diamond: two files that both include a third. This is the case the `done`
# set exists for, and the one a cycle check must not mistake for a cycle —
# d.ast is reached twice but is never part-way through being parsed.
cat >"$OUT/sub/d.ast" <<'AST'
extern fn add2(n: i32) -> i32;
extern let total: i32;
AST
cat >"$OUT/b.ast" <<'AST'
include "sub/d.ast";

fn useB() -> i32 {
    return add2(total);
}
AST
cat >"$OUT/c.ast" <<'AST'
include "sub/d.ast";

fn useC() -> i32 {
    return add2(total);
}
AST
cat >"$OUT/diamond.ast" <<'AST'
include "b.ast";
include "c.ast";
include "sub/defs.ast";

fn main() -> i32 {
    return useB() + useC();
}
AST
$ASTER build-obj "$OUT/diamond.ast" -o "$OUT/diamond.o" >/dev/null \
    || fail 'a diamond include (two files including a third) was rejected'
echo 'OK: a repeated include is a no-op, and a diamond is not a cycle'

# ---------------------------------------------------------------------------
# 7. A cycle is an error that names the chain
# ---------------------------------------------------------------------------
cat >"$OUT/self.ast" <<'AST'
include "self.ast";

fn main() -> i32 {
    return 0;
}
AST
err=$($ASTER build-obj "$OUT/self.ast" -o "$OUT/self.o" 2>&1 >/dev/null || true)
case "$err" in
    *"include cycle"*) : ;;
    *) fail "a self-include was not reported as a cycle: $err" ;;
esac

cat >"$OUT/cyc-a.ast" <<'AST'
include "cyc-b.ast";

fn main() -> i32 {
    return 0;
}
AST
cat >"$OUT/cyc-b.ast" <<'AST'
include "cyc-c.ast";

fn helper() -> i32 {
    return 1;
}
AST
cat >"$OUT/cyc-c.ast" <<'AST'
include "cyc-a.ast";

fn other() -> i32 {
    return 2;
}
AST
err=$($ASTER build-obj "$OUT/cyc-a.ast" -o "$OUT/cyc.o" 2>&1 >/dev/null || true)
case "$err" in
    *"include cycle"*) : ;;
    *) fail "a three-file include cycle was not reported: $err" ;;
esac
# The message has to name the files involved, or it tells you nothing to act on.
for f in cyc-a.ast cyc-b.ast cyc-c.ast; do
    case "$err" in
        *"$f"*) : ;;
        *) fail "the cycle message does not name $f: $err" ;;
    esac
done
echo 'OK: a cycle is an error, and the message names the chain'

# ---------------------------------------------------------------------------
# 8. A definition in this file supersedes the included declaration
# ---------------------------------------------------------------------------
cat >"$OUT/supersede.ast" <<'AST'
include "sub/defs.ast";

fn add2(n: i32) -> i32 {
    return n + 100;
}

fn main() -> i32 {
    return add2(total);
}
AST
$ASTER build-obj "$OUT/supersede.ast" -o "$OUT/sup.o" >/dev/null \
    || fail 'defining a function that was also included was rejected'
readelf -sW "$OUT/sup.o" | grep -q 'UND.*add2' \
    && fail 'add2 is still undefined: this file is definition was dropped'
# Two definitions of one name in one file is still an error, so this only ever
# gives way to a declaration that arrived through an include.
cat >"$OUT/dup.ast" <<'AST'
fn add2(n: i32) -> i32 { return n + 1; }
fn add2(n: i32) -> i32 { return n + 2; }
fn main() -> i32 { return 0; }
AST
$ASTER build-obj "$OUT/dup.ast" -o "$OUT/dup.o" >/dev/null 2>&1 \
    && fail 'two definitions of the same function in one file were accepted'
echo 'OK: a local definition supersedes an included declaration; a real duplicate is still an error'

# ---------------------------------------------------------------------------
# 9. An included file's @embed bytes are that file's business, not this one's
# ---------------------------------------------------------------------------
printf '%s' 'PAYLOAD-BYTES' >"$OUT/sub/text.txt"
cat >"$OUT/sub/with-embed.ast" <<'AST'
let data: ptr = @embed("text.txt");

fn helper() -> i32 {
    return load_u8(data);
}
AST
cat >"$OUT/use-embed.ast" <<'AST'
include "sub/with-embed.ast";

fn main() -> i32 {
    return 1;
}
AST
$ASTER build-obj "$OUT/use-embed.ast" -o "$OUT/use-embed.o" >/dev/null \
    || fail 'including a file that embeds bytes failed'
if readelf -SW "$OUT/use-embed.o" | grep -q '\.rodata'; then
    rodata_bytes=$(readelf -x .rodata "$OUT/use-embed.o" | grep -c 'PAYLOAD' || true)
    [ "$rodata_bytes" -eq 0 ] || fail 'the included file is embed bytes came across into this object'
fi
echo 'OK: @embed bytes belong to the file that embeds them, not to a file that includes it'

# ---------------------------------------------------------------------------
# 10. A path that resolves to nothing says where it looked
# ---------------------------------------------------------------------------
cat >"$OUT/missing.ast" <<'AST'
include "nowhere/nope.ast";

fn main() -> i32 {
    return 0;
}
AST
err=$($ASTER build-obj "$OUT/missing.ast" -o "$OUT/missing.o" 2>&1 >/dev/null || true)
case "$err" in
    *"cannot open included file"*) : ;;
    *) fail "a missing include was not reported: $err" ;;
esac
case "$err" in
    *"nope.ast"*) : ;;
    *) fail "the include error does not name the path it could not open: $err" ;;
esac
echo 'OK: a missing include is an error that names the path it looked for'

# ---------------------------------------------------------------------------
# 11. -g is not misled: no row of the line table may name an included file
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
    # -g cannot change codegen, in an include-based build either.
    $ASTER build-obj "$OUT/main.ast" -g -o "$OUT/main-dbg.o" >/dev/null
    $ASTER build-obj "$OUT/main.ast"    -o "$OUT/main-plain.o" >/dev/null
    readelf -x .text "$OUT/main-plain.o" >"$OUT/t1"
    readelf -x .text "$OUT/main-dbg.o"   >"$OUT/t2"
    cmp -s "$OUT/t1" "$OUT/t2" || fail '-g changed the .text bytes of an include-based build'

    # An included file contributes declarations, so it contributes no code and
    # therefore no rows: linking the two -g objects must yield one unit per file,
    # each naming only its own lines. This is the check that would catch a
    # future change letting a body (and so another file's line numbers) across.
    $ASTER build-obj "$OUT/sub/defs.ast" -g -o "$OUT/defs-dbg.o" >/dev/null
    $ASTER link-obj "$OUT/main-dbg.o" "$OUT/defs-dbg.o" -o "$OUT/linked-dbg.elf" >/dev/null
    python3 tests/debugline-decode.py "$OUT/linked-dbg.elf" >"$OUT/rows.txt"
    [ -s "$OUT/rows.txt" ] || fail 'the -g build of an include-based program produced no line rows'
    while read -r addr line path; do
        case "$path" in
            */main.ast|*/defs.ast) : ;;
            *) fail "row $addr names $path — only the two compiled files may appear" ;;
        esac
    done <"$OUT/rows.txt"
    # main.ast: the fn on line 3 and the return on line 4. defs.ast: 3 and 4 too.
    for pair in "3 main.ast" "4 main.ast" "3 defs.ast" "4 defs.ast"; do
        set -- $pair
        grep -qE "^0x[0-9a-f]+ $1 .*$2\$" "$OUT/rows.txt" \
            || fail "the linked table is missing line $1 of $2"
    done
    # ...and no row may carry a line from the *other* file's numbering: defs.ast
    # has only 5 lines, main.ast only 5, so a mis-attributed row is visible here.
    for pair in "1 main.ast" "2 main.ast" "5 main.ast" "1 defs.ast" "2 defs.ast" "5 defs.ast"; do
        set -- $pair
        ! grep -qE "^0x[0-9a-f]+ $1 .*$2\$" "$OUT/rows.txt" \
            || fail "the linked table claims line $1 of $2, which holds no statement"
    done
    echo 'OK: -g attributes every row to the file that produced it, and changes no code'
else
    echo 'note: python3 missing — skipping the -g attribution check'
fi

# ---------------------------------------------------------------------------
# 12. Mutations: each is a way to get one of the above silently wrong
# ---------------------------------------------------------------------------
#   mutate <desc> <sed script> <present|absent> <guard text>
# The guard is what keeps this honest: a sed that stops matching the source
# (because the line was refactored) must fail the suite loudly rather than
# quietly compile the unmutated file and "pass" every check.
mutate() {
    desc=$1; script=$2; kind=$3; needle=$4
    sed "$script" src/aster.cpp >"$OUT/mutant.cpp"
    if [ "$kind" = present ]; then
        grep -qF "$needle" "$OUT/mutant.cpp" \
            || fail "the mutation '$desc' no longer applies to src/aster.cpp (fix the guard)"
    else
        grep -qF "$needle" "$OUT/mutant.cpp" \
            && fail "the mutation '$desc' no longer applies to src/aster.cpp (fix the guard)"
    fi
    $CXX -std=c++17 -O2 -w "$OUT/mutant.cpp" -o "$OUT/aster-mutant"
    echo "   mutated: $desc"
}

# 12a. Drop the top-level dispatch: `include` stops being syntax at all.
mutate 'include is no longer handled at the top level' \
    's|if(eat(TK::Include)){includeDirective();continue;}|;|' \
    absent 'if(eat(TK::Include)){includeDirective();continue;}'
if "$OUT/aster-mutant" build-obj "$OUT/main.ast" -o "$OUT/m1.o" >/dev/null 2>&1; then
    fail 'dropping the include dispatch went unnoticed'
fi

# 12b. Resolve against the working directory instead of the including file.
mutate 'include resolves against cwd instead of the including file' \
    's|const std::string full=resolveIncludePath(pathTok.s);|const std::string full=pathTok.s;|' \
    present 'const std::string full=pathTok.s;'
if (cd "$OUT/decoy" && "$HERE/$OUT/aster-mutant" build-obj "$HERE/$OUT/main.ast" \
        -o "$HERE/$OUT/m2.o") >/dev/null 2>&1; then
    fail 'resolving an include against the working directory went unnoticed'
fi

# 12c. Let the included function become a definition: main.o would carry add2's
#      code as well as main's, so it can no longer match the hand-written object.
mutate 'an included function arrives as a definition, not a declaration' \
    's|f.external=true;f.fromInclude=true;f.body.clear();|f.fromInclude=true;f.body.clear();|' \
    absent 'f.external=true;f.fromInclude=true;'
if "$OUT/aster-mutant" build-obj "$OUT/main.ast" -o "$OUT/m3.o" >/dev/null 2>&1 \
   && cmp -s "$OUT/m3.o" "$OUT/hand.o"; then
    fail 'an included function bringing its body across went unnoticed'
fi

# 12d. Forget the supersede rule: "include, then define" stops being legal.
mutate 'a local definition no longer supersedes an included declaration' \
    's|if(!old.fromInclude)throw Error("duplicate function declaration: "+f.name);|if(true)throw Error("duplicate function declaration: "+f.name);|' \
    present 'if(true)throw Error("duplicate function declaration: "+f.name);'
if "$OUT/aster-mutant" build-obj "$OUT/supersede.ast" -o "$OUT/m4.o" >/dev/null 2>&1; then
    fail 'losing the supersede rule went unnoticed'
fi
echo 'OK: four compiler mutations are each caught'

echo 'PASS: `include` shares declarations without sharing code (byte-identical to hand-written extern, own-file paths, cycles rejected, repeated includes inert, -g unaffected)'
