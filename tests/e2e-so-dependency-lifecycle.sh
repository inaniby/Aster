#!/bin/sh
# v0.22.28-dev: validate DT_NEEDED dependency lifetime using the real loader.
set -eu
. tests/host-toolchain-probe.sh
CXX=${CXX:-g++}
HOSTCC=${HOSTCC:-cc}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o aster
$HOSTCC -O2 -Wall -Wextra -Wpedantic -Werror -o tmp-so-dependency-lifecycle-host tests/so-dependency-lifecycle-host.c -ldl
WORK=tmp-so-dependency-lifecycle
rm -rf "$WORK"; mkdir -p "$WORK"
./aster build-so examples/so_link_lib.ast -o "$WORK/libdyn.so" --soname libdyn.so
./aster build-so examples/so_link_import.ast -o "$WORK/libdyn-import.so" --soname libdyn-import.so --needed libdyn.so
ABS=$(pwd)/$WORK
. tests/guest-libc-alias.sh && provide_guest_libc_alias "$WORK"
set +e
out=$(LD_LIBRARY_PATH="$ABS" $RUNNER ./tmp-so-dependency-lifecycle-host "$ABS/libdyn.so" "$ABS/libdyn-import.so" 2>&1); rc=$?
set -e
printf '%s\n' "$out"
[ "$rc" -eq 0 ] || { echo "FAIL: dependency lifecycle host exited $rc"; exit 1; }
printf '%s\n' "$out" | grep -q '^PASS: DT_NEEDED dependency lifetime follows importer reference and resets after final unload$' || { echo 'FAIL: dependency lifetime summary missing'; exit 1; }
rm -rf "$WORK" tmp-so-dependency-lifecycle-host
echo 'PASS: Aster v0.22.28-dev DT_NEEDED dependency lifetime tests'
