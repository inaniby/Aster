#!/bin/sh
# v0.17.0 end-to-end verification of the deeper global features: the generated images are actually
# executed. Run natively on an AArch64 host, or from any host through qemu-user:
#
#   HOSTCC=aarch64-linux-gnu-gcc RUNNER="qemu-aarch64 -L /usr/aarch64-linux-gnu" sh tests/e2e-global-deep.sh
#
# HOSTCC compiles the target-architecture shared-object host (so-init-host.c).
# RUNNER is an optional command prefix used to execute the generated AArch64 programs.
set -eu
. tests/host-toolchain-probe.sh
CXX=${CXX:-g++}
HOSTCC=${HOSTCC:-cc}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
$CXX -std=c++17 -O2 -Wall -Wextra -pedantic src/aster.cpp -o aster
$HOSTCC -O1 -o tmp-so-init-host tests/so-init-host.c -ldl
run() { $RUNNER "$@"; }
check_exit() { # label image expected
  set +e; run "./$2" >/dev/null 2>&1; got=$?; set -e
  [ "$got" -eq "$3" ] || { echo "FAIL: $1 expected exit $3, got $got"; exit 1; }
  echo "PASS: $1 exit=$got"
}

# --- fixed-address ET_EXEC: arrays, run-time initializers and alignment -------------
for pair in array_rw:84 array_sum:45 array_bss:29 array_index_expr:12 runtime_init:18 align_global:35; do
  name=${pair%%:*}; want=${pair##*:}
  ./aster build-elf "examples/$name.ast" -o "tmp-$name"
  chmod +x "tmp-$name"
  check_exit "$name" "tmp-$name" "$want"
done

# --- static PIE: the same features at a position-independent link -------------------
for pair in array_rw:84 array_index_expr:12 runtime_init:18 align_global:35; do
  name=${pair%%:*}; want=${pair##*:}
  ./aster build-pie "examples/$name.ast" -o "tmp-pie-$name"
  chmod +x "tmp-pie-$name"
  check_exit "pie-$name" "tmp-pie-$name" "$want"
done

# --- cross-object: extern array, and run-time initializer ordering ------------------
./aster build-obj examples/array_extern_main.ast -o tmp-ae-main.o
./aster build-obj examples/array_extern_defs.ast -o tmp-ae-defs.o
./aster link-obj tmp-ae-main.o tmp-ae-defs.o -o tmp-array-extern
chmod +x tmp-array-extern
check_exit array-extern tmp-array-extern 20
./aster link-pie tmp-ae-main.o tmp-ae-defs.o -o tmp-pie-array-extern
chmod +x tmp-pie-array-extern
check_exit pie-array-extern tmp-pie-array-extern 20

# Entry object first: first is initialized before second reads it -> 12.
./aster build-obj examples/runtime_init_order_main.ast -o tmp-ro-main.o
./aster build-obj examples/runtime_init_order_defs.ast -o tmp-ro-defs.o
./aster link-obj tmp-ro-main.o tmp-ro-defs.o -o tmp-runtime-order
chmod +x tmp-runtime-order
check_exit runtime-order tmp-runtime-order 12
# Provider object first: first is still zero when second reads it -> 11.
./aster link-obj tmp-ro-defs.o tmp-ro-main.o -o tmp-runtime-order-rev
chmod +x tmp-runtime-order-rev
check_exit runtime-order-rev tmp-runtime-order-rev 11

# --- shared object: DT_INIT_ARRAY runs the initializer at dlopen time ---------------
./aster build-so examples/runtime_init.ast -o tmp-so-rt-init.so
set +e; run ./tmp-so-init-host ./tmp-so-rt-init.so main 18; got=$?; set -e
[ "$got" -eq 0 ] || { echo "FAIL: shared-object initializer host exit=$got"; exit 1; }
echo "PASS: dlopen ran the shared object's run-time initializer (main()=18)"

rm -f tmp-array_rw tmp-array_sum tmp-array_bss tmp-array_index_expr tmp-runtime_init tmp-align_global \
      tmp-pie-array_rw tmp-pie-array_index_expr tmp-pie-runtime_init tmp-pie-align_global \
      tmp-ae-main.o tmp-ae-defs.o tmp-array-extern tmp-pie-array-extern \
      tmp-ro-main.o tmp-ro-defs.o tmp-runtime-order tmp-runtime-order-rev \
      tmp-so-init-host tmp-so-rt-init.so
echo "PASS: all v0.17.0 deep global-variable execution checks"
