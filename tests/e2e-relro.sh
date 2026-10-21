#!/bin/sh
# v0.21.0: runtime RELRO permission test; run on AArch64 Android/Linux or via qemu-user.
set -eu
. tests/host-toolchain-probe.sh
CXX=${CXX:-g++}
HOSTCC=${HOSTCC:-cc}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
$CXX -std=c++17 -O2 -Wall -Wextra -pedantic src/aster.cpp -o aster
$HOSTCC -O2 -Wall -Wextra -Wpedantic -o tmp-relro-runtime-host tests/relro-runtime-host.c -ldl
WORK=tmp-relro-runtime
rm -rf "$WORK"; mkdir -p "$WORK"
./aster build-so examples/so_link_lib.ast -o "$WORK/librelro-runtime.so" --soname librelro-runtime.so
set +e
out=$(LD_LIBRARY_PATH="$(pwd)/$WORK${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" $RUNNER ./tmp-relro-runtime-host "$(pwd)/$WORK/librelro-runtime.so" 2>&1); rc=$?
set -e
printf '%s\n' "$out"
[ "$rc" -eq 0 ] || { echo "FAIL: runtime RELRO test exited $rc"; exit 1; }
printf '%s\n' "$out" | grep -q 'PASS: Android/Linux loader mapped every PT_GNU_RELRO page read-only'
printf '%s\n' "$out" | grep -q 'PASS: ordinary .data global remains writable'
rm -rf "$WORK" tmp-relro-runtime-host
 echo 'PASS: v0.21.0 runtime RELRO checks'
