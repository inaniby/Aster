#!/usr/bin/env python3
"""Aster project-file / cache-meta mutation corpus (v0.23.81-dev, fuzz batch).

Writes deterministic mutant copies of one pristine scaffold project into
--outdir, for the sanitizer suite (tests/sanitizer-checks.sh step [8/9]):

  proj-NN/  a full copy of the project with a mutated aster.proj (no build/
            directory: each mutant builds from scratch, so a stale cache
            cannot mask a parse problem). The mutation list covers the
            audit §6.2 asks: duplicate lines (exact and re-spelled),
            malformed lines, over-long lines, illegal characters, truncation,
            and every setting line with a bad value.
  meta-NN/  a full copy INCLUDING build/.cache, with exactly one .meta
            mutated (the one for src/main.ast): truncated, hash flipped,
            field dropped, field duplicated, NUL bytes, over-long line, a
            dep pointing nowhere, an unknown line. A bad meta must fail
            closed to a recompile, never to a crash and never to trusting
            the cached object.

Every output is reproducible: the list is fixed, no randomness, no seed.
A MANIFEST.txt records "<dir> <mutation>" per mutant, in order.
"""

import argparse
import os
import shutil
import sys

LONG_X = "x" * 100000
LONG_NAME = "x" * 5000


def proj_mutants(pristine):
    """(name, mutated aster.proj bytes) for every aster.proj mutation."""
    p = pristine
    return [
        ("dup-source", p + b"src/util.ast\n"),
        ("dup-source-respelled", p + b"./src/util.ast\nsrc/../src/util.ast\n"),
        ("dup-kind", p + b"kind exe\n"),
        ("dup-test", p + b"test tests/util_test.ast\n"),
        ("kind-bad", p.replace(b"src/main.ast", b"kind banana\nsrc/main.ast", 1)),
        ("kind-empty", p.replace(b"src/main.ast", b"kind\nsrc/main.ast", 1)),
        ("kind-extra", p.replace(b"src/main.ast", b"kind exe extra\nsrc/main.ast", 1)),
        ("kind-apk-no-package", p.replace(b"src/main.ast", b"kind apk\nsrc/main.ast", 1)),
        ("name-dotdot", p.replace(b"src/main.ast", b"name ../x\nsrc/main.ast", 1)),
        ("name-empty", p.replace(b"src/main.ast", b"name\nsrc/main.ast", 1)),
        ("name-space", p.replace(b"src/main.ast", b"name foo bar\nsrc/main.ast", 1)),
        ("name-slash", p.replace(b"src/main.ast", b"name a/b\nsrc/main.ast", 1)),
        ("name-dot", p.replace(b"src/main.ast", b"name .\nsrc/main.ast", 1)),
        ("name-long", p.replace(b"src/main.ast", ("name " + LONG_NAME + "\n").encode(), 1)),
        ("long-source-line", p + LONG_X.encode() + b"\n"),
        ("long-line-no-newline", p + LONG_X.encode()),
        ("truncated-half", p[:len(p) // 2]),
        ("truncated-mid-line", p[:len(p) - 3]),
        ("nul-bytes", p.replace(b"src/util.ast", b"src/util\x00.ast\nsrc/util\xff.ast", 1)),
        ("crlf", p.replace(b"\n", b"\r\n")),
        ("only-comments", b"# comment\n# another\n"),
        ("empty", b""),
        ("only-blank-lines", b"\n\n   \n\t\n"),
        ("min-sdk-bad", p.replace(b"src/main.ast", b"min-sdk abc\nsrc/main.ast", 1)),
        ("min-sdk-neg", p.replace(b"src/main.ast", b"min-sdk -1\nsrc/main.ast", 1)),
        ("min-sdk-huge", p.replace(b"src/main.ast", b"min-sdk 99999999999999999999\nsrc/main.ast", 1)),
        ("page-size-bad", p.replace(b"src/main.ast", b"page-size 8192\nsrc/main.ast", 1)),
        ("key-bits-bad", p.replace(b"src/main.ast", b"key-bits 1024\nsrc/main.ast", 1)),
        ("sign-mode-bad", p.replace(b"src/main.ast", b"sign-mode banana\nsrc/main.ast", 1)),
        ("source-dotdot-escape", p + b"../outside.ast\n"),
        ("source-absolute", p + b"/tmp/abs.ast\n"),
        ("source-empty-name", p + b"\n"),
        ("unknown-key-line", p + b"frobnicate yes\n"),
        ("blank-lines-and-spaces", b"\n   \n" + p.replace(b"\n", b"   \n") + b"\t\n"),
        ("no-trailing-newline", p.rstrip(b"\n")),
        ("tab-separated-kind", p.replace(b"src/main.ast", b"kind\texe\nsrc/main.ast", 1)),
        ("test-missing", p + b"test tests/nope.ast\n"),
        ("source-missing", p + b"src/nope.ast\n"),
    ]


def flip_hex(text):
    """Flip the first hex digit of the first 64-hex run in text."""
    for i, ch in enumerate(text):
        if ch in "0123456789abcdef":
            return text[:i] + ("0" if ch != "0" else "1") + text[i + 1:]
    return text


def meta_mutants(meta_text):
    """(name, mutated .meta bytes) for every cache-meta mutation."""
    lines = meta_text.split("\n")
    src_line = next((ln for ln in lines if ln.startswith("src ")), "")
    obj_line = next((ln for ln in lines if ln.startswith("obj ")), "")
    src_path = src_line.split(" ")[1] if src_line.count(" ") >= 1 else "src/main.ast"
    src_hash = src_line.rsplit(" ", 1)[-1] if " " in src_line else "0" * 64
    out = []

    def with_lines(new_lines):
        return ("\n".join(new_lines) + "\n").encode()

    out.append(("truncate-half", meta_text[:len(meta_text) // 2].encode()))
    out.append(("truncate-empty", b""))
    out.append(("truncate-1byte", meta_text[:1].encode()))
    out.append(("obj-hash-flip", meta_text.replace(obj_line, flip_hex(obj_line), 1).encode()))
    out.append(("src-hash-flip", meta_text.replace(src_line, flip_hex(src_line), 1).encode()))
    out.append(("src-line-short-hash",
                meta_text.replace(src_line, "src %s abc" % src_path, 1).encode()))
    out.append(("src-line-no-hash",
                meta_text.replace(src_line, "src %s" % src_path, 1).encode()))
    out.append(("no-src-line", with_lines([ln for ln in lines if not ln.startswith("src ")])))
    out.append(("no-obj-line", with_lines([ln for ln in lines if not ln.startswith("obj ")])))
    out.append(("wrong-version", meta_text.replace("version ", "version 9.9.9-dev", 1).encode()))
    out.append(("wrong-flags", meta_text.replace("flags ", "flags ???|4096", 1).encode()))
    out.append(("dup-src-line", meta_text.replace(src_line, src_line + "\n" + src_line, 1).encode()))
    out.append(("dup-obj-line", meta_text.replace(obj_line, obj_line + "\n" + obj_line, 1).encode()))
    out.append(("nul-bytes", meta_text.replace(src_line, src_line + "\x00junk", 1).encode()))
    out.append(("long-line", (meta_text + "x" * 100000 + "\n").encode()))
    out.append(("dep-nonexistent",
                with_lines(lines + ["dep " + "0" * 64 + " /nonexistent/nope.ast"])))
    out.append(("dep-garbage-hash",
                with_lines(lines + ["dep zzz " + src_path])))
    out.append(("unknown-line", with_lines(lines + ["zzz whatever this is"])))
    out.append(("src-line-wrong-path",
                meta_text.replace(src_line, "src src/other.ast " + src_hash, 1).encode()))
    out.append(("obj-line-short", meta_text.replace(obj_line, "obj abc", 1).encode()))
    out.append(("version-empty", meta_text.replace("version ", "version \nversion ", 1).encode()))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--project", required=True, help="pristine project dir (warm cache)")
    ap.add_argument("--outdir", required=True)
    args = ap.parse_args()

    proj_path = os.path.join(args.project, "aster.proj")
    with open(proj_path, "rb") as fh:
        pristine = fh.read()

    cache = os.path.join(args.project, "build", ".cache")
    metas = [os.path.join(cache, n) for n in sorted(os.listdir(cache))
             if n.endswith(".meta")] if os.path.isdir(cache) else []
    main_meta = None
    for m in metas:
        with open(m, "r", errors="replace") as fh:
            if "src src/main.ast " in fh.read():
                main_meta = m
                break
    if main_meta is None:
        print("FAIL: no warm cache meta for src/main.ast in %s" % cache, file=sys.stderr)
        return 1
    with open(main_meta, "rb") as fh:
        meta_text = fh.read().decode(errors="replace")

    os.makedirs(args.outdir, exist_ok=True)
    manifest = []

    for i, (name, blob) in enumerate(proj_mutants(pristine), 1):
        d = os.path.join(args.outdir, "proj-%02d" % i)
        shutil.copytree(args.project, d, ignore=shutil.ignore_patterns("build"))
        with open(os.path.join(d, "aster.proj"), "wb") as fh:
            fh.write(blob)
        manifest.append("proj-%02d %s" % (i, name))

    for i, (name, blob) in enumerate(meta_mutants(meta_text), 1):
        d = os.path.join(args.outdir, "meta-%02d" % i)
        shutil.copytree(args.project, d)
        with open(os.path.join(d, "build", ".cache", os.path.basename(main_meta)), "wb") as fh:
            fh.write(blob)
        manifest.append("meta-%02d %s" % (i, name))

    with open(os.path.join(args.outdir, "MANIFEST.txt"), "w") as fh:
        fh.write("\n".join(manifest) + "\n")
    print("proj/meta corpus: %d proj + %d meta mutants in %s"
          % (len(proj_mutants(pristine)), len(meta_mutants(meta_text)), args.outdir))
    return 0


if __name__ == "__main__":
    sys.exit(main())
