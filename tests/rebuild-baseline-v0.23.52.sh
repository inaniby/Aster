#!/bin/sh
# tests/rebuild-baseline-v0.23.52.sh — re-record the byte-identity baseline
# after Round E (thread-local storage in a shared object: .tbss, PT_TLS in a
# .so, initial-exec).
#
# This round is narrower than Round D in one important way, and the script says
# so. Round D added three mandatory sections to both .so writers, so every
# build-so row necessarily moved. Round E touches only what a program that
# declares `tls` produces:
#
#   * build-elf / build-obj --pic: every row reproduces byte for byte EXCEPT
#     tls_demo's two. The block is two sections now (.tdata gains SHF_WRITE,
#     which GNU ld also sets, and .tbss follows it), and __aster_tls_block's
#     size is its own section's rather than the whole block's, so the only
#     example in the tree that uses `tls` legitimately moves. 228 rows
#     identical, 2 moved.
#
#   * build-so: every row reproduces byte for byte EXCEPT tls_demo's, which
#     flips the other way — it was FAILED by design in Round D ("a shared
#     object rejects `tls`") and is now a real hash, because this round is
#     exactly that rejection being lifted. A .so with no `tls` writes the same
#     bytes it did: no PT_TLS segment, no .tdata/.tbss section, no change to
#     any offset or count. 114 rows identical, 1 FAILED row becomes a hash.
#
# The round adds one example: examples/so_tls_demo.ast, whose build-so row is a
# real hash and whose build-elf row is FAILED by design (it has no main — it is
# a library, like so_verstrlen). Its three rows are the only new ones.
#
# Post-round refinement: so_tls_demo.ast now also carries two thread-local
# ARRAYS (a mutable .tdata one exercised by `accsum`, a mutable .tbss one by
# `zerosum`), closing the "scalar + array" TLS claim for the .so path. The
# example's source changed, so its two real-hash rows (build-so,
# build-obj --pic) moved; the build-elf row is still FAILED. Example count is
# unchanged at 116, so the 348-row identity below still holds.
#
# The byte comparison is a line-by-line comparison of two files written in the
# order `examples/*.ast` globs, so it is only reproducible if that order is
# fixed: in an en_US.UTF-8 locale the shell sorts `condition.ast` before
# `c_ptr_*.ast` (the underscore is elided), in the C locale after, and the
# baseline recorded here is the C one. Pinning the collation keeps the round
# trip independent of whoever runs it.
LC_ALL=C
export LC_ALL
set -eu
cd "$(dirname "$0")/.."
OUT=tmp-baseline
rm -rf "$OUT"; mkdir -p "$OUT"
g++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror -o "$OUT/aster" src/aster.cpp
: > "$OUT/hashes.txt"
for mode in build-so build-elf "build-obj --pic"; do
    tag=$(echo "$mode" | tr ' ' '_')
    for f in examples/*.ast; do
        b=$(basename "$f" .ast)
        # shellcheck disable=SC2086
        if "$OUT/aster" $mode "$f" -o "$OUT/$b.$tag" >/dev/null 2>&1; then
            printf '%s %s\n' "$b.$tag" "$(sha256sum "$OUT/$b.$tag" | cut -d' ' -f1)" >> "$OUT/hashes.txt"
        else
            printf '%s FAILED\n' "$b.$tag" >> "$OUT/hashes.txt"
        fi
    done
done
cp tests/baseline/v0.23.5-dev/example-hashes.txt "$OUT/old.txt"
old=$(wc -l < "$OUT/old.txt")
total=$(wc -l < "$OUT/hashes.txt")
[ "$total" -eq 348 ] \
    || { echo "FAIL: expected 348 rows total (116 examples x 3 modes), found $total" >&2; exit 1; }
# Two modes, because the script is only ever run once per round but may be
# re-run after the round is closed (to confirm the tree still reproduces the
# recorded baseline). When it starts from the pre-round 345-row baseline it
# asserts the per-mode delta this round is allowed; when it starts from the
# post-round 348-row baseline it asserts byte-for-byte identity.
python3 - "$OUT/old.txt" "$OUT/hashes.txt" <<'PY' || exit 1
import sys
def load(p):
    out = {}
    for line in open(p):
        k, v = line.split()
        out[k] = v
    return out
old, new = load(sys.argv[1]), load(sys.argv[2])
violations = []
if len(old) == 345 and len(new) == 348:
    # pre-round baseline -> record the round's delta
    # The only rows allowed to move: the one example in the tree that declares
    # `tls`. Its two static rows change shape (.tdata gains SHF_WRITE and gains
    # a .tbss behind it); its build-so row stops being FAILED, which is the round.
    ALLOWED_MOVED = {'tls_demo.build-elf', 'tls_demo.build-obj_--pic', 'tls_demo.build-so'}
    for k in old:
        if new.get(k) == old[k]:
            continue
        if k not in ALLOWED_MOVED:
            violations.append(('an unrelated row moved', k, old[k], new.get(k)))
    static = [k for k in old if not k.endswith('.build-so')]
    static_same = sum(1 for k in static if new.get(k) == old[k])
    if len(static) != 230:
        violations.append(('expected 230 static rows', len(static)))
    if static_same != 228:
        violations.append(('expected exactly 228 byte-identical static rows', static_same))
    so = [k for k in old if k.endswith('.build-so')]
    so_same = sum(1 for k in so if new.get(k) == old[k])
    if len(so) != 115:
        violations.append(('expected 115 build-so rows', len(so)))
    if so_same != 114:
        violations.append(('expected exactly 114 byte-identical build-so rows', so_same))
    if old['tls_demo.build-so'] != 'FAILED':
        violations.append(('tls_demo.build-so was no longer FAILED on disk',))
    if new['tls_demo.build-so'] == 'FAILED':
        violations.append(('tls_demo.build-so is still FAILED — a .so still rejects `tls`',))
    for k in so:
        if old[k] == 'FAILED' and k != 'tls_demo.build-so' and new.get(k) != 'FAILED':
            violations.append(('a FAILED build-so row became a hash', k))
    extra = sorted(k for k in new if k not in old)
    if extra != ['so_tls_demo.build-elf', 'so_tls_demo.build-obj_--pic', 'so_tls_demo.build-so']:
        violations.append(('unexpected new rows', extra))
    want_failed = {'so_tls_demo.build-elf'}          # no main: it is a library
    for k in extra:
        is_failed = new[k] == 'FAILED'
        if is_failed != (k in want_failed):
            violations.append(('a new example row has the wrong FAILED/hash shape', k, new[k]))
    if violations:
        for v in violations[:20]:
            print('VIOLATION:', *v, file=sys.stderr)
        sys.exit(1)
    print('PASS: %d static rows byte-identical (2 moved: tls_demo), %d build-so rows '
          'byte-identical (1 moved: tls_demo FAILED -> hash)' % (static_same, so_same))
elif len(old) == 348 and len(new) == 348:
    # already-rounded baseline -> just confirm byte-for-byte identity
    for k in old:
        if new.get(k) != old[k]:
            violations.append(('baseline drift', k, old[k], new.get(k)))
    if violations:
        for v in violations[:20]:
            print('VIOLATION:', *v, file=sys.stderr)
        sys.exit(1)
    print('PASS: 348 baseline rows byte-identical to current source (no drift)')
else:
    print('FAIL: unexpected baseline row counts old=%d new=%d' % (len(old), len(new)), file=sys.stderr)
    sys.exit(1)
PY
echo "OK: $old baseline lines on disk -> $total rows re-recorded (3 new)"
cp "$OUT/hashes.txt" tests/baseline/v0.23.5-dev/example-hashes.txt
rm -rf "$OUT"
echo "baseline re-recorded: tests/baseline/v0.23.5-dev/example-hashes.txt"
