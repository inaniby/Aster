# tests/lib/tmpdir.sh — the scratch directory a suite writes through.
#
# Suites used to name /tmp directly. That is right on a Linux CI box and
# impossible on Termux, where /tmp is not writable (SELinux denies it): every
# test that needs scratch space fails with "can't create temporary file
# /data/local/...". CI therefore points TMPDIR at $HOME/tmp on Termux, and the
# suites spell the directory $TMPD so both hosts work:
#
#   . tests/lib/tmpdir.sh
#   "$ASTER" build-so examples/so_math.ast -o "$TMPD/so_math.so"
#
# A suite that also runs python passes it along, since a quoted heredoc does not
# expand $TMPD: python3 - "$TMPD" <<'PY' ... sys.argv[1] ... PY
TMPD=${TMPDIR:-/tmp}
if [ ! -d "$TMPD" ]; then
    mkdir -p "$TMPD" 2>/dev/null || { TMPD=/tmp; mkdir -p "$TMPD" 2>/dev/null || true; }
fi
if [ ! -w "$TMPD" ]; then
    echo "FAIL: the scratch directory $TMPD is not writable" >&2
    exit 1
fi
export TMPD
