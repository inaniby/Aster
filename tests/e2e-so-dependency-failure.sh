#!/bin/sh
# v0.22.35-dev: failed indirect DT_NEEDED loads must not disturb an already-live valid chain.
set -eu
. tests/host-toolchain-probe.sh
CXX=${CXX:-g++}
HOSTCC=${HOSTCC:-cc}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o aster
$HOSTCC -O2 -Wall -Wextra -Wpedantic -Werror -o tmp-so-dependency-failure-host tests/so-dependency-failure-host.c -ldl
WORK=tmp-so-dependency-failure
rm -rf "$WORK"; mkdir -p "$WORK"
# Missing indirect dependency: client -> missing-middle -> absent library.
./aster build-so examples/so_missing_dependency.ast -o "$WORK/libmissing-middle.so" --soname libmissing-middle.so --needed libaster_missing_dependency.so
./aster build-so examples/so_chain_client.ast -o "$WORK/libmissing-client.so" --soname libmissing-client.so --needed libmissing-middle.so
# Unresolved symbol in an indirect dependency: client -> unresolved-middle.
./aster build-so examples/so_chain_middle_unresolved.ast -o "$WORK/libunresolved-middle.so" --soname libunresolved-middle.so
./aster build-so examples/so_chain_client.ast -o "$WORK/libunresolved-client.so" --soname libunresolved-client.so --needed libunresolved-middle.so
# A separate valid chain in the same search path proves recovery after failures.
./aster build-so examples/so_chain_base.ast -o "$WORK/libchain-base.so" --soname libchain-base.so
./aster build-so examples/so_chain_middle.ast -o "$WORK/libchain-middle.so" --soname libchain-middle.so --needed libchain-base.so
./aster build-so examples/so_chain_client.ast -o "$WORK/libchain-client.so" --soname libchain-client.so --needed libchain-middle.so
ABS=$(pwd)/$WORK
. tests/guest-libc-alias.sh && provide_guest_libc_alias "$WORK"
set +e
out=$(LD_LIBRARY_PATH="$ABS" $RUNNER ./tmp-so-dependency-failure-host "$ABS/libmissing-client.so" "$ABS/libunresolved-client.so" "$ABS/libchain-base.so" "$ABS/libchain-client.so" 2>&1); rc=$?
set -e
printf '%s\n' "$out"
[ "$rc" -eq 0 ] || { echo "FAIL: dependency failure host exited $rc"; exit 1; }
printf '%s\n' "$out" | grep -q '^PASS: repeated indirect dependency failures, dlerror consumption, per-failure live-chain integrity, recovery, and final-close reload tests$' || { echo 'FAIL: indirect dependency recovery summary missing'; exit 1; }
rm -rf "$WORK" tmp-so-dependency-failure-host
echo 'PASS: Aster v0.22.35-dev indirect dependency failure, per-failure live-chain integrity, recovery, and reload tests'
