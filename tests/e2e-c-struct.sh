#!/bin/sh
# v0.23.5-dev: does Aster's struct ABI actually agree with C?
#
# Every other struct test compares Aster against itself. This one compares it
# against a real C compiler, in both directions, in all three AAPCS64 size
# classes (8 bytes in one register, 12 in a register pair, 24 through a
# caller-made copy with X8 carrying a >16-byte result):
#
#   C     -> Aster : tests/c-struct-host.c calls examples/c_struct_abi.ast
#   Aster -> C     : the same file supplies the imports that example calls
#
# The halves are linked statically: the point is the calling convention, and a
# static link settles it without dragging in a dynamic loader. (The shared
# object path is exercised by tests/struct-checks.sh and the existing e2e-c-*
# suite; it uses the same PLT machinery.)
#
# The C compiler is a witness here, not a tool in the pipeline: Aster compiles
# its own half and owns every byte of it.
set -eu
. tests/host-toolchain-probe.sh
cd "$(dirname "$0")/.."
CXX=${CXX:-c++}
OUT=${OUT:-tmp-c-struct}
mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT HUP INT TERM

printf '%s\n' '[1/4] Build Aster compiler strictly'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"

printf '%s\n' '[2/4] Aster compiles its half: a relocatable object, no C involved'
"$OUT/aster" build-obj examples/c_struct_abi.ast -o "$OUT/c_struct_abi.o"

printf '%s\n' '[3/4] Link the two halves statically'
${HOSTCC:-cc} -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror -static \
    tests/c-struct-host.c "$OUT/c_struct_abi.o" -o "$OUT/c-struct-host"

printf '%s\n' '[4/4] Run: C calls Aster, Aster calls C'
"$PWD/tests/run-aarch64.sh" "$OUT/c-struct-host"
echo 'PASS: Aster v0.23.5-dev struct ABI matches C in both directions'
