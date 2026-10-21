#!/bin/sh
# tests/run-aarch64.sh — execute an Aster-produced AArch64 ELF transparently.
#
# The test suite builds AArch64 binaries regardless of host architecture. On an
# AArch64 host the binary runs natively; on any other host this wrapper runs it
# under qemu-aarch64 user-mode emulation (when available), so the same suite
# works on x86 CI runners and dev machines. Non-ELF64-AArch64 inputs (e.g. host
# C test programs) are executed directly, untouched.
#
# Usage: run-aarch64.sh <elf> [args...]
set -eu
bin="$1"; shift

# A guest that dies from a signal makes qemu dump *both* its own core and the
# guest's (hundreds of MB per run) into the current directory. Suites
# deliberately kill guests -- tests/runtime-bounds-checks.sh asserts on the
# SIGTRAP exit status -- so cores are disabled here rather than swept up later.
ulimit -c 0 2>/dev/null || true

# Read the first 20 bytes of a little-endian ELF64 header without executing
# anything: magic[4] class data version pad[9] e_type[2] e_machine[2].
# EM_AARCH64 = 0xb7. od prints one byte per field; strip whitespace to compare.
# Only the class, the endianness, the version and e_machine are read: EI_OSABI
# and the padding are whatever the producer wrote (0 for Aster, 3 for glibc),
# and e_type varies between ET_EXEC, ET_DYN and ET_REL callers.
hex=$(head -c 20 "$bin" 2>/dev/null | od -An -tx1 -v | tr -d ' \n')
host=$(uname -m)
case "$hex" in
    7f454c46020101??????????????????????b700) # ELF64 LE, EM_AARCH64 (40 hex chars)
        case "$host" in
            aarch64|arm64) exec "$bin" "$@" ;;
        esac
        if command -v qemu-aarch64 >/dev/null 2>&1; then
            # Cross-compiled host programs are dynamically linked against the
            # AArch64 sysroot; -L lets qemu's loader find it when present.
            if [ -d /usr/aarch64-linux-gnu ]; then
                exec qemu-aarch64 -L /usr/aarch64-linux-gnu "$bin" "$@"
            fi
            exec qemu-aarch64 "$bin" "$@"
        fi
        echo "run-aarch64: '$bin' is an AArch64 ELF but qemu-aarch64 is not on PATH" >&2
        exit 126
        ;;
    *) exec "$bin" "$@" ;; # host binary or non-ELF: run it directly
esac
