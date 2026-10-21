#!/bin/sh
# v0.22.29-dev: client -> middle -> base DT_NEEDED chain and multi-client lifetime.
set -eu
. tests/host-toolchain-probe.sh
CXX=${CXX:-g++}
HOSTCC=${HOSTCC:-cc}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o aster
$HOSTCC -O2 -Wall -Wextra -Wpedantic -Werror -o tmp-so-dependency-chain-host tests/so-dependency-chain-host.c -ldl
WORK=tmp-so-dependency-chain
rm -rf "$WORK"; mkdir -p "$WORK"
./aster build-so examples/so_chain_base.ast -o "$WORK/libchain-base.so" --soname libchain-base.so
./aster build-so examples/so_chain_middle.ast -o "$WORK/libchain-middle.so" --soname libchain-middle.so --needed libchain-base.so
./aster build-so examples/so_chain_client.ast -o "$WORK/libchain-client-a.so" --soname libchain-client-a.so --needed libchain-middle.so
./aster build-so examples/so_chain_client.ast -o "$WORK/libchain-client-b.so" --soname libchain-client-b.so --needed libchain-middle.so
ABS=$(pwd)/$WORK
. tests/guest-libc-alias.sh && provide_guest_libc_alias "$WORK"
set +e
out=$(LD_LIBRARY_PATH="$ABS" $RUNNER ./tmp-so-dependency-chain-host "$ABS/libchain-base.so" "$ABS/libchain-client-a.so" "$ABS/libchain-client-b.so" 2>&1); rc=$?
set -e
printf '%s\n' "$out"
[ "$rc" -eq 0 ] || { echo "FAIL: dependency chain host exited $rc"; exit 1; }
printf '%s\n' "$out" | grep -q '^PASS: dependency chain, multi-client lifetime, close order, and final reload tests$' || { echo 'FAIL: dependency chain summary missing'; exit 1; }
rm -rf "$WORK" tmp-so-dependency-chain-host
echo 'PASS: Aster v0.22.29-dev DT_NEEDED dependency-chain tests'
