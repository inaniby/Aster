#!/bin/sh
# v0.22.22-dev runtime negative tests using the real platform dynamic loader.
# Native AArch64/Termux, or cross-run with HOSTCC and RUNNER as in e2e-so-import.sh.
set -eu
. tests/host-toolchain-probe.sh
CXX=${CXX:-g++}
HOSTCC=${HOSTCC:-cc}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic src/aster.cpp -o aster
$HOSTCC -O1 -Wall -Wextra -Wpedantic -Werror -o tmp-so-negative-host tests/so-negative-host.c -ldl
WORK=tmp-so-negative
rm -rf "$WORK"; mkdir -p "$WORK"
./aster build-so examples/so_missing_dependency.ast -o "$WORK/libmissing-dependency-client.so" --needed libaster_missing_dependency.so
./aster build-so examples/so_missing_symbol.ast -o "$WORK/libmissing-symbol-client.so"
ABS=$(pwd)/$WORK
. tests/guest-libc-alias.sh && provide_guest_libc_alias "$WORK"

# The named dependency intentionally does not exist in WORK or the standard loader path.
set +e
out=$(LD_LIBRARY_PATH="$ABS" $RUNNER ./tmp-so-negative-host "$ABS/libmissing-dependency-client.so" libaster_missing_dependency.so 2>&1); rc=$?
set -e
printf '%s\n' "$out"
[ "$rc" -eq 0 ] || { echo "FAIL: missing-dependency loader test exited $rc"; exit 1; }

# RTLD_NOW must resolve all function imports during dlopen, not defer the failure until call time.
set +e
out=$(LD_LIBRARY_PATH="$ABS" $RUNNER ./tmp-so-negative-host "$ABS/libmissing-symbol-client.so" aster_missing_function 2>&1); rc=$?
set -e
printf '%s\n' "$out"
[ "$rc" -eq 0 ] || { echo "FAIL: unresolved-symbol loader test exited $rc"; exit 1; }

rm -rf "$WORK" tmp-so-negative-host
echo 'PASS: missing dependency and unresolved import fail with loader diagnostics'
