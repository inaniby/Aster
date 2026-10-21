#!/bin/sh
# v0.23.34-dev: empirical proof that the seven ANativeActivity lifecycle
# callbacks can be wired up and driven — the carry-forward item in README's
# "Android's bionic loader is not covered" note.
#
# native_render.ast and native_touch.ast fill the window/input callback slots
# (56..96) of ANativeActivityCallbacks but leave the first seven — the activity
# lifecycle — empty. Aster's function-name-as-address feature lets an Aster
# module populate them, but nothing exercised that path. This example does, and
# this script drives it the way Android would: load the module as a shared
# object, call ANativeActivity_onCreate, then call each of the seven installed
# entries and read the counters back.
#
# The instructions are the ones Android runs. Only the loader (glibc under qemu,
# not bionic on a phone) and the provider of __android_log_print (a host liblog
# stub, not liblog on the device) differ. Device-side confirmation stays a
# separate open item; what this closes is "does the callback table get filled
# in, at the right offsets, with functions that run".
#
# Layers:
#   [1] Strictly build the Aster compiler.
#   [2] Source guards — pin the seven offset assignments and the count routing.
#   [3] Build the shared object and assert its exported-symbol set (byte-stable
#       at the symbol level) — the example's contract with the host.
#   [4] Build the AArch64 test host and the liblog stub, then drive the callbacks
#       under qemu-aarch64 and assert every slot installs, runs, and counts.
#
# Run with HOSTCC=aarch64-linux-gnu-gcc RUNNER="qemu-aarch64 -L /usr/aarch64-linux-gnu"
# on an x86 runner, or natively on an AArch64 host.

cd "$(dirname "$0")/.."
CXX=${CXX:-c++}
HOSTCC=${HOSTCC:-cc}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-lifecycle-callbacks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# [1] Strictly build Aster.
# ---------------------------------------------------------------------------
printf '%s\n' '[1/4] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster" \
    || { echo 'FAIL: Aster does not build strictly' >&2; exit 1; }
A="$OUT/aster"

# ---------------------------------------------------------------------------
# [2] Source guards. The wiring is seven stores at fixed byte offsets into the
# callbacks table, plus a counter router keyed by index. Pin both so a refactor
# that moves an offset or drops a slot fails here, loudly.
# ---------------------------------------------------------------------------
printf '%s\n' '[2/4] Source guards for the lifecycle example'
EX=examples/lifecycle.ast
[ -f "$EX" ] || { echo "FAIL: $EX missing" >&2; exit 1; }
# The seven lifecycle slots, at offsets 0..48 (8 bytes each).
for off in 0 8 16 24 32 40 48; do
    grep -qF "*(cb + $off) =" "$EX" \
        || { echo "FAIL: lifecycle example no longer installs a callback at offset $off" >&2; exit 1; }
done
# onCreate returns 0 and fills from the activity's `callbacks` pointer.
grep -qF 'let cb: ptr = load_ptr(activity);' "$EX" \
    || { echo 'FAIL: ANativeActivity_onCreate no longer loads the callbacks pointer' >&2; exit 1; }
# The counter router answers -1 out of range and each index in range.
grep -qF 'if (which == 6) { return g_lowmem; }' "$EX" \
    || { echo 'FAIL: lifecycle count router dropped a slot' >&2; exit 1; }
grep -qF 'return -1;' "$EX" \
    || { echo 'FAIL: lifecycle count router no longer rejects out-of-range' >&2; exit 1; }

# ---------------------------------------------------------------------------
# [3] Build the shared object and assert its exported-symbol set. This is the
# byte-stable contract the host dlopen()s against; if a callback is renamed or
# dropped, the surface changes and the host cannot find it.
# ---------------------------------------------------------------------------
printf '%s\n' '[3/4] Build the shared object and check its exported symbols'
$A build-so examples/lifecycle.ast -o "$OUT/lifecycle.so" \
    || { echo 'FAIL: lifecycle.ast does not build as a shared object' >&2; exit 1; }
NM=$(command -v aarch64-linux-gnu-nm || command -v nm)
EXP="ANativeActivity_onCreate aster_lifecycle_count on_start on_resume on_pause \
on_stop on_destroy on_configuration_changed on_low_memory"
got=$($NM -D --defined-only "$OUT/lifecycle.so" 2>/dev/null | awk '{print $NF}')
for sym in $EXP; do
    printf '%s\n' "$got" | grep -qx "$sym" \
        || { echo "FAIL: lifecycle.so does not export $sym" >&2; exit 1; }
done
# And nothing extra in the contract beyond these nine.
n=$(printf '%s\n' "$got" | grep -xcE "$(printf '%s\n' $EXP | tr '\n' '|' | sed 's/|$//')")
[ "$n" -eq 9 ] || { echo "FAIL: lifecycle.so exports $n expected symbols, want 9" >&2; exit 1; }

# ---------------------------------------------------------------------------
# [4] Build the AArch64 host and the liblog stub, drive the callbacks, assert.
# The host must be AArch64 to dlopen an AArch64 .so, so a non-AArch64 HOSTCC on
# a non-AArch64 host cannot produce a runnable pair — skip rather than fail.
# ---------------------------------------------------------------------------
printf '%s\n' '[4/4] Build host + liblog stub and drive the callbacks under qemu'
machine=$($HOSTCC -dumpmachine 2>/dev/null || echo unknown)
case "$machine" in
    aarch64*|arm64*) ;;
    *) if [ "$(uname -m)" != aarch64 ] && [ "$(uname -m)" != arm64 ]; then
           printf '%s\n' "SKIP: lifecycle host needs an AArch64 HOSTCC (got $HOSTCC -> $machine); run with HOSTCC=aarch64-linux-gnu-gcc RUNNER=\"qemu-aarch64 -L /usr/aarch64-linux-gnu\""
           exit 0
       fi ;;
esac
$HOSTCC -shared -fPIC -o "$OUT/liblog.so" tests/liblog-stub.c \
    || { echo 'FAIL: cannot build host liblog stub' >&2; exit 1; }
$HOSTCC -O2 -fPIE -pie -o "$OUT/lc-host" tests/lifecycle-harness.c -ldl \
    || { echo 'FAIL: cannot build lifecycle host' >&2; exit 1; }

# The host dlopen()s lifecycle.so, whose one PLT import (__android_log_print)
# resolves against the liblog stub on LD_LIBRARY_PATH. run-aarch64.sh / qemu
# pass that environment to the guest loader.
LD_LIBRARY_PATH="$OUT" $RUNNER "$OUT/lc-host" "$OUT/lifecycle.so" >"$OUT/run.out" 2>"$OUT/run.err"
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "FAIL: lifecycle host exited $rc" >&2
    sed -n '1,20p' "$OUT/run.err" >&2 || true
    exit 1
fi
# The host prints the per-slot result; assert the key facts it reports.
grep -qF '7 callbacks installed at offsets 0..48 and driven' "$OUT/run.out" \
    || { echo 'FAIL: lifecycle host did not report all seven callbacks driven' >&2; exit 1; }
grep -qF 'count(0)=2' "$OUT/run.out" \
    || { echo 'FAIL: onStart counter did not accumulate to 2' >&2; exit 1; }
grep -qF 'count(7)=-1' "$OUT/run.out" \
    || { echo 'FAIL: out-of-range count(7) did not return -1' >&2; exit 1; }
# The liblog stub must have printed each lifecycle event to stderr.
for ev in onStart onResume onPause onStop onDestroy onConfigurationChanged onLowMemory; do
    grep -qF "[AsterLifecycle] $ev" "$OUT/run.err" \
        || { echo "FAIL: liblog stub did not log $ev" >&2; exit 1; }
done

printf '%s\n' 'PASS: the seven ANativeActivity lifecycle callbacks install at offsets 0..48, run, and count (AArch64 .so driven under qemu)'
