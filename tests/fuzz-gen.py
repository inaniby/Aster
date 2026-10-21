#!/usr/bin/env python3
"""Aster syntax-fuzzer corpus generator (P4.4).

Writes `--count` .ast files into `--outdir`, deterministically for a given
`--seed`, from four kinds of input:

  seed      a fixed, hand-picked set written first. Each one exercises a
            parser path that has actually crashed before: unary prefix
            operators (`-`, `!`, `*`, `&`) and the assignment forms that
            move their target into the statement. They are deliberately
            NOT random, so the "does this fuzzer actually catch crashes"
            proof in fuzz-checks.sh has something guaranteed to hit.
  mutation  a real example from `--corpus` with random edits applied:
            delete a span, insert junk, truncate, duplicate a line, swap
            characters, inject newlines/tabs (which moves every reported
            line/column and stresses the diagnostics renderer too). Half of
            these are "light" -- ONE edit -- because a single edit to a valid
            program is what produces an input that is still nearly valid, and
            those are the ones that get deep enough to reach codegen.
  soup      a random token stream. Almost all of it dies in the lexer,
            which is still worth having: the lexer is part of the surface.
  skeleton  a syntactically valid frame (`fn main() -> i32 { ... }`) filled
            with random statements and expressions. This is the kind that
            gets *past* the parser's front door and into type checking,
            which is where the interesting crashes live.

The mix matters: a corpus that is only soup never reaches the semantic
pass, and fuzz-checks.sh asserts that a nonzero share of the corpus
actually compiles, so the corpus cannot silently degrade into "everything
is rejected by the first token".
"""

import argparse
import os
import random

# Tokens the lexer actually knows, plus a few it must reject cleanly.
TOKENS = [
    "fn", "main", "return", "let", "if", "else", "while", "for", "break",
    "continue", "struct", "extern", "ptr", "i32", "i64", "u8", "u16", "u32",
    "bool", "->", "{", "}", "(", ")", "[", "]", ";", ":", ",", ".", "=",
    "==", "!=", "<", "<=", ">", ">=", "+", "-", "*", "/", "%", "!", "&&",
    "||", "&", "@", '"', "'", "`", "\\", "?", "#", "$", "~", "^", "|",
    "0", "1", "42", "2147483648", "999999999999999999999999", "x", "y", "z",
    "_start", "embed", "embed_len", "0x10", "1e999", "\x00", "\t", "\n", " ",
]

# Fixed seeds: every unary/assignment path, spelled plainly.
SEEDS = [
    "fn main() -> i32 {\n    let x: i32 = -1;\n    return x;\n}\n",
    "fn main() -> i32 {\n    let b: bool = !x;\n    return 0;\n}\n",
    "fn main() -> i32 {\n    let x: i32 = 1;\n    let p: ptr<i32> = &x;\n    return 0;\n}\n",
    "fn main() -> i32 {\n    let x: i32 = 1;\n    let p: ptr<i32> = &x;\n    *p = 5;\n    return *p;\n}\n",
    "fn main() -> i32 {\n    let x: i32 = 1;\n    let p: ptr<i32> = &x;\n    let q: ptr<i32> = -p;\n    return 0;\n}\n",
    "fn main() -> i32 {\n    let a: i32[4] = 0;\n    a[0] = 1;\n    return a[0];\n}\n",
    "fn main() -> i32 {\n    let x: i32 = 1;\n    x = -x;\n    return x;\n}\n",
    "fn main() -> i32 {\n    let x: i32 = 1;\n    return !(x > 0);\n}\n",
    "fn main() -> i32 {\n    let p: ptr<i32> = 0;\n    *p = *p + 1;\n    return 0;\n}\n",
    "fn main() -> i32 {\n    let x: i32 = ((((-1))));\n    return x;\n}\n",
]

EXPRS = [
    "1", "x", "y", "-1", "-x", "!x", "!0", "*p", "&x", "x + 1", "x - 1",
    "x * 2", "x / 2", "x % 2", "x == y", "x != y", "x < y", "x >= y",
    "x && y", "x || y", "f(x)", "f(x, y)", "a[0]", "a[i]", "p.f", "(x + 1) * 2",
    '@embed("missing.bin")', "@embed_len(\"missing.bin\")", "2147483648",
    "99999999999999999999", "", "(", ")", "*", "&", "!", "-", "x +", "+ x",
]

STMTS = [
    "let v: i32 = {e};", "let v: bool = {e};", "let v: ptr<i32> = {e};",
    "let v: i64 = {e};", "let v: u8 = {e};", "let a: i32[4] = {e};",
    "v = {e};", "a[0] = {e};", "p.f = {e};", "*p = {e};", "return {e};",
    "return;", "if ({e}) {{ return {e}; }}", "while ({e}) {{ v = {e}; }}",
    "for (let i: i32 = 0; i < 4; i = i + 1) {{ v = {e}; }}",
    "break;", "continue;", "{e};", "let v: i32 = ;", "let = 1;",
]

HEADS = [
    "fn main() -> i32 {",
    "fn f() -> i32 {",
    "fn g(a: i32, b: i32) -> i32 {",
    "fn h(p: ptr<i32>) -> bool {",
    "struct P {{ x: i32, y: i32 }}\nfn main() -> i32 {",
    "fn main() -> i32 { let x: i32 = 1; let y: i32 = 2; let p: ptr<i32> = &x;",
]


def mutate(text, rnd, edits=None):
    """Apply `edits` random edits to a real source file (default 1..4)."""
    if edits is None:
        edits = rnd.randint(1, 4)
    chars = list(text)
    for _ in range(edits):
        if not chars:
            break
        op = rnd.randint(0, 5)
        if op == 0:                                  # delete a span
            i = rnd.randrange(len(chars))
            j = min(len(chars), i + rnd.randint(1, 40))
            del chars[i:j]
        elif op == 1:                                # insert junk
            i = rnd.randrange(len(chars) + 1)
            junk = "".join(rnd.choice(TOKENS) for _ in range(rnd.randint(1, 6)))
            chars[i:i] = list(junk)
        elif op == 2:                                # truncate
            del chars[rnd.randrange(len(chars)):]
        elif op == 3:                                # duplicate a line
            lines = "".join(chars).split("\n")
            if lines:
                i = rnd.randrange(len(lines))
                lines.insert(i, lines[i])
                chars = list("\n".join(lines))
        elif op == 4:                                # character substitutions
            for _ in range(rnd.randint(1, 8)):
                i = rnd.randrange(len(chars))
                chars[i] = rnd.choice(TOKENS) if rnd.random() < 0.5 else rnd.choice("{}(),;")
        else:                                        # whitespace / layout churn
            i = rnd.randrange(len(chars) + 1)
            chars[i:i] = list(rnd.choice(["\n", "\t", "    ", "\n\n", " \n"]))
    return "".join(chars)


def soup(rnd):
    """A random token stream: mostly lexer food."""
    return " ".join(rnd.choice(TOKENS) for _ in range(rnd.randint(1, 60))) + "\n"


def skeleton(rnd):
    """A valid frame filled with random-but-plausible statements."""
    body = [rnd.choice(STMTS).replace("{e}", rnd.choice(EXPRS))
            for _ in range(rnd.randint(1, 6))]
    return rnd.choice(HEADS) + "\n" + "\n".join(body) + "\n}\n"


def main():
    ap = argparse.ArgumentParser(description="generate an Aster fuzz corpus")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--count", type=int, default=2000)
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--corpus", default="examples")
    args = ap.parse_args()

    rnd = random.Random(args.seed)

    corpus = []
    if os.path.isdir(args.corpus):
        for name in sorted(os.listdir(args.corpus)):
            path = os.path.join(args.corpus, name)
            if name.endswith(".ast") and os.path.isfile(path):
                with open(path, "r", errors="replace") as fh:
                    corpus.append(fh.read())

    os.makedirs(args.outdir, exist_ok=True)
    counts = {"seed": 0, "light": 0, "mutation": 0, "soup": 0, "skeleton": 0}
    for i in range(args.count):
        if i < len(SEEDS):
            text, kind = SEEDS[i], "seed"
        else:
            r = rnd.random()
            if corpus and r < 0.25:
                # One edit to a valid program: still nearly valid, so it gets
                # past the parser and into the semantic pass and codegen.
                text, kind = mutate(rnd.choice(corpus), rnd, 1), "light"
            elif corpus and r < 0.45:
                text, kind = mutate(rnd.choice(corpus), rnd), "mutation"
            elif r < 0.60:
                text, kind = soup(rnd), "soup"
            else:
                text, kind = skeleton(rnd), "skeleton"
        counts[kind] += 1
        with open(os.path.join(args.outdir, "fuzz_%05d.ast" % i), "w") as fh:
            fh.write(text)

    print("fuzz corpus: %d inputs (seed=%d) %s"
          % (args.count, args.seed,
             " ".join("%s=%d" % kv for kv in sorted(counts.items()) if kv[1])))


if __name__ == "__main__":
    main()
