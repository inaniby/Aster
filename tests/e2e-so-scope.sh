#!/bin/sh
# Target-device tests for DSO symbol scopes and close/reopen lifecycle.
set -eu
. tests/host-toolchain-probe.sh
CXX=${CXX:-g++}; HOSTCC=${HOSTCC:-cc}; RUNNER=${RUNNER:-tests/run-aarch64.sh}
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o aster
$HOSTCC -O2 -Wall -Wextra -Wpedantic -Werror -o tmp-so-scope-host tests/so-scope-host.c -ldl
$HOSTCC -O2 -Wall -Wextra -Wpedantic -Werror -o tmp-so-loader-lifecycle-host tests/so-loader-lifecycle-host.c -ldl
WORK=tmp-so-scope
rm -rf "$WORK"; mkdir -p "$WORK"
./aster build-so examples/so_scope_a.ast -o "$WORK/libscope-a.so" --soname libscope-a.so
./aster build-so examples/so_scope_b.ast -o "$WORK/libscope-b.so" --soname libscope-b.so
ABS=$(pwd)/$WORK
. tests/guest-libc-alias.sh && provide_guest_libc_alias "$WORK"
$RUNNER ./tmp-so-scope-host "$ABS/libscope-a.so" "$ABS/libscope-b.so" ab
$RUNNER ./tmp-so-scope-host "$ABS/libscope-a.so" "$ABS/libscope-b.so" ba
$RUNNER ./tmp-so-loader-lifecycle-host global "$ABS/libscope-a.so" "$ABS/libscope-b.so"
$RUNNER ./tmp-so-loader-lifecycle-host lifecycle "$ABS/libscope-a.so"
$RUNNER ./tmp-so-loader-lifecycle-host repeat "$ABS/libscope-a.so"
$RUNNER ./tmp-so-loader-lifecycle-host recovery "$ABS/libscope-a.so"
$RUNNER ./tmp-so-loader-lifecycle-host close-order "$ABS/libscope-a.so"
rm -rf "$WORK" tmp-so-scope-host tmp-so-loader-lifecycle-host
echo 'PASS: Aster v0.22.30-dev DSO scope, loader recovery, close-order, repeated-handle, and lifecycle tests' 
