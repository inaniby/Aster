#!/bin/sh
# v0.22.43-dev: comment syntax regression checks (// line comments, /* */ block
# comments, unterminated block comment must be an error).
set -eu
cd "$(dirname "$0")/.."

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# 1) A program whose only "code" is wrapped in comments must still compile.
cat >"$tmpdir/commented.ast" <<'EOF'
/* Aster supports comments as of v0.22.43-dev.
   This block comment spans multiple lines. */
fn main() -> i32 { // trailing line comment
    let x: i32 = 42; /* inline block comment */
    // full-line comment
    return x; /* trailing */
}
EOF
./aster build-elf "$tmpdir/commented.ast" -o "$tmpdir/commented"
if ! llvm-objdump -d "$tmpdir/commented" | grep -q 'mov	w0, #0x2a'; then
    echo "FAIL: commented program did not compile to 'return 42'" >&2
    exit 1
fi
echo "OK: // and /* */ comments are skipped by the lexer"

# 2) Unterminated block comment must be a lex error.
cat >"$tmpdir/unterminated.ast" <<'EOF'
fn main() -> i32 {
    /* this block comment never closes
    return 0;
}
EOF
if ./aster build-elf "$tmpdir/unterminated.ast" -o "$tmpdir/unterminated" >/dev/null 2>&1; then
    echo "FAIL: unterminated block comment was accepted" >&2
    exit 1
fi
if ! ./aster build-elf "$tmpdir/unterminated.ast" -o "$tmpdir/unterminated" 2>&1 | grep -q "unterminated block comment"; then
    echo "FAIL: unterminated block comment did not report a clear error" >&2
    exit 1
fi
echo "OK: unterminated block comment rejected with a clear error"

# 3) Non-ASCII bytes *outside* comments must report the dedicated diagnostic
#    (bytes inside comments are skipped with the comment itself, which is fine).
#    Note: /bin/sh printf only guarantees octal escapes, so use \344\250\255 (U+4E2D).
printf 'fn main() -> i32 {\n    let \344\250\255: i32 = 1;\n    return 0;\n}\n' >"$tmpdir/nonascii.ast"
if ./aster build-elf "$tmpdir/nonascii.ast" -o "$tmpdir/nonascii" >/dev/null 2>&1; then
    echo "FAIL: non-ASCII comment byte was accepted" >&2
    exit 1
fi
if ! ./aster build-elf "$tmpdir/nonascii.ast" -o "$tmpdir/nonascii" 2>&1 | grep -q "non-ASCII character"; then
    echo "FAIL: non-ASCII source did not report the dedicated diagnostic" >&2
    exit 1
fi
echo "OK: non-ASCII source reports 'non-ASCII character'"

echo "=== comment checks: ALL PASSED ==="
