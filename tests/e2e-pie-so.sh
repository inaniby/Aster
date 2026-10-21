#!/bin/sh
# End-to-end verification of the v0.17.0 static-PIE and shared-object outputs: the generated
# images are actually executed. Run natively on an AArch64 host, or from any host through qemu-user:
#
#   HOSTCC=aarch64-linux-gnu-gcc RUNNER="qemu-aarch64 -L /usr/aarch64-linux-gnu" sh tests/e2e-pie-so.sh
#
# HOSTCC compiles the two target-architecture test hosts (pie-loader.c, so-host.c).
# RUNNER is an optional command prefix used to execute the generated AArch64 programs.
set -eu
. tests/host-toolchain-probe.sh
CXX=${CXX:-g++}
HOSTCC=${HOSTCC:-cc}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
$CXX -std=c++17 -O2 -Wall -Wextra -pedantic src/aster.cpp -o aster
$HOSTCC -O1 -o tmp-pie-loader tests/pie-loader.c
$HOSTCC -O1 -o tmp-so-host tests/so-host.c -ldl
run() { $RUNNER "$@"; }

check_exit() { # name expected
  set +e; run "./$1" >/dev/null 2>&1; got=$?; set -e
  [ "$got" -eq "$2" ] || { echo "FAIL: $1 expected exit $2, got $got"; exit 1; }
  echo "PASS: $1 exit=$got"
}

# --- static PIE executed directly through the kernel ---------------------------------
./aster build-pie examples/hello.ast -o tmp-pie-hello
./aster build-pie examples/pie_global_rw.ast -o tmp-pie-global
./aster build-obj examples/pie_modular_main.ast -o tmp-pie-main.o
./aster build-obj examples/pie_modular_helper.ast -o tmp-pie-helper.o
./aster link-pie tmp-pie-main.o tmp-pie-helper.o -o tmp-pie-modular
chmod +x tmp-pie-hello tmp-pie-global tmp-pie-modular
check_exit tmp-pie-hello 42
check_exit tmp-pie-global 42
check_exit tmp-pie-modular 42

# --- static PIE loaded at unrelated bases by pie-loader ------------------------------
for image in tmp-pie-global tmp-pie-modular; do
  : > tmp-pie-bases
  for i in 1 2 3 4 5 6; do
    set +e; run ./tmp-pie-loader "./$image" 2>tmp-pie-base.log >/dev/null; got=$?; set -e
    [ "$got" -eq 42 ] || { echo "FAIL: pie-loader $image exit=$got"; cat tmp-pie-base.log; exit 1; }
    sed -n 's/.*base=\(0x[0-9a-f]*\).*/\1/p' tmp-pie-base.log >> tmp-pie-bases
  done
  distinct=$(sort -u tmp-pie-bases | sed '/^$/d' | wc -l)
  [ "$distinct" -ge 3 ] || { echo "FAIL: $image only ran at $distinct distinct base(s)"; cat tmp-pie-bases; exit 1; }
  echo "PASS: $image executed at $distinct distinct load bases, all exit=42"
done

# --- shared object through dlopen/dlsym ----------------------------------------------
./aster build-so examples/so_math.ast -o tmp-so-math.so
set +e; run ./tmp-so-host ./tmp-so-math.so; got=$?; set -e
[ "$got" -eq 0 ] || { echo "FAIL: shared-object host exit=$got"; exit 1; }
echo "PASS: dlopen/dlsym shared-object host exit=$got"

rm -f tmp-pie-hello tmp-pie-global tmp-pie-modular tmp-pie-main.o tmp-pie-helper.o \
      tmp-pie-loader tmp-so-host tmp-so-math.so tmp-pie-bases tmp-pie-base.log
echo "PASS: all v0.17.0 static-PIE and shared-object execution checks"
