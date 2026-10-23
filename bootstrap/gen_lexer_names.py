#!/usr/bin/env python3
"""Single source of truth for the M3a token kinds and keywords.

Emits two artifacts from one list (bootstrap/LEXER-SPEC.md §12, as narrowed by
PARSER-SPEC.md §12.1):

  * the GENERATED region of bootstrap/aster.ast — the 73 K_* constants, the
    `ident_is` byte-compare helper and the `keyword_kind` else-if chain. The
    packed `ktab` name table the retired token dump used is no longer emitted;
  * tests/lexer_names.h — the C side's enum of the same 73 codes and keyword
    table, consumed by tests/parser-twin.c (the M3b differential twin, which
    lexes the input itself).

Deterministic and idempotent: running it twice changes nothing. The region
inside bootstrap/aster.ast is replaced in place between the BEGIN/END markers;
hand-written code is never touched.

Before emitting, the list is cross-checked against src/aster.cpp itself — the
`enum class TK` order and the lexer's keyword chain — so a token set that
drifts between this file and the host compiler fails here rather than in the
differential suite.

Usage:
    python3 bootstrap/gen_lexer_names.py            regenerate both artifacts
    python3 bootstrap/gen_lexer_names.py --check    verify the on-disk files
                                                    are what this would emit
                                                    (no writes; exit 1 on drift)
"""

import os
import re
import sys

# ---------------------------------------------------------------------------
# The token kinds, in the exact order of `enum class TK` in src/aster.cpp.
# The number is part of the contract (LEXER-SPEC.md §2): the dump prints the
# name, but both implementations and this generator key off the number.
# ---------------------------------------------------------------------------
TOKENS = [
    "End", "Ident", "Number", "String",
    "Fn", "Extern", "Main", "Let", "Return", "If", "Else", "While", "For",
    "Break", "Continue", "I32", "Ptr", "Bool",
    "I64", "U8", "U16", "U32",
    "U64",                 # v0.23.48-dev: the 64-bit unsigned integer
    "True", "False",
    "Struct", "Include",
    "LParen", "RParen", "LBrace", "RBrace", "Colon", "Semi", "Comma", "Arrow",
    "Eq", "EqEq", "Ne",
    "Lt", "Le", "Gt", "Ge", "Plus", "Minus", "Star", "Slash", "LBracket",
    "RBracket", "At", "And", "Or", "Not",
    "Percent", "Shl", "Shr", "BitXor", "BitOr", "Tilde", "Question",
    "PlusEq", "MinusEq", "StarEq", "SlashEq", "PercentEq", "ShlEq", "ShrEq",
    "AndEq", "OrEq", "XorEq",
    "PlusPlus", "MinusMinus",
    "Dot", "Amp",
]

# The 23 reserved words, each spelling mapped to the kind it lexes to. Order
# is the order the host compiler's chain tests them in; since every spelling
# is distinct the order carries no meaning, but keeping it identical makes
# the generated chain diff against the C++ one line for line.
KEYWORDS = [
    ("fn", "Fn"), ("extern", "Extern"), ("main", "Main"), ("let", "Let"),
    ("return", "Return"), ("if", "If"), ("else", "Else"), ("while", "While"),
    ("for", "For"), ("break", "Break"), ("continue", "Continue"),
    ("i32", "I32"), ("ptr", "Ptr"), ("bool", "Bool"),
    ("i64", "I64"), ("u8", "U8"), ("u16", "U16"), ("u32", "U32"),
    ("u64", "U64"),       # v0.23.48-dev
    ("struct", "Struct"), ("include", "Include"),
    ("true", "True"), ("false", "False"),
]

# The record width the retired packed name table used; kept as the name-length
# bound in check_list. The longest name, "MinusMinus", is 10 bytes.
RECORD = 12

TOKEN_COUNT = len(TOKENS)
KEYWORD_COUNT = len(KEYWORDS)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ASTER_PATH = os.path.join(HERE, "aster.ast")
HEADER_PATH = os.path.join(ROOT, "tests", "lexer_names.h")
CPP_PATH = os.path.join(ROOT, "src", "aster.cpp")

BEGIN = "// ---- BEGIN GENERATED: lexer names (bootstrap/gen_lexer_names.py) ----"
END = "// ---- END GENERATED: lexer names ----"


def die(msg):
    sys.stderr.write("gen_lexer_names.py: %s\n" % msg)
    sys.exit(2)


# ---------------------------------------------------------------------------
# Self-checks: the list must be well-formed before anything is emitted.
# ---------------------------------------------------------------------------
def check_list():
    if TOKEN_COUNT != 73:
        die("expected 73 token kinds, list has %d" % TOKEN_COUNT)
    if len(set(TOKENS)) != TOKEN_COUNT:
        die("duplicate token kind name")
    for name in TOKENS:
        if not re.fullmatch(r"[A-Z][A-Za-z0-9]*", name):
            die("token kind name is not an identifier: %r" % name)
        if len(name) >= RECORD:
            die("token kind name %r does not fit a %d-byte record"
                % (name, RECORD))
    if KEYWORD_COUNT != 23:
        die("expected 23 keywords, list has %d" % KEYWORD_COUNT)
    kinds = [k for _, k in KEYWORDS]
    if len(set(kinds)) != KEYWORD_COUNT:
        die("two keywords map to the same kind")
    spellings = [s for s, _ in KEYWORDS]
    if len(set(spellings)) != KEYWORD_COUNT:
        die("duplicate keyword spelling")
    for spelling, kind in KEYWORDS:
        if kind not in TOKENS:
            die("keyword %r maps to unknown kind %r" % (spelling, kind))
        if not re.fullmatch(r"[a-z][a-z0-9]*", spelling):
            die("keyword is not a lowercase identifier: %r" % spelling)


# ---------------------------------------------------------------------------
# Cross-checks against src/aster.cpp. The Python is the source of truth, so
# these run Python -> C++ : if the host compiler's enum or keyword chain has
# moved, this file has to be updated first, and it says so.
# ---------------------------------------------------------------------------
def cpp_text():
    try:
        with open(CPP_PATH, "r", encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def cpp_enum_tokens():
    """The names inside `enum class TK { ... };`, comments stripped."""
    src = cpp_text()
    m = re.search(r"enum\s+class\s+TK\s*\{(.*?)\}\s*;", src, re.S)
    if not m:
        die("cannot find `enum class TK` in src/aster.cpp")
    body = re.sub(r"/\*.*?\*/", " ", m.group(1), flags=re.S)
    body = re.sub(r"//[^\n]*", " ", body)
    return [t for t in re.split(r"[,\s]+", body) if t]


def cpp_keyword_pairs():
    """The (spelling, kind) pairs of the lexer's keyword chain, in order."""
    src = cpp_text()
    pairs = re.findall(r'x=="([a-z0-9]+)"\)k=TK::(\w+)', src)
    if not pairs:
        die("cannot find the lexer's keyword chain in src/aster.cpp")
    return pairs


def check_against_cpp():
    enum_names = cpp_enum_tokens()
    if enum_names != TOKENS:
        only_cpp = [n for n in enum_names if n not in TOKENS]
        only_py = [n for n in TOKENS if n not in enum_names]
        die("`enum class TK` in src/aster.cpp disagrees with TOKENS\n"
            "    in src/aster.cpp only: %s\n"
            "    in this file only:     %s\n"
            "The Python list is the source of truth (LEXER-SPEC.md §12): "
            "update it here first, then src/aster.cpp."
            % (only_cpp or "nothing", only_py or "nothing"))
    pairs = cpp_keyword_pairs()
    if pairs != KEYWORDS:
        die("the lexer's keyword chain in src/aster.cpp disagrees with "
            "KEYWORDS\n    src/aster.cpp: %s\n    this file:     %s"
            % (pairs, KEYWORDS))


# ---------------------------------------------------------------------------
# Emission.
# ---------------------------------------------------------------------------
def aster_region():
    lines = [BEGIN]
    lines.append("// The %d token kinds, numbered exactly as `enum class TK`"
                 % TOKEN_COUNT)
    lines.append("// in src/aster.cpp. Regenerate: python3 "
                 "bootstrap/gen_lexer_names.py")
    for i, name in enumerate(TOKENS):
        lines.append("let K_%s: i32 = %d;" % (name, i))
    lines.append("")
    lines.append("// Byte-wise equality of n bytes at id against the")
    lines.append("// NUL-terminated literal lit; the terminator must sit")
    lines.append("// exactly at n, so unequal lengths answer 0 as well.")
    lines.append("fn ident_is(lit: ptr<u8>, id: ptr<u8>, n: i32) -> i32 {")
    lines.append("    let i: i32 = 0;")
    lines.append("    while (i < n) {")
    lines.append("        if (load_u8(lit + i) != load_u8(id + i)) { return 0; }")
    lines.append("        i = i + 1;")
    lines.append("    }")
    lines.append("    if (load_u8(lit + n) != 0) { return 0; }")
    lines.append("    return 1;")
    lines.append("}")
    lines.append("")
    lines.append("// Keyword recognition — the %d reserved words, one branch"
                 % KEYWORD_COUNT)
    lines.append("// each, from the same list as the C twin's table")
    lines.append("// (tests/lexer_names.h). No match is K_Ident.")
    lines.append("fn keyword_kind(id: ptr<u8>, n: i32) -> i32 {")
    for spelling, kind in KEYWORDS:
        lines.append('    if (ident_is("%s", id, n)) { return K_%s; }'
                     % (spelling, kind))
    lines.append("    return K_Ident;")
    lines.append("}")
    lines.append(END)
    return "\n".join(lines) + "\n"


def c_header():
    lines = [
        "/* Generated by bootstrap/gen_lexer_names.py — do not edit.",
        " *",
        " * The differential twin's token-kind codes and keyword table,",
        " * from the same single list as bootstrap/aster.ast's generated",
        " * region: a token set that drifts between the two fails the",
        " * differential, not a reader. Consumed by tests/parser-twin.c,",
        " * which lexes the input itself (the M3b twin has no separate",
        " * lexer stage — PARSER-SPEC.md §12.1 retired the M3a token dump",
        " * and with it the lexer twin; the scanner rules themselves are",
        " * unchanged, bootstrap/LEXER-SPEC.md remains their contract). */",
        "#ifndef ASTER_LEXER_NAMES_H",
        "#define ASTER_LEXER_NAMES_H",
        "",
        "enum {",
        "    TK_End = 0,",
    ]
    for name in TOKENS[1:]:
        lines.append("    TK_%s," % name)
    lines.append("};")
    lines.append("")
    lines.append("#define TK_COUNT %d" % TOKEN_COUNT)
    lines.append("static const char *const TK_NAMES[TK_COUNT] = {")
    for name in TOKENS:
        lines.append('    "%s",' % name)
    lines.append("};")
    lines.append("")
    lines.append("#define KW_COUNT %d" % KEYWORD_COUNT)
    lines.append("static const struct { const char *spelling; int kind; } "
                 "KEYWORDS[KW_COUNT] = {")
    for spelling, kind in KEYWORDS:
        lines.append('    { "%s", TK_%s },' % (spelling, kind))
    lines.append("};")
    lines.append("")
    lines.append("#endif /* ASTER_LEXER_NAMES_H */")
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
            sys.stderr.write("gen_lexer_names.py: %s is missing\n" % ASTER_PATH)
            ok = False
        elif patch_aster(current, region) != current:
            sys.stderr.write("gen_lexer_names.py: %s is stale — its generated "
                             "region differs from what this emits\n"
                             % ASTER_PATH)
            ok = False
        try:
            with open(HEADER_PATH, "r", encoding="utf-8") as f:
                on_disk = f.read()
        except OSError:
            on_disk = None
        if on_disk is None:
            sys.stderr.write("gen_lexer_names.py: %s is missing\n" % HEADER_PATH)
            ok = False
        elif on_disk != header:
            sys.stderr.write("gen_lexer_names.py: %s is stale — it differs "
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
        "gen_lexer_names.py: %d kinds, %d keywords — wrote the generated "
        "region of %s and %s\n"
        % (TOKEN_COUNT, KEYWORD_COUNT, ASTER_PATH, HEADER_PATH))


if __name__ == "__main__":
    main()
