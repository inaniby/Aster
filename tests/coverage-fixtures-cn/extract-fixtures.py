#!/usr/bin/env python3
"""Extract heredoc .ast programs from the cn suite scripts into
tests/coverage-fixtures-cn/ (self-contained coverage corpus fixtures).

Byte-identical extraction: file contents are NOT edited (no header added);
provenance lives in MANIFEST.md next to the fixtures. Skips:
  - aster.proj blocks (extracted separately, same relative layout)
  - *.expected files, probe.c (not Aster programs)
  - signed-narrow-overflow.ast (unquoted heredoc, $type/$value template)
Reads only the suite scripts; writes only tests/coverage-fixtures-cn/.
"""
import os, re, sys

REPO = os.path.expanduser("~/workspace/projects/Aster-cn-s1s2-fix")
TESTS = os.path.join(REPO, "tests")
OUT = os.path.join(TESTS, "coverage-fixtures-cn")

SUITES = [
    "cn-lexer-checks.sh", "cn-parser-checks.sh", "cn-ast-equiv-checks.sh",
    "cn-backend-checks.sh", "cn-module-checks.sh", "cn-constructor-checks.sh",
    "cn-interface-checks.sh", "cn-override-checks.sh", "cn-class-checks.sh",
    "cn-closure-checks.sh", "cn-embed-checks.sh", "cn-apk-checks.sh",
    "cn-diag-checks.sh", "cn-format-checks.sh", "cn-runtime-checks.sh",
    "cn-sema-checks.sh", "cn-types-checks.sh",
    "cn-traditional-surface-checks.sh", "decl-layout-checks.sh",
]

# heredoc start: cat > "<target>" <<'TAG'  (TAG quoted) or <<TAG (unquoted)
HEREDOC = re.compile(r"""^(\s*)cat > "([^"]+)" <<('?)([A-Za-z_][A-Za-z0-9_]*)('?)\s*$""")

SKIP_BASENAMES = {"signed-narrow-overflow.ast", "probe.c"}
CJK = re.compile(r"[\u4e00-\u9fff]")

def lang_guess(path, body):
    first = body.split("\n", 1)[0] if body else ""
    m = re.match(r"//\s*aster:language=(zh|en)\b", first)
    if m:
        return m.group(1) + " (directive)"
    base = os.path.basename(path)
    if "-zh." in base or base.startswith("zh") or "-zh-" in base:
        return "zh?"
    if "-en." in base or base.startswith("en") or "-en-" in base:
        return "en?"
    if CJK.search(body):
        return "zh?"
    if re.search(r"(?m)^(fn|struct|class|let|const|package|interface class|extern fn)\b", body):
        return "en?"
    return "?"

def target_rel(target):
    # "$TMP/packages/calc-zh.ast" -> "packages/calc-zh.ast"
    # "$dir/src/counter.ast" -> "src/counter.ast"
    t = target
    t = re.sub(r"^\$TMP/", "", t)
    t = re.sub(r"^\$dir/", "", t)
    t = re.sub(r"^\$TMP", "", t)
    return t.lstrip("/")

def main():
    os.makedirs(OUT, exist_ok=True)
    manifest = []
    counts = {}
    for suite in SUITES:
        spath = os.path.join(TESTS, suite)
        lines = open(spath, encoding="utf-8").read().split("\n")
        i = 0
        n_files = 0
        while i < len(lines):
            m = HEREDOC.match(lines[i])
            if not m:
                i += 1
                continue
            quoted, target, tag = m.group(3), m.group(2), m.group(4)
            start = i + 1
            j = start
            while j < len(lines) and lines[j] != tag:
                j += 1
            if j >= len(lines):
                print(f"WARN {suite}:{i+1}: unterminated heredoc {tag}", file=sys.stderr)
                break
            body = "\n".join(lines[start:j])
            if body:
                body += "\n"
            rel = target_rel(target)
            base = os.path.basename(rel)
            suite_dir = os.path.join(OUT, suite.replace("-checks.sh", ""))
            if base == "aster.proj":
                kind = "proj"
            elif base.endswith(".expected") or base in SKIP_BASENAMES:
                manifest.append((suite, i + 1, rel, "SKIPPED", len(body.splitlines()), "-",
                                 "skipped: expected-output / C probe / $ template"))
                i = j + 1
                continue
            else:
                kind = "ast"
            out_rel = rel
            out_path = os.path.join(suite_dir, out_rel)
            # dedup: same path, different content -> __2, __3 ...
            n = 2
            while os.path.exists(out_path):
                existing = open(out_path, encoding="utf-8").read()
                if existing == body:
                    out_path = None  # identical dup: keep first, record dup
                    break
                stem, ext = os.path.splitext(out_rel)
                out_rel = f"{stem}__{n}{ext}"
                out_path = os.path.join(suite_dir, out_rel)
                n += 1
            if out_path is None:
                manifest.append((suite, i + 1, rel, "DUP", len(body.splitlines()), "-",
                                 "identical to earlier extract; kept first copy"))
                i = j + 1
                continue
            os.makedirs(os.path.dirname(out_path), exist_ok=True)
            with open(out_path, "w", encoding="utf-8") as f:
                f.write(body)
            n_files += 1
            lg = lang_guess(rel, body) if kind == "ast" else "-"
            manifest.append((suite, i + 1, out_rel, kind, len(body.splitlines()), lg, ""))
            i = j + 1
        counts[suite] = n_files
        print(f"{suite}: {n_files} files")
    # MANIFEST.md
    mpath = os.path.join(OUT, "MANIFEST.md")
    with open(mpath, "w", encoding="utf-8") as f:
        f.write("# coverage-fixtures-cn — provenance manifest\n\n")
        f.write("Byte-identical extracts of heredoc programs from the cn suite scripts\n")
        f.write("in `tests/` (same work tree, branch `cn-s1-s2-frontend-fix`). No file\n")
        f.write("content was edited; the only changes are dedup renames (`__2`, `__3`)\n")
        f.write("where one suite writes the same path twice with different content\n")
        f.write("(e.g. `probe.ast` zh then en in cn-embed). Language is a guess for\n")
        f.write("files without a `// aster:language=` directive (`?` = unknown);\n")
        f.write("`coverage-checks.sh` runs every fixture with both `--language zh`\n")
        f.write("and `--language en`, so a wrong guess costs nothing.\n\n")
        f.write("Data files the fixtures need (created by the extractor run, same\n")
        f.write("bytes the suites create): `cn-embed/data.bin` (`A\\x01\\x02\\x03\\x04`),\n")
        f.write("`cn-embed/import/sub/helper.bin` (`Z`). D-2a drafts live in\n")
        f.write("`d2a/` (copies of `~/workspace/asterui-cn-s1s2/prototypes/d2a/`,\n")
        f.write("concatenated with the decl-layout stubs into `full-*.ast`).\n\n")
        f.write("| suite | line | fixture path | kind | lines | language | note |\n")
        f.write("|---|---|---|---|---|---|---|\n")
        for (suite, line, rel, kind, nlines, lg, note) in manifest:
            f.write(f"| {suite} | {line} | {rel} | {kind} | {nlines} | {lg} | {note} |\n")
    total = sum(counts.values())
    print(f"TOTAL {total} files -> {OUT}")
    print(f"manifest rows: {len(manifest)}")

if __name__ == "__main__":
    main()
