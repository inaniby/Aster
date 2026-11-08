#!/bin/sh
# tests/alias-const-checks.sh — two declaration forms Aster never had.
#
# AUDIT-v0.23.61-dev.md's third part listed the language's gaps in order of
# cost-effectiveness and asked for them to be closed: `typedef`/type alias
# (1), `const` (2), `void` (3), `char` (4), `union` (5). This round closes the
# first two; `void` stays queued.
#
#   `type Name = T ;`   a name for a type, declared at file scope beside
#                       struct and enum, and expanded at the moment its name
#                       is read. There is no Ty::Alias: a Ty is a (kind,
#                       index) pair with no room for a spelling, so the name
#                       is gone before layout, Sema or codegen ever run. The
#                       one thing a Ty cannot carry — a function signature —
#                       travels in the alias record and is handed back at
#                       every use, so `type Op = fn(i32) -> i64;` is a real
#                       signature at every declaration that names it.
#
#   `const x : T = e;`  a binding no assignment may change, at file scope and
#                       in a function body. Every store is refused — `x = e`,
#                       `x += e`, `x++`, an element store `a[i] = e`, a field
#                       store `s.f = e`, and the address `&x`, because an
#                       Aster ptr carries no read-only bit of its own and
#                       `*p = v` would be the one way back in. A const must
#                       be given a value; reading one is reading a let.
#
# What the round deliberately does not do: `type` is not a cast spelling
# (`T(x)` stays the type keywords alone, so an identifier there is still a
# call), and an alias cannot stand for an array (`i32[4]` is a declaration
# form, not a type). The guarantee is the compiler's, not the image's — a
# const global occupies the same .data bytes a let global does.
#
# The oracle for both is gcc: `typedef` and `const` are C spellings, so each
# behavioural case has a C twin and the two must agree on the exit status
# under qemu, and each *refusal* has a C twin gcc must refuse too. The one
# refusal C does not share is `&const` — C happily hands out a `const int *`
# — and the suite says so rather than pretending otherwise.
#
# Layers (the project 9-layer shape): strict build; source guards pinning
# every piece of the machinery plus the reserved-word list; an independent
# reader (a Python alias expander proving the alias is a spelling and not a
# type, by byte equality); a gcc differential over ten cases; a refusal
# matrix, six of whose entries gcc must refuse as well; the shipped examples
# against their C twins; coverage counting; six mutations; and the byte
# baseline, which asserts every pre-existing row is unchanged.

set -eu
cd "$(dirname "$0")/.."
. tests/lib/baseline.sh
. tests/lib/verdict.sh
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-alias-const-checks}
W="$OUT/work"
mkdir -p "$W"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
run(){ sh "$RUNNER" "$@"; }

# The differential and the behavioural witnesses need a cross gcc and a way to
# run AArch64; without them those layers say SKIP with a reason and the rest
# of the suite still runs.
HOSTCC=${HOSTCC:-}
if [ -z "$HOSTCC" ] && command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    HOSTCC=aarch64-linux-gnu-gcc
fi
if [ -z "$HOSTCC" ] && command -v cc >/dev/null 2>&1; then HOSTCC=cc; fi
have_qemu=yes
command -v qemu-aarch64 >/dev/null 2>&1 || have_qemu=no
case $(uname -m) in aarch64|arm64) have_qemu=yes ;; esac
if [ "$have_qemu" = yes ] && [ -n "$HOSTCC" ]; then
    printf 'int main(void){return 0;}\n' > "$W/probe.c"
    if ! "$HOSTCC" -O2 -fwrapv "$W/probe.c" -o "$W/probe" >/dev/null 2>&1; then
        have_qemu=no
    elif ! run "$W/probe" >/dev/null 2>&1; then
        have_qemu=no
    fi
fi

# ---------------------------------------------------------------------------
# [1/9] Strictly build the Aster compiler
printf '%s\n' '[1/9] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"
A=$OUT/aster

# ---------------------------------------------------------------------------
# [2/9] Source guards. Each piece of the two features is pinned by its text.
printf '%s\n' '[2/9] Source guards: the alias machinery and the const machinery'
guard_count=0
guard(){ # $1 = literal source text, $2 = what it is
    grep -qF "$1" src/aster.cpp \
        || { printf 'FAIL: %s is gone\n' "$2" >&2; exit 1; }
    guard_count=$((guard_count + 1))
}
grep -qF '#define ASTER_VERSION_STRING "0.23.74-dev"' src/aster.cpp \
    || { echo "FAIL: the version constant is not 0.23.74-dev" >&2; exit 1; }
guard '    Type,                // v0.23.67-dev: `type Name = T;`' 'the Type token'
guard '    Const,               // v0.23.67-dev: `const x : T = e;`' 'the Const token'
guard 'else if(x=="type")k=TK::Type; else if(x=="const")k=TK::Const;' 'the two new reserved words'
guard 'struct TypeAlias { Ty ty=Ty::I32; bool isFunc=false; FuncSig sig; };' 'the alias record'
guard 'static std::map<std::string,TypeAlias> g_typeAlias;' 'the alias table'
guard 'static const TypeAlias* typeAliasOf(const std::string& name){' 'the alias lookup'
guard 'if(const TypeAlias* ta=typeAliasOf(cur().s)){' 'the expansion in parseType'
guard 'if(ta->isFunc){pendingFuncType=true;pendingFuncSig=ta->sig;}' 'the signature an alias carries'
guard 'void typeAliasDeclaration(){' 'the type-alias declaration'
guard 'if(eat(TK::Type)){typeAliasDeclaration();continue;}' 'the file-scope hook'
guard '"duplicate type alias: "+id.s' 'the duplicate-name refusal'
guard '"type alias conflicts with a struct: "+id.s' 'the struct-name collision refusal'
guard 'if(eat(TK::Const)){globalDeclaration(false,false,true);continue;}' 'the file-scope const hook'
guard 'if(eat(TK::Const))return letStatement(true);' 'the local const hook'
guard 'Stmt letStatement(bool isConst=false){' 'the const flag on a let'
guard 'bool isConst=false; };' 'the const flag in a Sema binding'
guard 'bool isConstName(const std::string& n) const {' 'the one read-only question'
guard 'const std::set<std::string>& constGlobals;' 'the const globals reaching Sema'
guard 'if(b->isConst)throw Error(loc(s.line,s.col,"cannot assign to a const: "+s.name));' 'the refusal at an assignment'
guard 'if(isConstName(s.name))throw Error(loc(s.line,s.col,"cannot assign to a const: "+s.name));' 'the refusal at an element store'
guard 'if(s.idx->a&&s.idx->a->k==Expr::Var&&isConstName(s.idx->a->name))' 'the refusal at a field store'
guard '"cannot take the address of a const: "+e.a->name' 'the refusal at address-of'
guard '"a const must have an initializer: "+id.s' 'the initializer requirement'
# The refusals appear once per store site; the count is part of the guard so a
# later round cannot quietly drop one of them.
[ "$(grep -c 'cannot assign to a const: ' src/aster.cpp)" = 4 ] \
    || { echo 'FAIL: expected four "cannot assign to a const" sites' >&2; exit 1; }
guard_count=$((guard_count + 1))
[ "$(grep -c 'a const must have an initializer: ' src/aster.cpp)" = 3 ] \
    || { echo 'FAIL: expected three "a const must have an initializer" sites' >&2; exit 1; }
guard_count=$((guard_count + 1))
# The reserved-word list is generated, not hand-written: 32 words now that
# `type`, `const`, `void` and `char` joined it, and `tls` is still a context
# keyword.
python3 - <<'PY' || exit 1
import re
src = open('bootstrap/gen_lexer_names.py').read()
m = re.search(r'KEYWORDS = \[(.*?)\]', src, re.S)
entries = re.findall(r'\("([^"]+)",', m.group(1))
assert len(entries) == 32, ('reserved-word count moved', len(entries), entries)
assert 'type' in entries and 'const' in entries, 'type/const are not reserved words'
assert 'tls' not in entries, 'tls became a reserved word — it must stay a context keyword'
print('PASS: 32 reserved words, type and const among them, tls still a context keyword')
PY
guard_count=$((guard_count + 1))
printf '  %-30s %s\n' "guards passed" "$guard_count"

# ---------------------------------------------------------------------------
# [3/9] An independent reader: expand every alias out of the source by hand and
# require the compiler to emit byte-identical output. The expander knows
# nothing about the compiler — it rewrites the text — so byte equality is the
# proof that an alias is a spelling and not a type: had the compiler given the
# name any weight at all, the two programs could not agree.
printf '%s\n' '[3/9] Independent reader: expanding an alias out of the source changes no byte'
cat > "$OUT/expand.py" <<'PY'
import re, sys
# Read an Aster source, take every `type N = T ;` declaration out of it, and
# put T where N was — whole words only, and in declaration order so an alias
# whose own right-hand side names an earlier alias is resolved against the
# text that alias has already been replaced with.
src = open(sys.argv[1]).read()
decls = re.findall(r'^type\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^;]+);', src, re.M)
if not decls:
    sys.exit('no type alias declarations in ' + sys.argv[1])
out = re.sub(r'^type\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*[^;]+;.*\n', '', src, flags=re.M)
resolved = []
for name, ty in decls:
    t = ty.strip()
    for prev, ptxt in resolved:
        t = re.sub(r'\b' + re.escape(prev) + r'\b', ptxt, t)
    resolved.append((name, t))
    out = re.sub(r'\b' + re.escape(name) + r'\b', t, out)
for name, _ in resolved:
    if re.search(r'\b' + re.escape(name) + r'\b', out):
        sys.exit('alias ' + name + ' survived the expansion: ' + sys.argv[1])
open(sys.argv[2], 'w').write(out)
print('expanded %d alias(es): %s' % (len(resolved), ', '.join(n for n, _ in resolved)))
PY
expand_case(){ # $1 = label, $2 = source file
    python3 "$OUT/expand.py" "$2" "$W/$1.expanded.ast" > "$W/$1.expand.log" \
        || { echo "FAIL: $1 — the expander rejected the source:" >&2; cat "$W/$1.expand.log" >&2; return 1; }
    ok=1
    for mode in build-elf "build-obj --pic"; do
        tag=$(echo "$mode" | tr ' ' '_')
        if ! "$A" $mode "$2" -o "$W/$1.$tag" >/dev/null 2>&1; then
            echo "FAIL: $1 — the aliased source does not build ($mode)" >&2; return 1
        fi
        if ! "$A" $mode "$W/$1.expanded.ast" -o "$W/$1.exp.$tag" >/dev/null 2>&1; then
            echo "FAIL: $1 — the expanded source does not build ($mode)" >&2; return 1
        fi
        if ! cmp -s "$W/$1.$tag" "$W/$1.exp.$tag"; then
            echo "FAIL: $1 — $mode output differs once the aliases are written out" >&2
            return 1
        fi
    done
    printf 'PASS: %-22s aliases expanded by hand, %s byte-identical\n' "$1" "both modes"
}
cat > "$W/exp_struct.ast" <<'AST'
struct Point { x: i32, y: i32 }
type Coord = i32;
type Ptr = ptr<Point>;
type W = u16;
struct Pair { a: Coord, b: W }
let gp: Coord = 4;
fn use(q: Ptr) -> Coord { return q.x * 10 + q.y; }
fn main() -> i32 {
    let p: Point = Point { 3, 7 };
    let q: Ptr = &p;
    let pr: Pair = Pair { 5, 6 };
    let w: W = 30;
    return use(q) + pr.a + pr.b + w + gp;
}
AST
cat > "$W/exp_fn.ast" <<'AST'
type I = i32;
type Op = fn(I) -> I;
fn inc(v: I) -> I { return v + 1; }
fn apply(op: Op, v: I) -> I { return op(v); }
fn main() -> i32 { return apply(inc, 41); }
AST
cat > "$W/exp_nest.ast" <<'AST'
type I = i64;
type J = I;
type P = ptr<I>;
fn main() -> i32 {
    let v: J = 0;
    let p: P = &v;
    return i32(p[0]) + 5;
}
AST
failed=0
expand_case exp_struct "$W/exp_struct.ast" || failed=1
expand_case exp_fn "$W/exp_fn.ast" || failed=1
expand_case exp_nest "$W/exp_nest.ast" || failed=1
expand_case type_alias examples/type_alias.ast || failed=1
[ "$failed" = 0 ] || exit 1

# ---------------------------------------------------------------------------
# [4/9] The gcc differential. `typedef` and `const` are C spellings, so every
# case has an Aster source and a C source and the two must agree on the exit
# status under qemu — never a hand-computed expectation.
printf '%s\n' '[4/9] gcc differential: ten cases, Aster and C must agree'
diff_n=0
if [ "$have_qemu" != yes ]; then
    echo 'SKIP: no cross gcc or no qemu — the gcc differential did not run'
else
emit_case(){ # $1 = label
    n="$1"
    printf '%s\n' "$2" > "$W/$n.ast"
    printf '%s\n' "$3" > "$W/$n.c"
}
emit_case alias_scalar \
'type I = i32;
fn main() -> i32 { let x: I = 41; return x + 1; }' \
'typedef int I;
int main(void){ I x = 41; return x + 1; }'
emit_case alias_struct_ptr \
'struct Pt { x: i32, y: i32 }
type PP = ptr<Pt>;
fn main() -> i32 { let p: Pt = Pt { 3, 4 }; let q: PP = &p; return q.x + q.y; }' \
'typedef struct { int x, y; } Pt;
typedef Pt *PP;
int main(void){ Pt p = { 3, 4 }; PP q = &p; return q->x + q->y; }'
emit_case alias_array_elem \
'type W = u16;
fn main() -> i32 { let a: W[3] = 300; return a[0] + a[2] + 1; }' \
'typedef unsigned short W;
int main(void){ W a[3] = { 300, 300, 300 }; return a[0] + a[2] + 1; }'
emit_case alias_field \
'type I = i64;
struct Box { a: I, b: i32 }
fn main() -> i32 { let b: Box = Box { 5, 7 }; return i32(b.a) + b.b; }' \
'typedef long I;
typedef struct { I a; int b; } Box;
int main(void){ Box b = { 5, 7 }; return (int)b.a + b.b; }'
emit_case alias_param_ret \
'type I = i32;
fn twice(v: I) -> I { return v * 2; }
fn main() -> i32 { return twice(21); }' \
'typedef int I;
static I twice(I v){ return v * 2; }
int main(void){ return twice(21); }'
emit_case alias_fn_type \
'type I = i32;
type Op = fn(I) -> I;
fn inc(v: I) -> I { return v + 1; }
fn apply(op: Op, v: I) -> I { return op(v); }
fn main() -> i32 { return apply(inc, 41); }' \
'typedef int I;
typedef I (*Op)(I);
static I inc(I v){ return v + 1; }
static I apply(Op op, I v){ return op(v); }
int main(void){ return apply(inc, 41); }'
emit_case alias_sizeof \
'type I = u64;
fn main() -> i32 { return sizeof(I); }' \
'typedef unsigned long I;
int main(void){ return (int)sizeof(I); }'
# The case that proves an alias carries a *signature* and not just the word
# "ptr": a bare function pointer reads its result at i32 width, so an i64
# result comes back truncated and the branch below takes the other way out.
emit_case alias_fn_i64_ret \
'type Op = fn(i32) -> i64;
fn big(v: i32) -> i64 { let r: i64 = 0; r = r + 4294967296; return r + v; }
fn main() -> i32 {
    let op: Op = big;
    let v: i64 = op(5);
    if (v > 2147483647) { return 11; }
    return 22;
}' \
'typedef long (*Op)(int);
static long big(int v){ return 4294967296L + v; }
int main(void){ Op op = big; long v = op(5); if (v > 2147483647) return 11; return 22; }'
emit_case const_local_read \
'fn bump(v: i32) -> i32 { return v + 1; }
fn main() -> i32 { const k: i32 = 41; return bump(k); }' \
'static int bump(int v){ return v + 1; }
int main(void){ const int k = 41; return bump(k); }'
emit_case const_array_struct \
'struct Pt { x: i32, y: i32 }
const g: i32 = 4;
fn main() -> i32 {
    const xs: i32[3] = 7;
    const p: Pt = Pt { 1, 2 };
    return g + xs[0] + xs[2] + p.x + p.y;
}' \
'typedef struct { int x, y; } Pt;
static const int g = 4;
int main(void){ const int xs[3] = { 7, 7, 7 }; const Pt p = { 1, 2 };
    return g + xs[0] + xs[2] + p.x + p.y; }'

DIFF_CASES='alias_scalar alias_struct_ptr alias_array_elem alias_field alias_param_ret
alias_fn_type alias_sizeof alias_fn_i64_ret const_local_read const_array_struct'
diff_n=0
failed=0
for n in $DIFF_CASES; do
    if ! "$A" build-elf "$W/$n.ast" -o "$W/$n.a64" >"$W/$n.ab.log" 2>&1; then
        echo "FAIL: $n — Aster build failed:" >&2; cat "$W/$n.ab.log" >&2; failed=1; continue
    fi
    if ! "$HOSTCC" -O2 -fwrapv "$W/$n.c" -o "$W/$n.c64" >"$W/$n.cb.log" 2>&1; then
        echo "FAIL: $n — C oracle build failed:" >&2; cat "$W/$n.cb.log" >&2; failed=1; continue
    fi
    run "$W/$n.a64" >/dev/null 2>&1 && a=0 || a=$?
    run "$W/$n.c64" >/dev/null 2>&1 && c=0 || c=$?
    [ "$a" -gt 127 ] && a=$((a - 256))
    [ "$c" -gt 127 ] && c=$((c - 256))
    if [ "$a" != "$c" ]; then
        echo "FAIL: $n — Aster exit $a, C oracle exit $c" >&2; failed=1; continue
    fi
    diff_n=$((diff_n + 1))
    printf 'PASS: %-22s exit %s (matches C)\n' "$n" "$a"
done
[ "$failed" = 0 ] || exit 1
fi

# ---------------------------------------------------------------------------
# [5/9] The refusal matrix. Every one names the reason Aster refuses; six of
# them have a C twin gcc must refuse too, so the refusals are not merely the
# compiler's own opinion.
printf '%s\n' '[5/9] Refusal matrix: what a type alias and a const may not do'
reject(){ # $1 = label, $2 = source, $3 = reason, $4 = C twin (empty = none)
    printf '%s\n' "$2" > "$W/rej.ast"
    if "$A" build-elf "$W/rej.ast" -o "$W/rej" >"$W/rej.log" 2>&1; then
        echo "FAIL: $1 — accepted, expected: $3" >&2; return 1
    fi
    if ! grep -qF "$3" "$W/rej.log"; then
        echo "FAIL: $1 — refused, but not with \"$3\":" >&2; head -2 "$W/rej.log" >&2; return 1
    fi
    if [ -n "$4" ]; then
        if [ "$have_qemu" != yes ]; then
            printf 'PASS: %-24s %s (C twin not run: no cross gcc)\n' "$1" "$3"
            return 0
        fi
        printf '%s\n' "$4" > "$W/rej.c"
        if "$HOSTCC" -O2 -fwrapv "$W/rej.c" -o "$W/rej.c64" >"$W/rej.c.log" 2>&1; then
            echo "FAIL: $1 — gcc accepted the C twin, so the refusal is Aster's alone" >&2
            return 1
        fi
        printf 'PASS: %-24s %s (gcc refuses too)\n' "$1" "$3"
        return 0
    fi
    printf 'PASS: %-24s %s\n' "$1" "$3"
    return 0
}
CONST_PRE='struct Pt { x: i32, y: i32 }
const g: i32 = 41;
fn main() -> i32 { '
failed=0
rej_n=0
r(){ reject "$@" && rej_n=$((rej_n + 1)) || failed=1; }
r 'alias: unknown type' \
'type P = Nope;
fn main() -> i32 { return 0; }' \
"expected a type after '=' in the declaration of type alias P" ''
r 'alias: duplicate name' \
'type P = i32;
type P = i64;
fn main() -> i32 { return 0; }' \
'duplicate type alias: P' ''
r 'alias: struct collision' \
'struct P { x: i32 }
type P = i32;
fn main() -> i32 { return 0; }' \
'type alias conflicts with a struct: P' ''
r 'alias: global collision' \
'let P: i32 = 1;
type P = i32;
fn main() -> i32 { return 0; }' \
'type alias conflicts with a global variable: P' ''
r 'alias: not an array' \
'type Row = i32[4];
fn main() -> i32 { return 0; }' \
"expected ';' after a type alias declaration" ''
r 'alias: undeclared use' \
'let g: P = 1;
fn main() -> i32 { return 0; }' \
'expected i32, i64, u8, u16, u32, u64, ptr, ptr<S>, bool' ''
r 'const: plain assignment' \
"${CONST_PRE}const k: i32 = 1; k = 2; return k; }" \
'cannot assign to a const: k' \
'int main(void){ const int k = 1; k = 2; return k; }'
r 'const: compound assignment' \
"${CONST_PRE}const k: i32 = 1; k += 2; return k; }" \
'cannot assign to a const: k' \
'int main(void){ const int k = 1; k += 2; return k; }'
r 'const: increment' \
"${CONST_PRE}const k: i32 = 1; k++; return k; }" \
'cannot assign to a const: k' \
'int main(void){ const int k = 1; k++; return k; }'
r 'const: element store' \
"${CONST_PRE}const a: i32[3] = 5; a[0] = 6; return a[0]; }" \
'cannot assign to a const: a' \
'int main(void){ const int a[3] = { 5, 5, 5 }; a[0] = 6; return a[0]; }'
r 'const: field store' \
"${CONST_PRE}const s: Pt = Pt { 1, 2 }; s.x = 3; return s.x; }" \
'cannot assign to a const: s' \
'typedef struct { int x, y; } Pt;
int main(void){ const Pt s = { 1, 2 }; s.x = 3; return s.x; }'
r 'const: file-scope store' \
"${CONST_PRE}g = 7; return g; }" \
'cannot assign to a const: g' \
'static const int g = 41;
int main(void){ g = 7; return g; }'
# The one refusal C does not share: C hands out a `const int *` happily,
# because its type system can say "pointer to const". Aster's ptr cannot, so
# the address is the hole the language closes by refusing to hand it out.
r 'const: address-of (Aster only)' \
"${CONST_PRE}const k: i32 = 1; let p: ptr<i32> = &k; return k; }" \
'cannot take the address of a const: k' ''
r 'const: no initializer (local)' \
"${CONST_PRE}const k: i32; return 0; }" \
"expected '='" ''
r 'const: no initializer (struct)' \
"${CONST_PRE}const s: Pt; return 0; }" \
'a const must have an initializer: s' ''
r 'const: no initializer (global)' \
'const g2: i32;
fn main() -> i32 { return 0; }' \
"expected '=' in global variable declaration" ''
[ "$failed" = 0 ] || exit 1
printf '  %-30s %s\n' "refusals held" "$rej_n"

# ---------------------------------------------------------------------------
# [6/9] The shipped examples, each against its C twin.
printf '%s\n' '[6/9] The shipped examples against their C twins'
if [ "$have_qemu" != yes ]; then
    echo 'SKIP: no cross gcc or no qemu — the example witnesses did not run'
else
for pair in 'type_alias:tests/type-alias-twin.c' 'const_binding:tests/const-binding-twin.c'; do
    ex=${pair%%:*}; twin=${pair#*:}
    if ! "$A" build-elf "examples/$ex.ast" -o "$W/$ex" >"$W/$ex.log" 2>&1; then
        echo "FAIL: examples/$ex.ast no longer builds:" >&2; cat "$W/$ex.log" >&2; exit 1
    fi
    if ! "$HOSTCC" -O2 -fwrapv "$twin" -o "$W/$ex.c64" >"$W/$ex.c.log" 2>&1; then
        echo "FAIL: $twin no longer builds:" >&2; cat "$W/$ex.c.log" >&2; exit 1
    fi
    run "$W/$ex" >/dev/null 2>&1 && ae=0 || ae=$?
    run "$W/$ex.c64" >/dev/null 2>&1 && ce=0 || ce=$?
    [ "$ae" -gt 127 ] && ae=$((ae - 256))
    [ "$ce" -gt 127 ] && ce=$((ce - 256))
    if [ "$ae" != "$ce" ]; then
        echo "FAIL: examples/$ex.ast exit $ae, $twin exit $ce" >&2; exit 1
    fi
    printf 'PASS: %-22s exit %s (matches C)\n' "$ex" "$ae"
done
# A const is read, not folded: the value a call returned is kept just as a
# let would keep it, and a struct const is read field by field.
cat > "$W/const_read.ast" <<'AST'
struct Pt { x: i32, y: i32 }
fn bump(v: i32) -> i32 { return v + 1; }
fn main() -> i32 {
    const k: i32 = bump(41);
    const p: Pt = Pt { 1, 2 };
    return k + p.x + p.y;
}
AST
"$A" build-elf "$W/const_read.ast" -o "$W/const_read" >/dev/null 2>&1 \
    || { echo 'FAIL: a const initialized by a call no longer builds' >&2; exit 1; }
run "$W/const_read" >/dev/null 2>&1 && cre=$? || cre=$?
[ "$cre" = 45 ] || { echo "FAIL: const_read exit $cre, expected 45" >&2; exit 1; }
printf 'PASS: %-22s exit %s\n' 'const_read' "$cre"
fi

# ---------------------------------------------------------------------------
# [7/9] Coverage counting: the layers have to be carrying their weight.
printf '%s\n' '[7/9] Coverage: the layers are not vacuous'
[ "$guard_count" -ge 22 ] || { echo "FAIL: only $guard_count source guards, expected at least 22" >&2; exit 1; }
[ "$rej_n" -ge 15 ] || { echo "FAIL: only $rej_n refusals held, expected at least 15" >&2; exit 1; }
printf '  %-30s %s\n' "source guards" "$guard_count"
printf '  %-30s %s\n' "refusals" "$rej_n"
printf '  %-30s %s\n' "expander cases" "4"
printf '  %-30s %s\n' "gcc differential cases" "$diff_n"

# ---------------------------------------------------------------------------
# [8/9] Mutations. Each piece has to be load-bearing.
printf '%s\n' '[8/9] The suite can still fail (six mutations)'
mutate(){ # $1 = label, $2 = sed script
    sed "$2" src/aster.cpp > "$OUT/$1.cpp"
    if cmp -s src/aster.cpp "$OUT/$1.cpp"; then
        echo "FAIL: mutation $1 did not apply — blind" >&2; exit 1
    fi
    $CXX -std=c++17 -O2 -w "$OUT/$1.cpp" -o "$OUT/$1" 2>/dev/null \
        || { echo "FAIL: mutation $1 no longer compiles" >&2; exit 1; }
}
# (a) An alias expands to whatever it was declared as — mutate that to "every
# alias means i32". examples/type_alias.ast stops building.
mutate m1 's|                    out=ta->ty;|                    out=Ty::I32;|'
if "$OUT/m1" build-elf examples/type_alias.ast -o "$W/m1" >/dev/null 2>&1; then
    echo 'FAIL: mutation (a) went unnoticed — aliases still mean what they say' >&2; exit 1
fi
printf '  %-40s %s\n' 'a) every alias expands to i32' 'noticed'
# (b) An assignment to a const is refused at a local binding.
mutate m2 's|if(b->isConst)throw Error(loc(s.line,s.col,"cannot assign to a const: "|if(false)throw Error(loc(s.line,s.col,"cannot assign to a const: "|'
printf '%s\n' 'fn main() -> i32 { const k: i32 = 1; k = 2; return k; }' > "$W/m2.ast"
# The original refuses `k = 2`; the mutant accepts it, so the mutant builds.
if "$OUT/m2" build-elf "$W/m2.ast" -o "$W/m2" >/dev/null 2>&1; then
    printf '  %-40s %s\n' 'b) a const may be assigned to' 'noticed'
else
    echo 'FAIL: mutation (b) went unnoticed — the refusal is not what blocks the assignment' >&2; exit 1
fi
# (c) isConstName answers for an element store, a field store and address-of.
mutate m3 's|        if(const Binding\* b=find(n))return b->isConst;|        if(const Binding* b=find(n))return false;|'
printf '%s\n' 'fn main() -> i32 { const a: i32[2] = 5; a[0] = 6; return a[0]; }' > "$W/m3.ast"
# The original refuses the element store; the mutant accepts it, so it builds.
if "$OUT/m3" build-elf "$W/m3.ast" -o "$W/m3" >/dev/null 2>&1; then
    printf '  %-40s %s\n' 'c) a const element may be written' 'noticed'
else
    echo 'FAIL: mutation (c) went unnoticed — isConstName is not what blocks the store' >&2; exit 1
fi
# (d) An alias to a function type carries the signature. Without it `op` is a
# bare function pointer and an i64 result comes back truncated: 22, not 11.
# The witness is written here rather than taken from [4/9], because [4/9] is
# the layer that may skip.
cat > "$W/fnsig.ast" <<'AST'
type Op = fn(i32) -> i64;
fn big(v: i32) -> i64 { let r: i64 = 0; r = r + 4294967296; return r + v; }
fn main() -> i32 {
    let op: Op = big;
    let v: i64 = op(5);
    if (v > 2147483647) { return 11; }
    return 22;
}
AST
mutate m4 's|if(pendingFuncType){a.isFunc=true;|if(false){a.isFunc=true;|'
if [ "$have_qemu" != yes ]; then
    echo 'SKIP: mutation (d) needs qemu — the signature witness did not run'
elif ! "$OUT/m4" build-elf "$W/fnsig.ast" -o "$W/m4" >/dev/null 2>&1; then
    echo 'FAIL: mutation (d) — the mutant does not build the witness at all' >&2; exit 1
else
    run "$W/m4" >/dev/null 2>&1 && m4rc=$? || m4rc=$?
    if [ "$m4rc" = 11 ]; then
        echo 'FAIL: mutation (d) went unnoticed — the i64 result still comes back whole' >&2; exit 1
    fi
    printf '  %-40s %s\n' 'd) an alias drops the signature' "noticed (exit $m4rc, expected 11)"
fi
# (e) A const local must be given a value.
mutate m5 '/v0.23.67-dev: not for a const/,+4 s|if(isConst)throw Error|if(false)throw Error|'
printf '%s\n' 'struct Pt { x: i32, y: i32 }
fn main() -> i32 { const p: Pt; return 0; }' > "$W/m5.ast"
# The original refuses a const with no initializer; the mutant accepts it.
if "$OUT/m5" build-elf "$W/m5.ast" -o "$W/m5" >/dev/null 2>&1; then
    printf '  %-40s %s\n' 'e) a const needs no initializer' 'noticed'
else
    echo 'FAIL: mutation (e) went unnoticed — the initializer rule is not what blocks it' >&2; exit 1
fi
# (f) A duplicate type alias is refused. v0.23.74-dev (F-04) moved the
# duplicate-name check into the shared rejectTagConflict(); neutralise the
# alias-table branch there so the refusal goes inert.
mutate m6 's|if(g_typeAlias.count(id.s)){|if(false){|'
printf '%s\n' 'type P = i32;
type P = u16;
fn main() -> i32 { let x: P = 300; return x; }' > "$W/m6.ast"
if "$OUT/m6" build-elf "$W/m6.ast" -o "$W/m6" >/dev/null 2>&1; then
    printf '  %-40s %s\n' 'f) a name may be aliased twice' 'noticed'
else
    echo 'FAIL: mutation (f) went unnoticed — the duplicate-name refusal is inert' >&2; exit 1
fi

# ---------------------------------------------------------------------------
# [9/9] The byte baseline. Two claims: the 372 rows reproduce, and every row
# that already existed in v0.23.66-dev is byte-identical still — earlier rounds
# added four files (type_alias, const_binding, void_return among them) and no
# program written before them may compile to different bytes because of any.
printf '%s\n' '[9/9] Byte baseline: no pre-existing program moved'
BASE=$(aster_baseline_file)
: > "$OUT/hashes.txt"
for mode in build-so build-elf "build-obj --pic"; do
    tag=$(echo "$mode" | tr ' ' '_')
    for f in examples/*.ast; do
        b=$(basename "$f" .ast)
        # shellcheck disable=SC2086
        if "$A" $mode "$f" -o "$OUT/$b.$tag" >/dev/null 2>&1; then
            printf '%s %s\n' "$b.$tag" "$(sha256sum "$OUT/$b.$tag" | cut -d' ' -f1)" >> "$OUT/hashes.txt"
        else
            printf '%s FAILED\n' "$b.$tag" >> "$OUT/hashes.txt"
        fi
    done
done
grep -v '^address_of_abi\.' "$OUT/hashes.txt" | LC_ALL=C sort > "$OUT/hashes.filtered.txt"
LC_ALL=C sort "$BASE" > "$OUT/base.sorted.txt"
if ! diff -u "$OUT/base.sorted.txt" "$OUT/hashes.filtered.txt" > "$OUT/hashes.diff"; then
    echo 'FAIL: the byte baseline no longer reproduces' >&2
    sed -n '1,20p' "$OUT/hashes.diff" >&2
    exit 1
fi
rows=$(wc -l < "$OUT/hashes.filtered.txt")
# 131 examples x 3 modes, less the three address_of_abi rows every release
# filters (v0.23.73-dev adds examples/stack_arg_abi.ast and
# examples/stride_scale.ast). Asserted so a later round cannot silently drop
# one; every row inherited from the previous release is byte-identical.
[ "$rows" = 390 ] || { echo "FAIL: $rows baseline rows, expected 390" >&2; exit 1; }
printf '  %-30s %s\n' "baseline rows reproduced" "$rows"
# The previous release's frozen baseline — derived, never a hardcoded path
# (the CI protocol check forbids literal versioned baseline paths).
_cur_v=$(aster_baseline_version)
_prev_v=$(ls tests/baseline/ | grep -v "^v${_cur_v}\$" | sort -V | tail -1)
if [ -n "$_prev_v" ]; then
    PREV="tests/baseline/${_prev_v}/example-hashes.txt"
    if [ -f "$PREV" ]; then
        moved=$(awk 'NR==FNR{a[$1]=$2;next} ($1 in a) && a[$1]!=$2 {print $1}' \
                     "$PREV" "$OUT/hashes.filtered.txt")
        prev_rows=$(wc -l < "$PREV")
        if [ -n "$moved" ]; then
            echo 'FAIL: this round moved bytes of a program written before it:' >&2
            printf '%s\n' "$moved" >&2
            exit 1
        fi
        printf '  %-30s %s\n' "pre-existing rows unchanged" "$prev_rows"
    fi
fi

printf '%s\n' 'PASS: all v0.23.67-dev alias and const checks'
