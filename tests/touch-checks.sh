#!/bin/sh
# v0.23.15-dev checks for the touch-input example (P2.3).
#
# native_touch.ast is the first interactive native app: it wires the
# ANativeActivityCallbacks slots (window callbacks 56/64/72/80, input queue
# 88/96), attaches an AInputQueue handler to Android's main looper, and on each
# motion event captures the float coordinates through the lrintf bridge and
# repaints a dot at the finger.
#
# v0.23.14-dev shipped this example broken on real hardware, three bugs deep,
# and all three are pinned by the layers below:
#   1. the input-queue callbacks were written at 80/88 — but 80 is
#      onNativeWindowDestroyed, so the framework called the "destroyed" handler
#      when the queue appeared and the attach never happened;
#   2. the event drain tested `got == 1` — AInputQueue_getEvent signals success
#      with 0 and a dry queue with a negative value (the 1/0 convention belongs
#      to AInputQueue_hasEvents), so the loop body never ran;
#   3. the coordinates were read as i32 from w0 — but a C `float` return lands
#      in s0, a different register file, so the decode consumed garbage.
#
# The riskiest part is the coordinate capture. Aster has no float type, so
# AMotionEvent_getX/Y are declared `-> i32` and the value is recovered by
# calling zero-argument lrintf() immediately after: lrintf reads its argument
# from s0 and returns a long in x0, whose low 32 bits Aster reads. Aster emits
# no SIMD instruction of its own and the PLT is eagerly bound, so nothing
# between the two calls disturbs s0 — but no other Aster call may be inserted
# between them. strtof (also a C function returning a float) stands in for getX
# in the qemu test, so the chain is determinable off-device; the actual
# on-screen touch is confirmed on a real arm64 device (the same boundary
# native_render ships under).
#
# Layers:
#   1. run under qemu: the strtof + lrintf capture chain converts exactly
#   2. source guards: externs, the 88/96 wiring, the >= 0 drain, the bridge
#   3. APK gate: native_touch builds, signs and validates, links libm too
#   4. a mutation that breaks the bridge must be caught by the qemu test
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-touch-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
ASTER=${ASTER:-./aster}

[ -x "$ASTER" ] || { echo 'FAIL: aster not built (run the strict build first)' >&2; exit 1; }

run_qemu() {   # $1 = elf; echoes the exit status, survives `set -e`
    set +e
    sh tests/run-aarch64.sh "$1" > /dev/null 2>&1
    echo $?
    set -e
}

printf '%s\n' '[1/4] Run under qemu: the lrintf bridge converts float returns exactly'
# build-so, not build-elf: extern calls go through the PLT, which only the
# shared-object path emits. The host harness then dlopens the result.
"$ASTER" build-so tests/touch-coord-test.ast -o "$OUT/libtouchcoord.so" --soname libtouchcoord.so > "$OUT/coord.log" 2>&1 \
    || { echo 'FAIL: touch-coord-test.ast did not build'; sed -n 's/^/    /p' "$OUT/coord.log" >&2; exit 1; }
if ! command -v qemu-aarch64 >/dev/null 2>&1; then
    printf '%s\n' 'SKIP: qemu-aarch64 not installed -- cannot run the capture test'
else
    # The harness runs under qemu and dlopens an AArch64 .so, so it must itself
    # be AArch64. $HOSTCC is the *native* compiler on an x86 runner (ci.sh sets
    # it to cc there), and an x86 harness dlopening this .so fails with a
    # misleading "No such file or directory" -- so probe for AArch64 capability
    # first and fall back to the cross toolchain, the same test
    # host-toolchain-probe.sh makes.
    GUESTCC=
    for cand in "${HOSTCC:-}" aarch64-linux-gnu-gcc; do
        [ -n "$cand" ] || continue
        command -v "$cand" >/dev/null 2>&1 || continue
        probe=$(mktemp)
        if echo 'int main(){return 0;}' | "$cand" -x c - -o "$probe" 2>/dev/null \
           && head -c 20 "$probe" 2>/dev/null | od -An -tx1 -v | tr -d ' \n' | grep -q 'b700$'; then
            rm -f "$probe"; GUESTCC=$cand; break
        fi
        rm -f "$probe"
    done
    if [ -z "$GUESTCC" ]; then
        printf '%s\n' 'SKIP: no AArch64-capable C compiler -- cannot build the dlopen harness'
    else
        "$GUESTCC" -O1 -o "$OUT/touch-coord-host" tests/touch-coord-host.c -ldl > "$OUT/host.log" 2>&1 \
            || { echo 'FAIL: touch-coord-host.c did not compile'; sed -n 's/^/    /p' "$OUT/host.log" >&2; exit 1; }
        # DT_NEEDED carries the Android sonames libc.so/libm.so; make real
        # AArch64 libraries visible under those names for the guest loader.
        . tests/guest-libc-alias.sh
        provide_guest_libc_alias "$OUT"
        provide_guest_libm_alias "$OUT"
        ABS_OUT=$(cd "$OUT" && pwd)
        set +e
        out=$(LD_LIBRARY_PATH="$ABS_OUT" sh tests/run-aarch64.sh "$OUT/touch-coord-host" "$ABS_OUT/libtouchcoord.so" 2>&1); st=$?
        set -e
        printf '%s\n' "    $out"
        [ "$st" = 0 ] || { echo "FAIL: capture chain exited $st, expected 0" >&2; exit 1; }
        printf '%s\n' 'PASS: 0.0/1042.0/768.0/3000.0/123.0/1042.5/1919.5/-12.0 captured exactly'
    fi
fi

printf '%s\n' '[2/4] Source guards: externs, 88/96 wiring, >= 0 drain, lrintf bridge'
grep -qF 'extern fn AInputQueue_attachLooper(queue: ptr, looper: ptr, ident: i32, cb: ptr, data: ptr) -> i32;' examples/native_touch.ast \
    || { echo 'FAIL: AInputQueue_attachLooper extern is gone' >&2; exit 1; }
grep -qF 'extern fn AMotionEvent_getX(event: ptr, pointerIndex: i32) -> i32;' examples/native_touch.ast \
    || { echo 'FAIL: AMotionEvent_getX extern is gone' >&2; exit 1; }
grep -qF 'extern fn AMotionEvent_getY(event: ptr, pointerIndex: i32) -> i32;' examples/native_touch.ast \
    || { echo 'FAIL: AMotionEvent_getY extern is gone' >&2; exit 1; }
grep -qF 'extern fn lrintf() -> i32;' examples/native_touch.ast \
    || { echo 'FAIL: the lrintf bridge extern is gone' >&2; exit 1; }
grep -qF 'extern fn ALooper_forThread() -> ptr;' examples/native_touch.ast \
    || { echo 'FAIL: ALooper_forThread extern is gone' >&2; exit 1; }
# The wiring: 80 is onNativeWindowDestroyed, 88 onInputQueueCreated, 96
# onInputQueueDestroyed (android/native_activity.h, all pointers).
grep -qF '*(cb + 80) = on_native_window_destroyed;' examples/native_touch.ast \
    || { echo 'FAIL: onNativeWindowDestroyed is no longer wired at offset 80' >&2; exit 1; }
grep -qF '*(cb + 88) = on_input_queue_created;' examples/native_touch.ast \
    || { echo 'FAIL: onInputQueueCreated is no longer wired at offset 88' >&2; exit 1; }
grep -qF '*(cb + 96) = on_input_queue_destroyed;' examples/native_touch.ast \
    || { echo 'FAIL: onInputQueueDestroyed is no longer wired at offset 96' >&2; exit 1; }
grep -qF 'AInputQueue_attachLooper(queue, looper, 1, on_looper_input, g_null);' examples/native_touch.ast \
    || { echo 'FAIL: the looper is no longer attached in on_input_queue_created' >&2; exit 1; }
# The drain: getEvent returns 0 on success, negative when dry.
grep -qF 'while (got >= 0) {' examples/native_touch.ast \
    || { echo 'FAIL: the event drain no longer tests got >= 0' >&2; exit 1; }
# Pre-dispatch: non-zero means abandon the event without finishEvent.
grep -qF 'if (pre == 0) {' examples/native_touch.ast \
    || { echo 'FAIL: the preDispatchEvent branch is gone' >&2; exit 1; }
# The bridge helpers exist, and each keeps its two calls adjacent: nothing may
# sit between the float call and the lrintf that reads s0.
grep -qF 'fn event_x(ev: ptr) -> i32 {' examples/native_touch.ast \
    || { echo 'FAIL: the event_x bridge helper is gone' >&2; exit 1; }
grep -qF 'fn event_y(ev: ptr) -> i32 {' examples/native_touch.ast \
    || { echo 'FAIL: the event_y bridge helper is gone' >&2; exit 1; }
grep -cF 'return lrintf();' examples/native_touch.ast | grep -qx 2 \
    || { echo 'FAIL: expected exactly 2 lrintf bridge returns, got another count' >&2; exit 1; }
if ! awk '
    /let junk: i32 = AMotionEvent_getX\(ev, 0\);/ { if ((getline nxt) > 0 && nxt ~ /^[ \t]*return lrintf\(\);[ \t]*$/) xok = 1 }
    /let junk: i32 = AMotionEvent_getY\(ev, 0\);/ { if ((getline nxt) > 0 && nxt ~ /^[ \t]*return lrintf\(\);[ \t]*$/) yok = 1 }
    END { exit (xok && yok) ? 0 : 1 }
' examples/native_touch.ast; then
    echo 'FAIL: a float call is no longer immediately followed by its lrintf' >&2; exit 1
fi
# The v0.23.14-dev bit-pattern decoder is gone: the bridge replaced it.
if grep -qF 'fn motion_coord' examples/native_touch.ast; then
    echo 'FAIL: the superseded motion_coord decoder is still in the example' >&2; exit 1
fi
printf '%s\n' 'PASS: touch externs, 88/96 wiring, >= 0 drain and lrintf bridge present'

printf '%s\n' '[3/4] APK gate: native_touch builds, signs and validates'
KEY="$OUT/keys"; mkdir -p "$KEY"
"$ASTER" build-apk examples/native_touch.ast -o "$OUT/native_touch.apk" \
    --package com.aster.nativeapp --libname nativeapp \
    --label "Aster Touch" --min-sdk 24 --target-sdk 34 \
    --version-code 1 --version-name "1.0" --keystore-dir "$KEY" \
    --emit-so "$OUT/native_touch.so" > "$OUT/apk.log" 2>&1 \
    || { echo 'FAIL: native_touch build-apk failed'; sed -n 's/^/    /p' "$OUT/apk.log" >&2; exit 1; }
python3 tests/validate_apk.py "$OUT/native_touch.apk" \
    --package com.aster.nativeapp --libname nativeapp --label "Aster Touch" --label-literal > "$OUT/val.log" 2>&1 \
    || { echo 'FAIL: validate_apk.py rejected native_touch'; sed -n 's/^/    /p' "$OUT/val.log" >&2; exit 1; }
"$ASTER" verify-apk "$OUT/native_touch.apk" > "$OUT/ver.log" 2>&1 \
    || { echo 'FAIL: aster verify-apk rejected native_touch'; sed -n 's/^/    /p' "$OUT/ver.log" >&2; exit 1; }
# The .so inside must link: libandroid for the input queue, liblog for the
# diagnostics, libm for the lrintf bridge, libc for the rest.
for lib in libandroid.so liblog.so libm.so libc.so; do
    readelf -d "$OUT/native_touch.so" 2>/dev/null | grep -qF "$lib" \
        || { echo "FAIL: native_touch .so is missing the $lib DT_NEEDED" >&2; exit 1; }
done
printf '%s\n' 'PASS: native_touch APK builds, v1+v2 signs, validates, links libandroid/liblog/libm/libc'

printf '%s\n' '[4/4] Mutation: a broken bridge must fail the qemu test'
# The anchor must still exist exactly once, so the mutation is meaningful
# (not a silent no-op).
grep -cF 'return lrintf();' tests/touch-coord-test.ast | grep -qx 1 \
    || { echo 'FAIL: anchor for the bridge appears != 1 time; the mutation guard is blind' >&2; exit 1; }
# Copy, replace the bridge with the raw i32 result — the v0.23.14-dev bug,
# reading w0 where the C float actually sits in s0 — rebuild, dlopen, run.
cp tests/touch-coord-test.ast "$OUT/coord-broken.ast"
sed -i 's/return lrintf();/return junk;/' "$OUT/coord-broken.ast"
"$ASTER" build-so "$OUT/coord-broken.ast" -o "$OUT/libtouchcoord-broken.so" --soname libtouchcoord.so > "$OUT/broken.log" 2>&1 \
    || { echo 'FAIL: the broken bridge still built'; exit 1; }
if ! command -v qemu-aarch64 >/dev/null 2>&1; then
    printf '%s\n' 'SKIP: qemu-aarch64 not installed -- mutation not run'
elif [ ! -x "$OUT/touch-coord-host" ]; then
    printf '%s\n' 'SKIP: dlopen harness not built -- mutation not run'
else
    set +e
    out=$(LD_LIBRARY_PATH="$ABS_OUT" sh tests/run-aarch64.sh "$OUT/touch-coord-host" "$OUT/libtouchcoord-broken.so" 2>&1); st=$?
    set -e
    [ "$st" != 0 ] || { echo "FAIL: a broken capture chain still exited 0 ($out)" >&2; exit 1; }
    printf '%s\n' "PASS: reading w0 instead of bridging is caught (exit $st, not 0)"
fi

printf '%s\n' 'ALL TOUCH CHECKS PASSED'
