#!/bin/sh
# v0.22.21-dev end-to-end: validate direct and PIC ET_REL -> link-so importers with the real dynamic linker.
#
# Run natively on an AArch64 Linux/Android host, or from any host through qemu-user:
#
#   HOSTCC=aarch64-linux-gnu-gcc RUNNER="qemu-aarch64 -L /usr/aarch64-linux-gnu" sh tests/e2e-so-import.sh
#
# HOSTCC compiles the target-architecture test hosts (so-import-host.c, so-host.c) and RUNNER is an
# optional command prefix. The script verifies that:
#   * a .so that DT_NEEDED another .so is loaded together with it (SONAME/NEEDED through the loader);
#   * a call to an imported function really goes through the .plt + R_AARCH64_JUMP_SLOT slot;
#   * a read *and* a write of an imported global really goes through the .got + R_AARCH64_GLOB_DAT;
#   * `link-so` merges several PIC objects and resolves their mutual references inside one .so;
#   * a further .so can import from a link-so output;
#   * the v0.17.0 single-source shared object (DT_HASH + R_AARCH64_RELATIVE) still loads and runs.
set -eu
. tests/host-toolchain-probe.sh
CXX=${CXX:-g++}
HOSTCC=${HOSTCC:-cc}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
$CXX -std=c++17 -O2 -Wall -Wextra -pedantic src/aster.cpp -o aster
$HOSTCC -O1 -o tmp-so-import-host tests/so-import-host.c -ldl
$HOSTCC -O1 -o tmp-so-host tests/so-host.c -ldl

WORK=tmp-so-import
rm -rf "$WORK"; mkdir -p "$WORK"
./aster build-so  examples/so_link_lib.ast      -o "$WORK/libdyn.so"           --soname libdyn.so
./aster build-so  examples/so_link_import.ast   -o "$WORK/libdyn-import.so"    --needed libdyn.so
./aster build-obj --pic examples/so_link_import.ast -o "$WORK/dyn-import.o"
./aster link-so "$WORK/dyn-import.o" -o "$WORK/libdyn-import-linked.so" --soname libdyn-import-linked.so --needed libdyn.so
./aster build-obj --pic examples/link_so_part_a.ast -o "$WORK/part_a.o"
./aster build-obj --pic examples/link_so_part_b.ast -o "$WORK/part_b.o"
./aster link-so   "$WORK/part_a.o" "$WORK/part_b.o" -o "$WORK/liblinked.so"    --soname liblinked.so
./aster build-so  examples/link_so_client.ast   -o "$WORK/liblinked-client.so" --needed liblinked.so
./aster build-so  examples/so_math.ast          -o "$WORK/legacy_math.so"

ABS=$(pwd)/$WORK
. tests/guest-libc-alias.sh && provide_guest_libc_alias "$WORK"
echo "# built: $(ls "$WORK"/*.so | wc -l) shared object(s) in $WORK"

set +e
out=$(LD_LIBRARY_PATH="$ABS" $RUNNER ./tmp-so-import-host "$ABS/libdyn-import.so" "$ABS/liblinked.so" "$ABS/liblinked-client.so" 2>&1); rc=$?
set -e
printf '%s\n' "$out"
[ "$rc" -eq 0 ] || { echo "FAIL: build-so importer host exited $rc"; exit 1; }
n=$(printf '%s\n' "$out" | grep -c '^PASS')
[ "$n" -ge 18 ] || { echo "FAIL: expected at least 18 PASS lines from build-so importer, got $n"; exit 1; }
echo "PASS: $n dlopen/dlsym checks passed for direct build-so importer"

set +e
out=$(LD_LIBRARY_PATH="$ABS" $RUNNER ./tmp-so-import-host "$ABS/libdyn-import-linked.so" "$ABS/liblinked.so" "$ABS/liblinked-client.so" 2>&1); rc=$?
set -e
printf '%s\n' "$out"
[ "$rc" -eq 0 ] || { echo "FAIL: link-so ET_REL importer host exited $rc"; exit 1; }
n=$(printf '%s\n' "$out" | grep -c '^PASS')
[ "$n" -ge 18 ] || { echo "FAIL: expected at least 18 PASS lines from link-so importer, got $n"; exit 1; }
echo "PASS: $n dlopen/dlsym checks passed for PIC ET_REL -> link-so importer"

set +e
out=$(LD_LIBRARY_PATH="$ABS" $RUNNER ./tmp-so-host "$ABS/legacy_math.so" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || { echo "FAIL: legacy so-host exited $rc: $out"; exit 1; }
echo "PASS: v0.17.0 single-source shared object (DT_HASH + R_AARCH64_RELATIVE GOT slots) still loads and runs"

rm -rf "$WORK" tmp-so-import-host tmp-so-host
echo "PASS: cross-.so imports work for direct build-so and PIC ET_REL -> link-so paths"
