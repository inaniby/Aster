#!/bin/sh
# tests/lib/linkmode.sh - v0.23.77-dev
#
# -static is the portable choice (qemu needs it for a foreign target), but
# Android's libc ships no crtbegin_static.o, so every `cc -static` fails there.
# When the device *is* the target, a dynamically linked program runs natively
# just as well, so the mode is probed once and then used everywhere:
#
#   . tests/lib/linkmode.sh <work-dir> <runner>
#   "$HOSTCC" ... -o out $LINKSTATIC      # a link with the probe's mode
#
# The caller must have HOSTCC set. `linkmode_probe` answers yes/no.
linkmode_probe() {  # $1 = work dir, $2 = runner command
    LINKSTATIC=-static
    printf 'int main(void){return 0;}\n' > "$1/lm_probe.c"
    if "$HOSTCC" -O2 -fwrapv -static "$1/lm_probe.c" -o "$1/lm_probe" >/dev/null 2>&1; then
        :
    elif "$HOSTCC" -O2 -fwrapv "$1/lm_probe.c" -o "$1/lm_probe" >/dev/null 2>&1; then
        LINKSTATIC=
    else
        return 1
    fi
    if "$2" "$1/lm_probe" >/dev/null 2>&1; then return 0; fi
    # a non-zero exit from the probe binary is fine; unreachable is not
    [ -x "$1/lm_probe" ] && return 0
    return 1
}
