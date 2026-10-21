# tests/host-toolchain-probe.sh — sourced by every e2e test at the very top.
#
# The e2e tests link Aster's AArch64 output into target-architecture test hosts
# compiled by $HOSTCC and run them (natively on AArch64, or under qemu-user
# elsewhere). When $HOSTCC cannot emit AArch64 ELF, the test cannot run at all;
# in that case say so and exit successfully (SKIP), so the rest of the suite is
# unaffected and the reason is visible.
#
#   HOSTCC=aarch64-linux-gnu-gcc sh tests/e2e-*.sh   # typical dev machine
#
# Control flow: this file is *sourced*, so `return` continues the caller and
# `exit` terminates it — a skip exits, a successful probe returns.
HOSTCC=${HOSTCC:-cc}
if ! command -v "$HOSTCC" >/dev/null 2>&1; then
    echo "SKIP: $0 needs \$HOSTCC=$HOSTCC on PATH" >&2
    exit 0
fi
probe=$(mktemp 2>/dev/null || echo /tmp/aster-hostprobe.$$)
if echo 'int main(){return 0;}' | "$HOSTCC" -x c - -o "$probe" 2>/dev/null \
   && head -c 20 "$probe" 2>/dev/null | od -An -tx1 -v | tr -d ' \n' | grep -q 'b700$'; then
    rm -f "$probe"
    return 0
fi
rm -f "$probe"
echo "SKIP: $0 ($HOSTCC cannot emit AArch64 ELF; try HOSTCC=aarch64-linux-gnu-gcc)" >&2
exit 0
