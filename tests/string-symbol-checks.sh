#!/bin/sh
# tests/string-symbol-checks.sh — A-25: a compiler-generated string blob is
# private to the object that carries it (v0.23.77-dev).
#
# The blob's symbol name is a per-file counter (`__aster_string_0`), so two
# objects that each embed a literal used to collide at link time
# ("duplicate global symbol '__aster_string_0' across input objects"). The
# linker now makes each object's blobs per-input before the definitions map
# sees them.
#
# Layers:
#   [1] strict build of the compiler
#   [2] two objects, each with a literal, link and both literals print
#   [3] the same through build-so + a C host (the .so path's own remap)
#   [4] the baseline does not move (393 rows, a single-file build reproduced)
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
. tests/lib/baseline.sh
CXX=${CXX:-c++}
ASTER="$TMPD/strsym-aster"
OUT="$TMPD/strsym-work"
rm -rf "$OUT"; mkdir -p "$OUT"
fail(){ echo "FAIL: $*" >&2; exit 1; }
ok(){ printf '  %-46s %s\n' "$1" 'ok'; }

printf '%s\n' '[1/4] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -o "$ASTER" src/aster.cpp
ok 'compiler built'

printf '%s\n' '[2/4] two objects with literals, linked'
cat > "$OUT/lib.ast" <<'AST'
fn lib_line() -> i32 {
    write(1, "lib says\n", 9);
    return 0;
}
AST
cat > "$OUT/main.ast" <<'AST'
extern fn lib_line() -> i32;
fn main() -> i32 {
    write(1, "main says\n", 10);
    return lib_line();
}
AST
"$ASTER" build-obj "$OUT/lib.ast" -o "$OUT/lib.o" >/dev/null 2>&1 || fail 'lib.o did not build'
"$ASTER" build-obj "$OUT/main.ast" -o "$OUT/main.o" >/dev/null 2>&1 || fail 'main.o did not build'
"$ASTER" link-obj "$OUT/main.o" "$OUT/lib.o" -o "$OUT/two" >"$OUT/link.log" 2>&1 \
    || fail "the two-literal link failed: $(tail -1 "$OUT/link.log")"
chmod +x "$OUT/two"
(cd "$OUT" && "$RUNNER" ./two > two.out 2>&1) || fail "the two-object program exited $?"
printf 'main says\nlib says\n' > "$OUT/want.out"
cmp -s "$OUT/two.out" "$OUT/want.out" || { cat -A "$OUT/two.out" >&2; fail 'both literals did not print'; }
ok 'A-25: two objects, two literals, one image'

printf '%s\n' '[3/4] the .so path keeps its own remap'
cat > "$OUT/so.ast" <<'AST'
fn so_line() -> i32 {
    write(1, "so says\n", 8);
    return 0;
}
AST
cat > "$OUT/host.c" <<'CEOF'
#include <dlfcn.h>
#include <stdio.h>
int main(void){
    void *h=dlopen("./libstrsym.so", RTLD_NOW);
    if(!h){ printf("dlopen: %s\n", dlerror()); return 1; }
    int (*f)(void)=(int(*)(void))dlsym(h,"so_line");
    if(!f){ printf("dlsym failed\n"); return 2; }
    f();
    return 0;
}
CEOF
"$ASTER" build-so "$OUT/so.ast" -o "$OUT/libstrsym.so" >/dev/null 2>&1 || fail 'the .so did not build'
# v0.23.77-dev (host adaptation): dlopen() only accepts a shared object of the
# *host's* architecture, so the consumer must be an AArch64 program too. An
# x86-built host loading an AArch64 .so exits 1 with "cannot open shared object
# file" — an architecture mismatch, not a broken .so. HOSTCC is the native
# compiler on an AArch64/Termux host and the cross compiler on x86; RUNNER runs
# the pair natively or under qemu on either machine.
HOSTCC=${HOSTCC:-cc}
"$HOSTCC" -O1 -w "$OUT/host.c" -o "$OUT/host" -ldl || fail 'the host did not build'
(cd "$OUT" && LD_LIBRARY_PATH=. "$RUNNER" ./host > so.out 2>&1) || fail "the .so consumer exited $?"
grep -qxF 'so says' "$OUT/so.out" || fail "the .so consumer printed '$(cat "$OUT/so.out")'"
ok '.so: dlopen + dlsym + the literal'

printf '%s\n' '[4/4] the baseline does not move'
BASE=$(aster_baseline_file)
rows=$(wc -l < "$BASE")
[ "$rows" = 393 ] || fail "the baseline has $rows rows, expected 393"
key=hello.build-elf
val=$(grep "^$key " "$BASE" | cut -d' ' -f2)
"$ASTER" build-elf examples/hello.ast -o "$OUT/$key" >/dev/null 2>&1 || fail 'the sample row did not build'
got=$(sha256sum "$OUT/$key" | cut -d' ' -f1)
[ "$got" = "$val" ] || fail "$key moved: expected $val, got $got"
ok '393 rows, a single-file row reproduced'

echo 'PASS: private string blobs (A-25)'
