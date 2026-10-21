# tests/guest-libc-alias.sh — sourced by the e2e shared-object tests.
#
# Aster's auto-DT_NEEDED (v0.22.40) emits the *Android* soname "libc.so" for
# extern imports that match no NDK library. On Android that is exactly right.
# On a glibc host (e.g. running the suite under qemu-user) the guest loader
# would instead resolve the bare name "libc.so" against the host's x86 libc
# ("invalid ELF header"). The alias below makes an AArch64 libc visible under
# the expected name through LD_LIBRARY_PATH, so guest .so files with an auto
# libc.so dependency still load on a development machine. On a real Android
# host none of these paths exist and the function is a no-op.
provide_guest_libc_alias() {
    dir=$1
    [ -e "$dir/libc.so" ] && return 0
    for c in /usr/aarch64-linux-gnu/lib/libc.so.6 \
             /lib/aarch64-linux-gnu/libc.so.6 \
             /usr/lib/aarch64-linux-gnu/libc.so.6; do
        if [ -e "$c" ]; then
            ln -sf "$c" "$dir/libc.so"
            return 0
        fi
    done
    return 0
}

# v0.23.15-dev: the same alias for libm. The lrintf bridge in native_touch.ast
# (and the strtof+lrintf chain in tests/touch-coord-test.ast) puts libm.so in
# DT_NEEDED, so the guest loader needs a real AArch64 libm under that name too.
provide_guest_libm_alias() {
    dir=$1
    [ -e "$dir/libm.so" ] && return 0
    for c in /usr/aarch64-linux-gnu/lib/libm.so.6 \
             /lib/aarch64-linux-gnu/libm.so.6 \
             /usr/lib/aarch64-linux-gnu/libm.so.6; do
        if [ -e "$c" ]; then
            ln -sf "$c" "$dir/libm.so"
            return 0
        fi
    done
    return 0
}
