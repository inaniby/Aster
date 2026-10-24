#!/bin/sh
# tests/rebuild-baseline-v0.23.51.sh — re-record the byte-identity baseline
# after Round D (thread-local storage + symbol versioning).
#
# This round's script differs from its predecessors, and the difference is the
# point. Rounds A–C shipped emitter-neutral work (new tokens, new examples), so
# their scripts could demand that *every* pre-existing row reproduce byte for
# byte. Round D adds three mandatory ELF sections to both shared-object writers
# (.gnu.version / .gnu.version_d / .gnu.version_r) and five .dynamic tags, so
# every successfully built .so necessarily changes — a byte-identical build-so
# row would now be the regression. The invariant splits by build mode:
#
#   * build-elf and build-obj --pic: every old row reproduces byte for byte.
#     The round touched only the two .so writers (plus the tls context keyword
#     and the entry stub, neither of which moves a program that does not use
#     `tls`). 226 rows, all identical.
#
#   * build-so: every old real-hash row must change (109 of them — the version
#     triad is unconditional in both writers), and every old FAILED row must
#     stay FAILED (4: call-stmt, cb_table, fn_ret, fn_type — no main to export).
#     A row that became FAILED, or a FAILED row that became a hash, is a
#     regression this check must not wave through.
#
# The round adds two examples (six rows): examples/tls_demo.ast — its build-so
# row is FAILED by design (a shared object refuses `tls`), the other two are
# real hashes; and examples/so_verstrlen.ast — its build-elf row is FAILED by
# design (it imports strlen), the other two are real hashes. A future round
# that made any of them FAILED (or any FAILED row real) would be a regression.
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
g++ -std=c++17 -O2 -Wall -Wextra -Werror -o "$OUT/aster" src/aster.cpp
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
[ "$old" -eq 339 ] \
    || { echo "FAIL: expected 339 baseline rows on disk, found $old" >&2; exit 1; }
[ "$total" -eq 345 ] \
    || { echo "FAIL: expected 345 rows total (115 examples x 3 modes), found $total" >&2; exit 1; }
# The whole check runs in python: it compares the two tables row by row, applies
# the mode-specific rule, and names every violation before the script writes
# anything. A FAILED row is not a regression by itself — 50 examples import
# symbols only a link or a libc can supply, and 4 have no main to export — the
# rule below is what matters.
python3 - "$OUT/old.txt" "$OUT/hashes.txt" <<'PY' || exit 1
import sys
def load(p):
    out = {}
    for line in open(p):
        k, v = line.split()
        out[k] = v
    return out
old, new = load(sys.argv[1]), load(sys.argv[2])
assert len(old) == 339 and len(new) == 345, (len(old), len(new))
new_examples = {'tls_demo', 'so_verstrlen'}
violations = []
# 1. build-elf / build-obj --pic: every old row reproduces byte for byte.
static = [k for k in old if not k.endswith('.build-so')]
for k in static:
    if new.get(k) != old[k]:
        violations.append(('a static-image row moved', k, old[k], new.get(k)))
# 2. build-so: every old real hash must change; every old FAILED must stay FAILED.
changed = failed_kept = 0
for k in old:
    if not k.endswith('.build-so'):
        continue
    if old[k] == 'FAILED':
        if new.get(k) != 'FAILED':
            violations.append(('a FAILED build-so row became a hash', k))
        else:
            failed_kept += 1
    else:
        if new.get(k) == 'FAILED':
            violations.append(('a build-so row became FAILED', k))
        elif new.get(k) == old[k]:
            violations.append(('a build-so row did not move — the version triad is missing', k))
        else:
            changed += 1
if changed != 109:
    violations.append(('expected exactly 109 changed build-so rows', changed))
if failed_kept != 4:
    violations.append(('expected exactly 4 FAILED build-so rows kept', failed_kept))
# 3. The new rows: only the two new examples', with the documented shape.
extra = [k for k in new if k not in old]
if sorted(extra) != sorted(
        ['tls_demo.build-so', 'tls_demo.build-elf', 'tls_demo.build-obj_--pic',
         'so_verstrlen.build-so', 'so_verstrlen.build-elf', 'so_verstrlen.build-obj_--pic']):
    violations.append(('unexpected new rows', sorted(extra)))
want_failed = {'tls_demo.build-so', 'so_verstrlen.build-elf'}
for k in extra:
    is_failed = new[k] == 'FAILED'
    if is_failed != (k in want_failed):
        violations.append(('a new example row has the wrong FAILED/hash shape', k, new[k]))
if violations:
    for v in violations[:20]:
        print('VIOLATION:', *v, file=sys.stderr)
    sys.exit(1)
print('PASS: %d static rows byte-identical; %d build-so rows moved; %d FAILED kept'
      % (len(static), changed, failed_kept))
PY
echo "OK: $old baseline lines on disk -> $total rows re-recorded (6 new)"
cp "$OUT/hashes.txt" tests/baseline/v0.23.5-dev/example-hashes.txt
rm -rf "$OUT"
echo "baseline re-recorded: tests/baseline/v0.23.5-dev/example-hashes.txt"
