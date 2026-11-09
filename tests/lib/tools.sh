# tests/lib/tools.sh — the binutils this host actually has, resolved once.
#
# These suites name aarch64-linux-gnu-* directly, which is right on an x86 CI
# host with the cross toolchain installed. On a native AArch64 host (Termux on
# a phone, an ARM runner) the target *is* the host, so the plain names are the
# same tools for the same target — and the cross names do not exist. Resolve
# both spellings in one place:
#
#   . tests/lib/tools.sh
#   [ -n "$AST_READELF" ] || { echo 'SKIP: no readelf' >&2; exit 0; }
#   "$AST_READELF" -h out.elf | grep -q EXEC
#
# An empty AST_* means the tool is genuinely absent; a suite that needs it must
# say so rather than run an empty command.
AST_READELF=${AST_READELF:-$(command -v aarch64-linux-gnu-readelf 2>/dev/null || command -v readelf 2>/dev/null || command -v llvm-readelf 2>/dev/null || true)}
AST_OBJDUMP=${AST_OBJDUMP:-$(command -v aarch64-linux-gnu-objdump 2>/dev/null || command -v objdump 2>/dev/null || command -v llvm-objdump 2>/dev/null || true)}
AST_OBJCOPY=${AST_OBJCOPY:-$(command -v aarch64-linux-gnu-objcopy 2>/dev/null || command -v objcopy 2>/dev/null || command -v llvm-objcopy 2>/dev/null || true)}

# aster_hostcc_link OUT [ARGS...] — link a C twin, preferring -static.
#
# The suites link their C twins with -static because that is what makes a
# cross-built binary runnable under qemu-user. A native AArch64 toolchain
# (Termux on a phone) has no libc.a or crtbegin_static, and every twin here is
# integer-only, so a plain dynamic link is the same oracle. Call it as
#
#   aster_hostcc_link "$W/twin" -O2 tests/foo-twin.c || { echo ...; exit 1; }
#
# Note it adds -O2 itself; pass only the sources and any extra flags.
aster_hostcc_link() {
    _out=$1; shift
    "$HOSTCC" -O2 -static "$@" -o "$_out" >/dev/null 2>&1 && return 0
    "$HOSTCC" -O2 "$@" -o "$_out" >/dev/null 2>&1 && return 0
    return 1
}
