#!/bin/sh
# tests/lib/verdict.sh — the exit-code protocol new or migrated suites use.
#
#   0   PASS   the suite ran and every assertion held
#   77  SKIP   the suite could not run as a whole; a reason is mandatory
#   1   FAIL   an assertion failed or the suite could not run meaningfully
#
# A *layer* may skip and the suite still PASS, as long as the harness prints
# "SKIP: <reason>" for that layer and exits 0 at the end.  Exit 77 is reserved
# for "the whole suite did not run", so tests/ci.sh can tell a missing-tool
# skip from a suite that executed and merely skipped an optional differential.
#
# Source this file; do not execute it:
#   . tests/lib/verdict.sh
#   aster_skip "qemu-aarch64 is not installed; behavioural layer not run"

ASTER_EXIT_PASS=0
ASTER_EXIT_SKIP=77
ASTER_EXIT_FAIL=1

# aster_skip "reason"
# Prints the reason and exits with the protocol's SKIP status.  The reason is
# mandatory: an unexplained skip is how a red dependency turns into a green
# run, which is the failure mode this protocol exists to stop.
aster_skip() {
    if [ "$#" -eq 0 ] || [ -z "$1" ]; then
        printf 'FAIL: aster_skip needs a reason\n' >&2
        exit "$ASTER_EXIT_FAIL"
    fi
    printf 'SKIP: %s\n' "$1"
    exit "$ASTER_EXIT_SKIP"
}

# aster_fail "reason"
aster_fail() {
    if [ "$#" -eq 0 ]; then
        printf 'FAIL: aster_fail needs a reason\n' >&2
    else
        printf 'FAIL: %s\n' "$1" >&2
    fi
    exit "$ASTER_EXIT_FAIL"
}

# aster_require_cmd CMD "reason"
# Skips the whole suite when CMD is not on PATH.
aster_require_cmd() {
    if [ "$#" -ne 2 ]; then
        printf 'FAIL: aster_require_cmd needs CMD and a reason\n' >&2
        exit "$ASTER_EXIT_FAIL"
    fi
    command -v "$1" >/dev/null 2>&1 || aster_skip "$2"
}

# aster_require_file PATH "reason"
aster_require_file() {
    if [ "$#" -ne 2 ]; then
        printf 'FAIL: aster_require_file needs PATH and a reason\n' >&2
        exit "$ASTER_EXIT_FAIL"
    fi
    [ -f "$1" ] || aster_skip "$2"
}
