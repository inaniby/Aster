#!/usr/bin/env python3
"""Single source of truth for the M3b node kinds, type tags and packed names.

Emits two artifacts from one set of lists (bootstrap/PARSER-SPEC.md §13):

  * the GENERATED region of bootstrap/aster.ast — the 25 E_* constants, the
    9 S_* constants, the 5 N_* constants, the 7 TY_* constants, and four
    packed name tables: `entab` (36 records, the host's full Expr::Kind list
    so a kind's record sits at its own number), `sntab` (12 records,
    Stmt::Kind), `nntab` (5 records, the structural kinds) and `tytab`
    (7 records, the type spellings);
  * tests/parser_names.h — the C twin's enums of the same codes, the same
    four name arrays, and the type enum.

Deterministic and idempotent: running it twice changes nothing. The region
inside bootstrap/aster.ast is replaced in place between the BEGIN/END markers;
hand-written code is never touched.

Before emitting, the lists are cross-checked against src/aster.cpp itself —
the `enum Kind` inside `struct Expr` and inside `struct Stmt` — and the subset
must be a subsequence of the host's, in the host's order. A node set that
drifts between this file and the host compiler fails here rather than in the
differential suite. Any change to the node set lands in this file first, then
in src/aster.cpp — never the other way round.

Usage:
    python3 bootstrap/gen_parser_names.py            regenerate both artifacts
    python3 bootstrap/gen_parser_names.py --check    verify the on-disk files
                                                    are what this would emit
                                                    (no writes; exit 1 on drift)
"""

import os
import re
import sys

# ---------------------------------------------------------------------------
# The host's expression kinds, in the exact order of `enum Kind` inside
# `struct Expr` in src/aster.cpp. The number is part of the contract
# (PARSER-SPEC.md §2.1): the dump prints names, but both implementations and
# this generator key off the number.
# ---------------------------------------------------------------------------
EXPR_KINDS = [
    "Num", "Var", "String", "Call", "Index",
    "Deref", "Add", "Sub", "Mul", "Div", "Neg",
    "Eq", "Ne", "Lt", "Le", "Gt", "Ge", "And", "Or", "Not",
    "Field", "AddrOf", "StructLit", "Embed",
    "Mod", "Shl", "Shr", "BitAnd", "BitOr", "BitXor", "BitNot", "Cond",
    "SizeOf", "Len",
    "FieldCall",
    "Cast",                  # v0.23.48-dev: T(x), an explicit integer cast
]

# The kinds the bootstrap parser builds, in the host's order: a subsequence of
# EXPR_KINDS. The eleven excluded kinds (§2.1, replaced per §12.2) keep their
# numbers unused, so a surviving kind's number is the host's.
EXPR_SUBSET = [
    "Num", "Var", "String", "Call", "Index",
    "Add", "Sub", "Mul", "Div", "Neg",
    "Eq", "Ne", "Lt", "Le", "Gt", "Ge", "And", "Or", "Not",
    "Mod", "Shl", "Shr", "BitAnd", "BitOr", "BitXor",
]

# The host's statement kinds, in the exact order of `enum Kind` inside
# `struct Stmt`; the parser's statement numbers are these + 64 (§2.2).
STMT_KINDS = [
    "Let", "Assign", "FieldAssign", "IndexAssign", "DerefAssign",
    "Return", "If", "While", "For", "Break", "Continue", "Switch", "Expr",
]

# The kinds the bootstrap parser builds: FieldAssign, DerefAssign, For and
# Switch are excluded (§12.2), their numbers skipped. Switch is excluded
# because Pascal-semantics switch is the one control-flow shape the bootstrap
# subset does not cover.
STMT_SUBSET = [
    "Let", "Assign", "IndexAssign", "Return", "If", "While",
    "Break", "Continue", "Expr",
]

# The structural kinds (§2.3): no counterpart in the host, which carries
# functions, globals, parameters and block bodies as vectors beside the AST.
# Numbered from 128 so they never collide with a statement kind.
STRUCT_BASE = 128
STRUCT_KINDS = ["Program", "Function", "Global", "Param", "Block"]

# The type tags (§2.4): the constant name and the spelling the dump prints.
TYPE_TAGS = [
    ("TY_I32", "i32"),
    ("TY_I64", "i64"),
    ("TY_U8", "u8"),
    ("TY_PTR", "ptr"),
    ("TY_PTR_U8", "ptr<u8>"),
    ("TY_PTR_I32", "ptr<i32>"),
    ("TY_PTR_I64", "ptr<i64>"),
]

# One record per table entry: the name's bytes, NUL-padded. The longest name
# in any table, "IndexAssign", is 12 bytes, so 16 always leaves room for the
# terminator.
RECORD = 16

EXPR_COUNT = len(EXPR_KINDS)          # 35 — entab's record count
STMT_COUNT = len(STMT_KINDS)          # 12 — sntab's record count
STRUCT_COUNT = len(STRUCT_KINDS)      # 5  — nntab's record count
TYPE_COUNT = len(TYPE_TAGS)           # 7  — tytab's record count
EXPR_SUBSET_COUNT = len(EXPR_SUBSET)  # 25 — the E_* constants
STMT_SUBSET_COUNT = len(STMT_SUBSET)  # 9  — the S_* constants

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ASTER_PATH = os.path.join(HERE, "aster.ast")
HEADER_PATH = os.path.join(ROOT, "tests", "parser_names.h")
CPP_PATH = os.path.join(ROOT, "src", "aster.cpp")

BEGIN = ("// ---- BEGIN GENERATED: parser names "
         "(bootstrap/gen_parser_names.py) ----")
END = "// ---- END GENERATED: parser names ----"


def die(msg):
    sys.stderr.write("gen_parser_names.py: %s\n" % msg)
    sys.exit(2)


# ---------------------------------------------------------------------------
# Self-checks: the lists must be well-formed before anything is emitted.
# ---------------------------------------------------------------------------
def check_list():
    if EXPR_COUNT != 36:
        die("expected 36 expression kinds, list has %d" % EXPR_COUNT)
    if EXPR_SUBSET_COUNT != 25:
        die("expected 25 expression kinds in the subset, list has %d"
            % EXPR_SUBSET_COUNT)
    if STMT_COUNT != 13:
        die("expected 13 statement kinds, list has %d" % STMT_COUNT)
    if STMT_SUBSET_COUNT != 9:
        die("expected 9 statement kinds in the subset, list has %d"
            % STMT_SUBSET_COUNT)
    if STRUCT_COUNT != 5:
        die("expected 5 structural kinds, list has %d" % STRUCT_COUNT)
    if TYPE_COUNT != 7:
        die("expected 7 type tags, list has %d" % TYPE_COUNT)
    for label, names in (("expression", EXPR_KINDS),
                         ("expression subset", EXPR_SUBSET),
                         ("statement", STMT_KINDS),
                         ("statement subset", STMT_SUBSET),
                         ("structural", STRUCT_KINDS)):
        if len(set(names)) != len(names):
            die("duplicate %s kind name" % label)
        for name in names:
            if not re.fullmatch(r"[A-Z][A-Za-z0-9]*", name):
                die("%s kind name is not an identifier: %r" % (label, name))
            if len(name) >= RECORD:
                die("%s kind name %r does not fit a %d-byte record"
                    % (label, name, RECORD))
    tag_names = [t for t, _ in TYPE_TAGS]
    if len(set(tag_names)) != TYPE_COUNT:
        die("duplicate type tag constant name")
    for tag, spelling in TYPE_TAGS:
        if not re.fullmatch(r"TY_[A-Z0-9_]+", tag):
            die("type tag constant is not shaped TY_*: %r" % tag)
        if len(spelling) >= RECORD:
            die("type spelling %r does not fit a %d-byte record"
                % (spelling, RECORD))
        try:
            raw = spelling.encode("ascii")
        except UnicodeEncodeError:
            die("type spelling %r is not ASCII" % spelling)
        for b in raw:
            if not 0x20 <= b <= 0x7E:
                die("type spelling %r holds a byte that is not printable "
                    "ASCII" % spelling)
    # The subsets must be subsequences of the host lists, in the host's order:
    # a kept kind keeps its number, an excluded kind's number is skipped.
    for label, full, sub in (("expression", EXPR_KINDS, EXPR_SUBSET),
                             ("statement", STMT_KINDS, STMT_SUBSET)):
        it = iter(full)
        if not all(name in it for name in sub):
            die("the %s subset is not a subsequence of the host's list, in "
                "the host's order" % label)
    if STRUCT_KINDS[0] != "Program" or STRUCT_KINDS[-1] != "Block":
        die("the structural kinds must run Program .. Block")


# ---------------------------------------------------------------------------
# Cross-checks against src/aster.cpp. The Python is the source of truth, so
# these run Python -> C++ : if the host compiler's enums have moved, this
# file has to be updated first, and it says so.
# ---------------------------------------------------------------------------
def cpp_text():
    try:
        with open(CPP_PATH, "r", encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def cpp_enum_kinds(struct):
    """The names inside `enum Kind { ... } k;` of one struct, comments out."""
    src = cpp_text()
    m = re.search(r"struct %s \{.*?enum Kind \{(.*?)\} k;" % struct, src, re.S)
    if not m:
        die("cannot find `enum Kind` inside `struct %s` in src/aster.cpp"
            % struct)
    body = re.sub(r"/\*.*?\*/", " ", m.group(1), flags=re.S)
    body = re.sub(r"//[^\n]*", " ", body)
    return [t for t in re.split(r"[,\s]+", body) if t]


def check_against_cpp():
    for struct, ours in (("Expr", EXPR_KINDS), ("Stmt", STMT_KINDS)):
        theirs = cpp_enum_kinds(struct)
        if theirs != ours:
            only_cpp = [n for n in theirs if n not in ours]
            only_py = [n for n in ours if n not in theirs]
            die("`enum Kind` inside `struct %s` in src/aster.cpp disagrees "
                "with this file\n"
                "    in src/aster.cpp only: %s\n"
                "    in this file only:     %s\n"
                "The Python list is the source of truth (PARSER-SPEC.md "
                "§13): update it here first, then src/aster.cpp."
                % (struct, only_cpp or "nothing", only_py or "nothing"))


# ---------------------------------------------------------------------------
# Emission.
# ---------------------------------------------------------------------------
def aster_string_literal(data):
    """Escape raw bytes as an Aster string literal body (no quotes)."""
    out = []
    for b in data:
        if b == 0x22:
            out.append('\\"')
        elif b == 0x5C:
            out.append("\\\\")
        elif b == 0x0A:
            out.append("\\n")
        elif b == 0x0D:
            out.append("\\r")
        elif b == 0x09:
            out.append("\\t")
        elif b == 0x00:
            out.append("\\0")
        elif 0x20 <= b <= 0x7E:
            out.append(chr(b))
        else:
            die("packed name table holds a byte that needs no escape but "
                "is not printable ASCII: 0x%02x" % b)
    return "".join(out)


def packed_table(names):
    return b"".join(name.encode("ascii") + b"\0" * (RECORD - len(name))
                    for name in names)


def aster_region():
    lines = [BEGIN]
    lines.append("// The %d expression node kinds this parser builds"
                 % EXPR_SUBSET_COUNT)
    lines.append("// (PARSER-SPEC.md §2.1), at the host's `enum Kind` numbers")
    lines.append("// inside struct Expr: the subset keeps the numbering, the")
    lines.append("// eleven excluded kinds (§12.2) are simply absent, so a kind's")
    lines.append("// number means the same thing in both implementations. The")
    lines.append("// full %d-record entab below still carries every host name."
                 % EXPR_COUNT)
    lines.append("// Regenerate: python3 bootstrap/gen_parser_names.py")
    for name in EXPR_SUBSET:
        lines.append("let E_%s: i32 = %d;" % (name, EXPR_KINDS.index(name)))
    lines.append("")
    lines.append("// The %d statement kinds (§2.2), the host's Stmt::Kind"
                 % STMT_SUBSET_COUNT)
    lines.append("// numbers + 64; FieldAssign, DerefAssign, For and Switch are")
    lines.append("// excluded (§12.2), their numbers skipped.")
    for name in STMT_SUBSET:
        lines.append("let S_%s: i32 = %d;"
                     % (name, 64 + STMT_KINDS.index(name)))
    lines.append("")
    lines.append("// The %d structural kinds (§2.3) — no host counterpart; the"
                 % STRUCT_COUNT)
    lines.append("// dump makes the host's side vectors nodes so every line")
    lines.append("// has one shape.")
    for i, name in enumerate(STRUCT_KINDS):
        lines.append("let N_%s: i32 = %d;" % (name, STRUCT_BASE + i))
    lines.append("")
    lines.append("// The %d type tags (§2.4)." % TYPE_COUNT)
    for tag, _ in TYPE_TAGS:
        lines.append("let %s: i32 = %d;"
                     % (tag, [t for t, _ in TYPE_TAGS].index(tag) + 1))
    lines.append("")
    lines.append("// The kind names, four packed tables of %d-byte records: a"
                 % RECORD)
    lines.append("// record is the name's bytes, NUL-padded. entab is the")
    lines.append("// host's full Expr::Kind list (%d records, so a kind's"
                 % EXPR_COUNT)
    lines.append("// record sits at its own number); sntab is Stmt::Kind (%d);"
                 % STMT_COUNT)
    lines.append("// nntab the structural kinds (%d); tytab the type spellings"
                 % STRUCT_COUNT)
    lines.append("// (%d, tag 1 at record 0). The dump picks the table by the"
                 % TYPE_COUNT)
    lines.append("// kind's space (§9): < 64 entab, < 128 sntab, else nntab.")
    lines.append('let entab: ptr = "%s";'
                 % aster_string_literal(packed_table(EXPR_KINDS)))
    lines.append('let sntab: ptr = "%s";'
                 % aster_string_literal(packed_table(STMT_KINDS)))
    lines.append('let nntab: ptr = "%s";'
                 % aster_string_literal(packed_table(STRUCT_KINDS)))
    lines.append('let tytab: ptr = "%s";'
                 % aster_string_literal(
                     packed_table([s for _, s in TYPE_TAGS])))
    lines.append(END)
    return "\n".join(lines) + "\n"


def c_header():
    lines = [
        "/* Generated by bootstrap/gen_parser_names.py — do not edit.",
        " *",
        " * The differential twin's node-kind codes, kind names and type",
        " * spellings, from the same single lists as bootstrap/aster.ast's",
        " * generated region: a node set that drifts between the two fails",
        " * the differential, not a reader. */",
        "#ifndef ASTER_PARSER_NAMES_H",
        "#define ASTER_PARSER_NAMES_H",
        "",
        "/* The %d expression kinds the bootstrap parser builds"
        % EXPR_SUBSET_COUNT,
        " * (PARSER-SPEC.md §2.1), at the host's Expr::Kind numbers. The eleven",
        " * excluded host kinds get no constant here, exactly as on the Aster",
        " * side. */",
        "enum {",
    ]
    for name in EXPR_SUBSET:
        lines.append("    E_%s = %d," % (name, EXPR_KINDS.index(name)))
    lines.append("};")
    lines.append("")
    lines.append(        "/* The %d statement kinds (§2.2), Stmt::Kind + 64; FieldAssign, "
                 "DerefAssign, For and Switch are excluded (§12.2). */"
                 % STMT_SUBSET_COUNT)
    lines.append("enum {")
    for name in STMT_SUBSET:
        lines.append("    S_%s = %d," % (name, 64 + STMT_KINDS.index(name)))
    lines.append("};")
    lines.append("")
    lines.append("/* The %d structural kinds (§2.3). */" % STRUCT_COUNT)
    lines.append("enum {")
    for i, name in enumerate(STRUCT_KINDS):
        lines.append("    N_%s = %d," % (name, STRUCT_BASE + i))
    lines.append("};")
    lines.append("")
    lines.append("/* The %d type tags (§2.4). */" % TYPE_COUNT)
    lines.append("enum {")
    for tag, _ in TYPE_TAGS:
        lines.append("    %s = %d," % (tag, [t for t, _ in
                                             TYPE_TAGS].index(tag) + 1))
    lines.append("};")
    lines.append("")
    lines.append("/* The name tables, the C shape of the Aster side's packed")
    lines.append(" * byte tables: entab is the host's full Expr::Kind list")
    lines.append(" * (index = kind), sntab Stmt::Kind (index = kind - 64),")
    lines.append(" * nntab the structural kinds (index = kind - 128), tytab")
    lines.append(" * the type spellings (index = tag - 1). */")
    lines.append("#define EK_COUNT %d" % EXPR_COUNT)
    lines.append("static const char *const EK_NAMES[EK_COUNT] = {")
    for name in EXPR_KINDS:
        lines.append('    "%s",' % name)
    lines.append("};")
    lines.append("")
    lines.append("#define SK_COUNT %d" % STMT_COUNT)
    lines.append("static const char *const SK_NAMES[SK_COUNT] = {")
    for name in STMT_KINDS:
        lines.append('    "%s",' % name)
    lines.append("};")
    lines.append("")
    lines.append("#define NK_COUNT %d" % STRUCT_COUNT)
    lines.append("static const char *const NK_NAMES[NK_COUNT] = {")
    for name in STRUCT_KINDS:
        lines.append('    "%s",' % name)
    lines.append("};")
    lines.append("")
    lines.append("#define TYT_COUNT %d" % TYPE_COUNT)
    lines.append("static const char *const TY_NAMES[TYT_COUNT] = {")
    for _, spelling in TYPE_TAGS:
        lines.append('    "%s",' % spelling)
    lines.append("};")
    lines.append("")
    lines.append("#endif /* ASTER_PARSER_NAMES_H */")
    return "\n".join(lines) + "\n"


def patch_aster(text, region):
    """Replace the marked region in bootstrap/aster.ast, markers included."""
    lines = text.split("\n")
    begin = end = None
    for i, line in enumerate(lines):
        if line == BEGIN and begin is None:
            begin = i
        elif line == END and begin is not None and end is None:
            end = i
    if begin is None or end is None:
        die("bootstrap/aster.ast does not carry the generated-region markers "
            "(%r .. %r)" % (BEGIN, END))
    new = lines[:begin] + region.rstrip("\n").split("\n") + lines[end + 1:]
    return "\n".join(new)


def main():
    check_list()
    check_against_cpp()
    region = aster_region()
    header = c_header()

    if "--check" in sys.argv[1:]:
        ok = True
        try:
            with open(ASTER_PATH, "r", encoding="utf-8") as f:
                current = f.read()
        except OSError:
            current = None
        if current is None:
            sys.stderr.write("gen_parser_names.py: %s is missing\n"
                             % ASTER_PATH)
            ok = False
        elif patch_aster(current, region) != current:
            sys.stderr.write("gen_parser_names.py: %s is stale — its "
                             "generated region differs from what this emits\n"
                             % ASTER_PATH)
            ok = False
        try:
            with open(HEADER_PATH, "r", encoding="utf-8") as f:
                on_disk = f.read()
        except OSError:
            on_disk = None
        if on_disk is None:
            sys.stderr.write("gen_parser_names.py: %s is missing\n"
                             % HEADER_PATH)
            ok = False
        elif on_disk != header:
            sys.stderr.write("gen_parser_names.py: %s is stale — it differs "
                             "from what this emits\n" % HEADER_PATH)
            ok = False
        sys.exit(0 if ok else 1)

    if not os.path.exists(ASTER_PATH):
        die("bootstrap/aster.ast does not exist yet — create it with the "
            "generated-region markers first")
    with open(ASTER_PATH, "r", encoding="utf-8") as f:
        text = f.read()
    with open(ASTER_PATH, "w", encoding="utf-8") as f:
        f.write(patch_aster(text, region))
    with open(HEADER_PATH, "w", encoding="utf-8") as f:
        f.write(header)
    sys.stderr.write(
        "gen_parser_names.py: %d expression kinds (%d built), %d statement "
        "kinds (%d built), %d structural, %d type tags — wrote the generated "
        "region of %s and %s\n"
        % (EXPR_COUNT, EXPR_SUBSET_COUNT, STMT_COUNT, STMT_SUBSET_COUNT,
           STRUCT_COUNT, TYPE_COUNT, ASTER_PATH, HEADER_PATH))


if __name__ == "__main__":
    main()
