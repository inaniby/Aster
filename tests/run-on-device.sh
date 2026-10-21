#!/bin/sh
# Aster device suite: run this on the AArch64 target itself -- Android/bionic (e.g. from
# /data/local/tmp with `sh tests/run-on-device.sh`) or any AArch64 Linux. It needs nothing but a
# C/C++ compiler, `sh` and the platform dynamic linker: every check executes a real product and
# compares its exit status or the values returned by dlopen/dlsym.
#
#   CXX=g++ sh tests/run-on-device.sh                       # on the device
#   sh tests/run-on-device.sh                               # compiler auto-detected
#
# From an x86 host you can also run it through qemu-user by naming the cross compiler and a
# RUNNER prefix; on the device RUNNER stays empty.
#
#   CXX=aarch64-linux-gnu-g++ HOSTCC=aarch64-linux-gnu-gcc \
#       RUNNER="qemu-aarch64-static -L /usr/aarch64-linux-gnu" sh tests/run-on-device.sh
set -eu
CXX=${CXX:-}
if [ -z "$CXX" ]; then
  if command -v g++ >/dev/null 2>&1; then CXX=g++; elif command -v clang++ >/dev/null 2>&1; then CXX=clang++; else echo "FAIL: no C++ compiler found; set CXX" >&2; exit 2; fi
fi
HOSTCC=${HOSTCC:-}
if [ -z "$HOSTCC" ]; then
  if command -v cc >/dev/null 2>&1; then HOSTCC=cc; elif command -v clang >/dev/null 2>&1; then HOSTCC=clang; else HOSTCC=gcc; fi
fi
RUNNER=${RUNNER:-}
run() { $RUNNER "$@"; }
$CXX -std=c++17 -O2 -Wall -Wextra -pedantic src/aster.cpp -o aster
for name in hello arithmetic negative_division if_less if_greater_equal if_equal if_not_equal_false if_less_equal if_greater_false assignment while_count nested_while scope_shadow nested_if many_locals long_expression if_return while_break while_continue nested_loop_break functions arguments nested_calls recursion eight_args; do
  ./aster build-obj "examples/$name.ast" -o "tmp-$name.o"
  ./aster link-obj "tmp-$name.o" -o "tmp-$name"
done
chmod +x tmp-functions tmp-arguments tmp-nested_calls tmp-recursion tmp-eight_args tmp-hello tmp-arithmetic tmp-negative_division tmp-if_less tmp-if_greater_equal tmp-if_equal tmp-if_not_equal_false tmp-if_less_equal tmp-if_greater_false tmp-assignment tmp-while_count tmp-nested_while tmp-scope_shadow tmp-nested_if tmp-many_locals tmp-long_expression tmp-if_return tmp-while_break tmp-while_continue tmp-nested_loop_break
check() {
  name=$1 expected=$2
  set +e
  run "./tmp-$name"
  got=$?
  set -e
  if [ "$got" -ne "$expected" ]; then echo "FAIL: $name expected $expected, got $got"; exit 1; fi
  echo "PASS: $name exit=$got"
}
check functions 42
check arguments 42
check nested_calls 42
check recursion 120
check eight_args 42
# Cross-object call: main and helper are compiled independently, then linked.
./aster build-obj examples/modular_main.ast -o tmp-modular-main.o
./aster build-obj examples/modular_helper.ast -o tmp-modular-helper.o
./aster link-obj tmp-modular-main.o tmp-modular-helper.o -o tmp-modular
chmod +x tmp-modular
check modular 42
# Global variables in .data/.bss, plus a cross-object global definition.
for name in global_rw global_bss global_mixed global_shadow; do
  ./aster build-obj "examples/$name.ast" -o "tmp-$name.o"
  ./aster link-obj "tmp-$name.o" -o "tmp-$name"
done
./aster build-obj examples/global_shared_main.ast -o tmp-global_shared_main.o
./aster build-obj examples/global_shared_defs.ast -o tmp-global_shared_defs.o
./aster link-obj tmp-global_shared_main.o tmp-global_shared_defs.o -o tmp-global_shared
chmod +x tmp-global_rw tmp-global_bss tmp-global_mixed tmp-global_shadow tmp-global_shared
check global_rw 42
check global_bss 42
check global_mixed 42
check global_shadow 42
check global_shared 42
rm -f tmp-global_rw.o tmp-global_bss.o tmp-global_mixed.o tmp-global_shadow.o tmp-global_rw tmp-global_bss tmp-global_mixed tmp-global_shadow tmp-global_shared_main.o tmp-global_shared_defs.o tmp-global_shared
check hello 42
check arithmetic 0
check negative_division 214
check if_less 42
check if_greater_equal 42
check if_equal 42
check if_not_equal_false 42
check if_less_equal 42
check if_greater_false 42
check assignment 42
check while_count 5
check nested_while 6
check scope_shadow 42
check nested_if 42
check many_locals 42
check long_expression 210
check if_return 42
check while_break 3
check while_continue 18
check nested_loop_break 3
rm -f tmp-modular-main.o tmp-modular-helper.o tmp-modular tmp-functions.o tmp-hello.o tmp-arithmetic.o tmp-negative_division.o tmp-if_less.o tmp-if_greater_equal.o tmp-if_equal.o tmp-if_not_equal_false.o tmp-if_less_equal.o tmp-if_greater_false.o tmp-assignment.o tmp-while_count.o tmp-nested_while.o tmp-scope_shadow.o tmp-nested_if.o tmp-many_locals.o tmp-long_expression.o tmp-if_return.o tmp-while_break.o tmp-while_continue.o tmp-nested_loop_break.o tmp-modular tmp-functions tmp-hello tmp-arithmetic tmp-negative_division tmp-if_less tmp-if_greater_equal tmp-if_equal tmp-if_not_equal_false tmp-if_less_equal tmp-if_greater_false tmp-assignment tmp-while_count tmp-nested_while tmp-scope_shadow tmp-nested_if tmp-many_locals tmp-long_expression tmp-if_return tmp-while_break tmp-while_continue tmp-nested_loop_break tmp-arguments.o tmp-nested_calls.o tmp-recursion.o tmp-eight_args.o tmp-arguments tmp-nested_calls tmp-recursion tmp-eight_args
# v0.17.0: static PIE (ET_DYN executable, no interpreter) images run at the kernel-chosen base.
./aster build-pie examples/pie_global_rw.ast -o tmp-pie_global_rw
./aster build-obj examples/pie_modular_main.ast -o tmp-pie_modular_main.o
./aster build-obj examples/pie_modular_helper.ast -o tmp-pie_modular_helper.o
./aster link-pie tmp-pie_modular_main.o tmp-pie_modular_helper.o -o tmp-pie_modular
chmod +x tmp-pie_global_rw tmp-pie_modular
check pie_global_rw 42
check pie_modular 42
rm -f tmp-pie_global_rw tmp-pie_modular tmp-pie_modular_main.o tmp-pie_modular_helper.o
# v0.17.0: fixed-length arrays, run-time initializers and alignment, plus their cross-object forms.
for name in array_rw array_sum array_bss array_index_expr runtime_init align_global; do
  ./aster build-obj "examples/$name.ast" -o "tmp-$name.o"
  ./aster link-obj "tmp-$name.o" -o "tmp-$name"
done
chmod +x tmp-array_rw tmp-array_sum tmp-array_bss tmp-array_index_expr tmp-runtime_init tmp-align_global
check array_rw 84
check array_sum 45
check array_bss 29
check array_index_expr 12
check runtime_init 18
check align_global 35
./aster build-obj examples/array_extern_main.ast -o tmp-array_extern_main.o
./aster build-obj examples/array_extern_defs.ast -o tmp-array_extern_defs.o
./aster link-obj tmp-array_extern_main.o tmp-array_extern_defs.o -o tmp-array_extern
chmod +x tmp-array_extern
check array_extern 20
./aster build-obj examples/runtime_init_order_main.ast -o tmp-runtime_init_order_main.o
./aster build-obj examples/runtime_init_order_defs.ast -o tmp-runtime_init_order_defs.o
./aster link-obj tmp-runtime_init_order_main.o tmp-runtime_init_order_defs.o -o tmp-runtime_init_order
chmod +x tmp-runtime_init_order
check runtime_init_order 12
rm -f tmp-array_rw.o tmp-array_sum.o tmp-array_bss.o tmp-array_index_expr.o tmp-runtime_init.o tmp-align_global.o \
      tmp-array_rw tmp-array_sum tmp-array_bss tmp-array_index_expr tmp-runtime_init tmp-align_global \
      tmp-array_extern_main.o tmp-array_extern_defs.o tmp-array_extern \
      tmp-runtime_init_order_main.o tmp-runtime_init_order_defs.o tmp-runtime_init_order
# v0.18.0: shared objects with DT_SONAME/DT_NEEDED and cross-.so imports through PLT/GOT. The
# evidence is that the platform dynamic linker (glibc or Android bionic) really loads three
# mutually dependent .so files, and that every imported call and imported global read/write comes
# back with the expected value -- there is no compiler self-check in this section at all.
WORK=tmp-device-so
rm -rf "$WORK"; mkdir -p "$WORK"
./aster build-so  examples/so_link_lib.ast    -o "$WORK/libdyn.so"            --soname libdyn.so
./aster build-so  examples/so_link_import.ast -o "$WORK/libdyn-import.so"     --needed libdyn.so
./aster build-obj --pic examples/link_so_part_a.ast -o "$WORK/part_a.o"
./aster build-obj --pic examples/link_so_part_b.ast -o "$WORK/part_b.o"
./aster link-so   "$WORK/part_a.o" "$WORK/part_b.o" -o "$WORK/liblinked.so"   --soname liblinked.so
./aster build-so  examples/link_so_client.ast -o "$WORK/liblinked-client.so"  --needed liblinked.so
./aster build-so  examples/so_math.ast        -o "$WORK/legacy_math.so"
$HOSTCC -O1 -o tmp-device-so-import-host tests/so-import-host.c -ldl
$HOSTCC -O1 -o tmp-device-so-host tests/so-host.c -ldl
ABS=$(pwd)/$WORK
runwith() { libpath=$1; shift; LD_LIBRARY_PATH="$libpath" $RUNNER "$@"; }
set +e
runwith "$ABS" ./tmp-device-so-import-host "$ABS/libdyn-import.so" "$ABS/liblinked.so" "$ABS/liblinked-client.so"
got=$?
set -e
[ "$got" -eq 0 ] || { echo "FAIL: cross-.so device host exited $got"; exit 1; }
echo "PASS: device dynamic linker loaded 3 mutually dependent shared objects; all cross-.so PLT/GOT calls matched"
set +e
runwith "$ABS" ./tmp-device-so-host "$ABS/legacy_math.so"
got=$?
set -e
[ "$got" -eq 0 ] || { echo "FAIL: legacy shared-object device host exited $got"; exit 1; }
echo "PASS: v0.17.0 single-source shared object (DT_HASH + R_AARCH64_RELATIVE) still loads on the device"
rm -rf "$WORK" tmp-device-so-import-host tmp-device-so-host
echo "PASS: all Aster v0.18.0 shared-object device tests"
echo "PASS: all Aster v0.17.0 function, argument, recursion, global-variable, linked-object, and static-PIE device tests"

# v0.21.0: check actual post-relocation page permissions, not only ELF structure.
sh tests/e2e-relro.sh
