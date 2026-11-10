#!/usr/bin/env python3
"""Single source of truth for the library core the bootstrap stage carries.

The M4 stage (`bootstrap/aster.ast`) is self-contained by design: a standalone
ET_EXEC cannot reference an external symbol (its own first `extern fn` call
hits CODEGEN-SPEC §10 C9), so the stage cannot *link* the library. What it can
do is carry the library's subset-safe core — `stdlib/aster_core.ast` — as a
generated region, exactly as it carries its token and node tables. One source
of truth, no copy that can drift, and the stage still links against nothing.

Usage:
    python3 bootstrap/gen_core_region.py            rewrite the region
    python3 bootstrap/gen_core_region.py --check    verify the region matches
                                                    (no writes; exit 1 on drift)
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
STAGE = os.path.join(HERE, "aster.ast")
CORE = os.path.join(ROOT, "stdlib", "aster_core.ast")

BEGIN = "// ---- BEGIN GENERATED: library core (bootstrap/gen_core_region.py) ----"
END = "// ---- END GENERATED: library core ----"


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def emit(region):
    """The region: a banner, then the core's routines verbatim (its own file
    header is dropped — that text belongs to stdlib/aster_core.ast)."""
    body = read(CORE)
    cut = body.find("\n// ")
    # strip the leading file comment block down to the first `fn `
    start = body.find("\nfn ")
    if start < 0:
        sys.stderr.write("gen_core_region.py: stdlib/aster_core.ast holds no functions\n")
        sys.exit(2)
    routines = body[start + 1:].rstrip() + "\n"
    banner = (
        "// The library's subset-safe core, generated from stdlib/aster_core.ast by\n"
        "// bootstrap/gen_core_region.py — edit that file, not this region. It is the\n"
        "// part of the library the stage's own subset can hold (CODEGEN-SPEC §10 C9\n"
        "// means it cannot *call* an external symbol at all), so the stage carries it\n"
        "// instead of linking it, and both compilers run the same bytes.\n"
    )
    return BEGIN + "\n" + banner + "\n" + routines + "\n" + END + "\n"


def main():
    stage = read(STAGE)
    i = stage.find(BEGIN)
    if i < 0:
        sys.stderr.write("gen_core_region.py: the BEGIN marker is missing from bootstrap/aster.ast\n")
        sys.exit(2)
    j = stage.find(END, i)
    if j < 0:
        sys.stderr.write("gen_core_region.py: the END marker is missing from bootstrap/aster.ast\n")
        sys.exit(2)
    j += len(END)
    region = emit(True)
    new = stage[:i] + region.rstrip("\n") + stage[j:]
    if "--check" in sys.argv[1:]:
        if new != stage:
            sys.stderr.write("gen_core_region.py: the library core region is stale — "
                             "re-run: python3 bootstrap/gen_core_region.py\n")
            sys.exit(1)
        print("gen_core_region.py --check: the region matches stdlib/aster_core.ast")
        return 0
    if new != stage:
        with open(STAGE, "w", encoding="utf-8", newline="") as f:
            f.write(new)
    n = sum(1 for line in region.splitlines() if line.startswith("fn "))
    print("gen_core_region.py: %d routines from stdlib/aster_core.ast written into bootstrap/aster.ast" % n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
