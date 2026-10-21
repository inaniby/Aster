#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cerrno>
#include <sys/stat.h>
#include <unistd.h>
#include <cstring>
#include <ctime>
#include <fstream>
#include <iostream>
#include <iterator>
#include <map>
#include <memory>
#include <stdexcept>
#include <set>
#include <sstream>
#include <cstdlib>
#include <string>
#include <vector>
#include <functional>            // AXML builder uses std::function

// The directory a path lives in, or "" when it has none. A relative path
// written inside a source file — @embed's, or `include`'s — resolves against
// the directory of the file that wrote it, which is C's rule for #include.
std::string dirNameOf(const std::string& p){size_t s=p.find_last_of('/');return s==std::string::npos?std::string():p.substr(0,s);}

// v0.23.13-dev: one definition of the version string. The usage banner used to
// carry its own copy and drifted (it still said 0.23.12-dev while the binary
// was 0.23.13-dev), so both places now expand this macro and cannot disagree.
// v0.23.16-dev: the e2e suite is finally executed on every host instead of
// being skipped on non-AArch64 machines. ci.sh now always compiles the test
// hosts with aarch64-linux-gnu-gcc and runs them through qemu-user via
// tests/run-aarch64.sh; the guest's Bionic-style "libc.so" DT_NEEDED is
// satisfied on glibc hosts by the guest-libc-alias.sh symlink farm. No
// compiler codegen change — A/B builds stay byte-identical.
// v0.23.24-dev: an indirect call — a call whose callee is a ptr variable
// holding a function's address, not a function name — finally branches
// through a register (BLR X9) instead of a relocated BL. No existing example
// could contain one (the shape was a compile error before), so the byte
// baseline holds by construction; the new example adds its rows.
// v0.23.25-dev: conditions grew up. `true` and `false` are now Bool literals
// (the language had none — bool constants were 0 and 1), and an if/while/for
// condition accepts any integer as well as a bool or a comparison: zero is
// false, non-zero is true, tested at the integer's own width. `?:`, `&&`,
// `||` and `!` keep their strict bool-only rule; the truthiness coercion
// lives at control-flow conditions only. The literals also exposed an old
// hole — arithmetic never rejected a bool operand, invisible while bool had
// no spelling of its own — so this round closes that too.
// v0.23.26-dev: a ptr can now be tested for null. The literal `0` becomes the
// language's null pointer constant (as in C: it may initialize, be assigned
// to, be passed to and be returned from a ptr, and nothing else crosses the
// integer/ptr line), and `==`/`!=` are defined for a ptr — against another ptr
// or against `0`. Ordering two addresses (`< <= > >=`) stays rejected, and so
// does `if (p)`: a ptr is still not a truthy type. The codegen needed no new
// encoding — `tyIs64` already counts a ptr, so the comparison path was already
// emitting `CMP Xn, Xm` at full width; the round is entirely a matter of
// which programs the type rules let through.
// v0.23.27-dev: four places where Aster's own reference disagreed with C, all
// found by writing that reference down and running every claim against the
// binary, and all corrected here.
//
//   1. `&&` and `||` shared one precedence level, so `a || b && c` read as
//      `(a || b) && c`. They are two levels now, with `&&` the tighter one.
//   2. `-` `!` `~` `*` took their operand at primary() depth, so `-s.v` read
//      as `(-s).v` and `*p.f` as `(*p).f`. A new unary() level fixes the
//      binding; `&` moves to it too, where it already behaved correctly.
//   3. `a < b == c` was rejected by the anti-chaining check even though the
//      comment above relational() said it parsed as `(a < b) == c`. The check
//      now refuses a chain within a level, not across the two.
//   4. A local `let` skipped the range check a global `let` applies, so
//      `let b: u8 = 300;` truncated to 44 inside a function while the same
//      declaration at file scope was an error. Sema applies it in both, and
//      so does codegen.
//
// None of the four changes the bytes of any program that compiled before: no
// shipped example mixes `&&` with `||`, none writes `*x.y` or `-x.y`, no
// program could previously contain `a < b == c` (it did not compile), and no
// shipped example initializes a narrow local with an out-of-range constant.
// v0.23.28-dev: an array's element type is the type that is written before the
// `[N]` — for every type, in every position. Until this release the grammar
// accepted a length only after an integer type, so `bool[N]`, a struct `S[N]`
// and a local `ptr[N]` were not declarations Aster could parse at all, and
// the type checker answered `i32` for every subscript whatever the element
// really was. The three holes and the wrong answer have one cause between
// them: the element type was never carried. It is now — in the local binding,
// in `typeOf(a[i])`, and in the address computation, which reaches a struct
// element whose size is not a power of two through MADD instead of a shift.
#define ASTER_VERSION_STRING "0.23.45-dev"

namespace {
constexpr const char* kVersion = ASTER_VERSION_STRING;
struct Error : std::runtime_error { using std::runtime_error::runtime_error; };
std::string readFile(const std::string& p) {
    std::ifstream f(p, std::ios::binary);
    if (!f) throw Error("cannot open input: " + p);
    return {std::istreambuf_iterator<char>(f), {}};
}

// Source-line cache so that diagnostics can show the offending line and a caret.
// Every parser/lexer diagnostic ends its message with " at L:C"; the top-level
// handler parses that suffix and renders the context. The AST compile entry
// points call setSourceCache() right before parsing.
std::string g_srcFile;
std::vector<std::string> g_srcLines;
static void setSourceCache(const std::string& path, const std::string& text) {
    g_srcFile = path;
    g_srcLines.clear();
    std::string cur;
    for (char ch : text) {
        if (ch == '\n') { g_srcLines.push_back(std::move(cur)); cur.clear(); }
        else if (ch != '\r') cur.push_back(ch);
    }
    g_srcLines.push_back(std::move(cur));
}
// Expand tabs to 8-column stops; returns the visual width alongside the text.
static std::string expandTabs(const std::string& s, unsigned* visWidth = nullptr) {
    std::string out; unsigned v = 0;
    for (char ch : s) {
        if (ch == '\t') { unsigned next = ((v / 8) + 1) * 8; out.append(next - v, ' '); v = next; }
        else { out.push_back(ch); ++v; }
    }
    if (visWidth) *visWidth = v;
    return out;
}
// Print a compiler diagnostic. When `msg` ends with " at L:C" and that line is
// known, also print the source line and a caret under column C. Otherwise the
// message is printed verbatim. The exact message text is preserved (it still
// carries " at L:C"), so existing `grep -F` assertions in the test suite keep
// passing unchanged.
// Append " at L:C" when a node carries a source location, so reportError() can
// render the offending source line and a caret. Nodes without a location
// (line==0) keep the bare message and fall back to the single-line diagnostic.
// The reported message text is preserved (it still carries " at L:C"), so the
// existing `grep -F` assertions in the test suite keep passing unchanged.
static std::string loc(unsigned line,unsigned col,std::string msg){
    if(line==0) return msg;
    msg += " at ";
    msg += std::to_string(line);
    msg += ':';
    msg += std::to_string(col);
    return msg;
}
static void reportError(const std::string& msg) {
    const char* file = g_srcFile.empty() ? "<source>" : g_srcFile.c_str();
    size_t at = msg.rfind(" at ");
    unsigned ln = 0, col = 0; bool haveLoc = false;
    if (at != std::string::npos) {
        const char* p = msg.c_str() + at + 4;
        char* end = nullptr;
        unsigned long L = std::strtoul(p, &end, 10);
        if (end && *end == ':') {
            char* end2 = nullptr;
            unsigned long C = std::strtoul(end + 1, &end2, 10);
            if (end2 && *end2 == '\0') { ln = (unsigned)L; col = (unsigned)C; haveLoc = true; }
        }
    }
    if (haveLoc) {
        std::cerr << "aster: " << file << ":" << ln << ":" << col << ": error: " << msg << "\n";
        if (ln > 0 && ln - 1 < g_srcLines.size()) {
            const std::string& raw = g_srcLines[ln - 1];
            std::string disp = expandTabs(raw);
            std::cerr << "    " << disp << "\n";
            std::string pointer = "    ";
            unsigned target = col > 0 ? col - 1 : 0;
            unsigned v = 0;
            for (char ch : raw) {
                if (v >= target) break;
                if (ch == '\t') { unsigned next = ((v / 8) + 1) * 8; while (v < next) { pointer.push_back(' '); ++v; } }
                else { pointer.push_back(' '); ++v; }
            }
            pointer.push_back('^');
            std::cerr << pointer << "\n";
        }
    } else {
        std::cerr << "aster: error: " << msg << "\n";
    }
}
uint64_t alignUp(uint64_t n,uint64_t a){return (n+a-1u)&~(a-1u);}

enum class TK { End, Ident, Number, String, Fn, Extern, Main, Let, Return, If, Else, While, For, Break, Continue, I32, Ptr, Bool,
    I64, U8, U16, U32,   // v0.23.2-dev (P3.2): wider integer type keywords
    True, False,         // v0.23.25-dev: Bool literals — the first the language has had
    Struct,              // v0.23.5-dev (P3.3): struct declarations
    Include,             // v0.23.13-dev (P3.4): include "file.ast" declaration sharing
    LParen, RParen, LBrace, RBrace, Colon, Semi, Comma, Arrow, Eq, EqEq, Ne,
    Lt, Le, Gt, Ge, Plus, Minus, Star, Slash, LBracket, RBracket, At, And, Or, Not,
    // v0.23.17-dev (round 1): the rest of the C operator set. `Amp` doubles as
    // bitwise AND — it is address-of only where an operand may begin, which is
    // exactly where primary() sees it, so `a & b` and `&a` cannot be confused.
    Percent, Shl, Shr, BitXor, BitOr, Tilde, Question,
    PlusEq, MinusEq, StarEq, SlashEq, PercentEq, ShlEq, ShrEq, AndEq, OrEq, XorEq,
    PlusPlus, MinusMinus,
    Dot, Amp };          // v0.23.5-dev (P3.3): '.' field access, '&' address-of
struct Token { TK k; std::string s; unsigned line, col; };
class Lexer {
    const std::string& s; size_t p=0; unsigned line=1, col=1;
    char peek(size_t n=0) const { return p+n<s.size()?s[p+n]:'\0'; }
    char take() { char c=peek(); if(c){++p;if(c=='\n'){++line;col=1;}else ++col;} return c; }
public:
    explicit Lexer(const std::string& x):s(x){}
    std::vector<Token> run() {
        std::vector<Token> v;
        for (;;) {
            for (;;) { // skip whitespace and comments (// line, /* block */)
                while (std::isspace((unsigned char)peek())) take();
                if (peek()=='/'&&peek(1)=='/') {
                    while(peek()&&peek()!='\n') take();
                    continue;
                }
                if (peek()=='/'&&peek(1)=='*') {
                    unsigned bl=line,bc=col; take(); take(); bool closed=false;
                    while(peek()){ if(peek()=='*'&&peek(1)=='/'){take();take();closed=true;break;} take(); }
                    if(!closed) throw Error("unterminated block comment at "+std::to_string(bl)+":"+std::to_string(bc));
                    continue;
                }
                break;
            }
            unsigned l=line,c=col; char ch=peek();
            if (!ch) { v.push_back({TK::End,"",l,c}); break; }
            if (std::isalpha((unsigned char)ch)||ch=='_') {
                std::string x; while(std::isalnum((unsigned char)peek())||peek()=='_') x+=take();
                TK k=TK::Ident;
                if(x=="fn")k=TK::Fn; else if(x=="extern")k=TK::Extern; else if(x=="main")k=TK::Main; else if(x=="let")k=TK::Let;
                else if(x=="return")k=TK::Return; else if(x=="if")k=TK::If; else if(x=="else")k=TK::Else; else if(x=="while")k=TK::While; else if(x=="for")k=TK::For; else if(x=="break")k=TK::Break; else if(x=="continue")k=TK::Continue; else if(x=="i32")k=TK::I32; else if(x=="ptr")k=TK::Ptr; else if(x=="bool")k=TK::Bool;
                else if(x=="i64")k=TK::I64; else if(x=="u8")k=TK::U8; else if(x=="u16")k=TK::U16; else if(x=="u32")k=TK::U32; else if(x=="struct")k=TK::Struct;
                else if(x=="include")k=TK::Include;   // v0.23.13-dev (P3.4)
                // v0.23.25-dev: true/false are reserved words now. No shipped
                // example or suite used either as an identifier, so the byte
                // baseline holds by construction.
                else if(x=="true")k=TK::True; else if(x=="false")k=TK::False;
                v.push_back({k,x,l,c}); continue;
            }
            if(std::isdigit((unsigned char)ch)) {
                std::string x; while(std::isdigit((unsigned char)peek()))x+=take();
                // v0.23.22-dev: hexadecimal literals. `0x`/`0X` followed by at
                // least one hex digit; the prefix stays in the token text and
                // unsignedLiteral parses base 16 (strtoull accepts the optional
                // prefix under base 16). A bare `0x` with no digits is a lexer
                // error here rather than a confusing parser error downstream.
                if(x=="0"&&(peek()=='x'||peek()=='X')){
                    x+=take();
                    if(!std::isxdigit((unsigned char)peek()))
                        throw Error("hexadecimal literal has no digits at "+std::to_string(l)+":"+std::to_string(c));
                    while(std::isxdigit((unsigned char)peek()))x+=take();
                }
                v.push_back({TK::Number,x,l,c}); continue;
            }
            if(ch=='"') {
                take(); std::string value; bool closed=false;
                while(peek()) {
                    char q=take();
                    if(q=='"'){closed=true;break;}
                    if(q=='\n'||q=='\r')throw Error("newline in string literal at "+std::to_string(l)+":"+std::to_string(c));
                    if(q=='\\') {
                        char e=take(); if(!e)break;
                        switch(e){case 'n':value+='\n';break;case 'r':value+='\r';break;case 't':value+='\t';break;case '0':value+='\0';break;case '\\':value+='\\';break;case '"':value+='"';break;default:throw Error("unsupported string escape at "+std::to_string(line)+":"+std::to_string(col));}
                    } else value+=q;
                }
                if(!closed)throw Error("unterminated string literal at "+std::to_string(l)+":"+std::to_string(c));
                v.push_back({TK::String,value,l,c}); continue;
            }
            if ((unsigned char)ch > 127) throw Error("non-ASCII character at "+std::to_string(l)+":"+std::to_string(c)+" (Aster source must be ASCII)");
            take();
            switch(ch) {
                case '(':v.push_back({TK::LParen,"(",l,c});break; case ')':v.push_back({TK::RParen,")",l,c});break;
                case '{':v.push_back({TK::LBrace,"{",l,c});break; case '}':v.push_back({TK::RBrace,"}",l,c});break;
                case ':':v.push_back({TK::Colon,":",l,c});break; case ';':v.push_back({TK::Semi,";",l,c});break; case ',':v.push_back({TK::Comma,",",l,c});break;
                case '[':v.push_back({TK::LBracket,"[",l,c});break; case ']':v.push_back({TK::RBracket,"]",l,c});break; case '@':v.push_back({TK::At,"@",l,c});break;
                case '=': if(peek()=='='){take();v.push_back({TK::EqEq,"==",l,c});}else v.push_back({TK::Eq,"=",l,c});break;
                case '!': if(peek()=='='){take();v.push_back({TK::Ne,"!=",l,c});}else v.push_back({TK::Not,"!",l,c});break;
                case '.':v.push_back({TK::Dot,".",l,c});break;
                // v0.23.17-dev (round 1): the operator set. Every two-character
                // form is decided by one peek, and the three-character compound
                // shifts (`<<=`, `>>=`) by a second — so `<<=` can never be cut
                // into `<<` + `=`, and `&&` can never be cut into two `&`.
                case '+': {
                    if(peek()=='+'){take();v.push_back({TK::PlusPlus,"++",l,c});}
                    else if(peek()=='='){take();v.push_back({TK::PlusEq,"+=",l,c});}
                    else v.push_back({TK::Plus,"+",l,c});
                    break;
                }
                case '-': {
                    if(peek()=='>'){take();v.push_back({TK::Arrow,"->",l,c});}
                    else if(peek()=='-'){take();v.push_back({TK::MinusMinus,"--",l,c});}
                    else if(peek()=='='){take();v.push_back({TK::MinusEq,"-=",l,c});}
                    else v.push_back({TK::Minus,"-",l,c});
                    break;
                }
                case '*': {
                    if(peek()=='='){take();v.push_back({TK::StarEq,"*=",l,c});}
                    else v.push_back({TK::Star,"*",l,c});
                    break;
                }
                case '/': {
                    if(peek()=='='){take();v.push_back({TK::SlashEq,"/=",l,c});}
                    else v.push_back({TK::Slash,"/",l,c});
                    break;
                }
                case '%': {
                    if(peek()=='='){take();v.push_back({TK::PercentEq,"%=",l,c});}
                    else v.push_back({TK::Percent,"%",l,c});
                    break;
                }
                case '^': {
                    if(peek()=='='){take();v.push_back({TK::XorEq,"^=",l,c});}
                    else v.push_back({TK::BitXor,"^",l,c});
                    break;
                }
                case '~': v.push_back({TK::Tilde,"~",l,c});break;
                case '?': v.push_back({TK::Question,"?",l,c});break;
                case '&': {
                    if(peek()=='&'){take();v.push_back({TK::And,"&&",l,c});}
                    else if(peek()=='='){take();v.push_back({TK::AndEq,"&=",l,c});}
                    else v.push_back({TK::Amp,"&",l,c});
                    break;
                }
                case '|': {
                    if(peek()=='|'){take();v.push_back({TK::Or,"||",l,c});}
                    else if(peek()=='='){take();v.push_back({TK::OrEq,"|=",l,c});}
                    else v.push_back({TK::BitOr,"|",l,c});
                    break;
                }
                case '<': {
                    if(peek()=='='){take();v.push_back({TK::Le,"<=",l,c});}
                    else if(peek()=='<'){
                        take();
                        if(peek()=='='){take();v.push_back({TK::ShlEq,"<<=",l,c});}
                        else v.push_back({TK::Shl,"<<",l,c});
                    }
                    else v.push_back({TK::Lt,"<",l,c});
                    break;
                }
                case '>': {
                    if(peek()=='='){take();v.push_back({TK::Ge,">=",l,c});}
                    else if(peek()=='>'){
                        take();
                        if(peek()=='='){take();v.push_back({TK::ShrEq,">>=",l,c});}
                        else v.push_back({TK::Shr,">>",l,c});
                    }
                    else v.push_back({TK::Gt,">",l,c});
                    break;
                }
                default:throw Error("unexpected character at "+std::to_string(l)+":"+std::to_string(c));
            }
        }
        return v;
    }
};
// ---------------------------------------------------------------------------
// Value types (v0.23.2-dev, P3.2)
//
// One enumeration describes what a slot, a parameter, a return value, a global
// or an array element holds. Before this release the answer was split across a
// handful of booleans (`isPtr`, `isBool`, `paramPtr`, `paramBool`, ...) that
// every consumer had to interpret in the same order; adding a fifth width would
// have meant threading another boolean through each of them.
//
// The type decides three things downstream:
//   * how many bytes a value occupies in memory        (tySize)
//   * whether it lives in a 32-bit W or 64-bit X register (tyIs64)
//   * which condition code a comparison of it uses      (signed vs unsigned)
//
// U8/U16 are 1- and 2-byte *memory* values: loading one zero-extends it into a
// W register, and storing one truncates. Bool is a 4-byte 0/1, unchanged.
//
// v0.23.5-dev (P3.3) turns the enumeration into a (Kind, struct-index) pair.
// A struct type needs to say *which* struct, and a pointer needs to be able to
// say what it points at, so the extra index rides along in every Ty instead of
// travelling beside it in a parallel map that could drift out of step:
//
//   k == Struct            -> a struct value; sid names the struct
//   k == Ptr && sid >= 0   -> a pointer to that struct (`ptr<S>`)
//   otherwise              -> sid is -1 and carries no meaning
//
// The Kind keeps the spelling `Ty::I32`, so every site that asks "is this a
// pointer?" or "how wide is it?" reads exactly as it did before.
struct Ty {
    enum Kind { I32, U32, U8, U16, I64, Ptr, Bool, Struct };
    Kind k = I32;
    int sid = -1;                      // struct-table index; see above
    // v0.23.34-dev: a pointer may carry the *element* it strides over, so
    // `p[i]` can scale by the element's real width instead of a hard-coded 4
    // and `&arr` can hand over an array of any element width (i64/u8/u16/ptr/S).
    // The element rides along as (ekind, esid) rather than as a nested Ty — a
    // Ty is not complete inside its own definition — and `ew` is its width in
    // bytes, or -1 when the pointer is untyped (the legacy `ptr`, a null, an
    // address taken from an int, or a `ptr<S>`), which is what makes a strided
    // pointer and a `ptr<S>` two different shapes rather than one.
    int ew = -1;
    Kind ekind = I32;
    int esid = -1;
    constexpr Ty(Kind kk = I32) : k(kk), sid(-1), ew(-1), ekind(I32), esid(-1) {}
    static Ty ofStruct(int id) { Ty t(Struct); t.sid = id; return t; }
    static Ty ptrTo(int id) { Ty t(Ptr); t.sid = id; return t; }
};
// Comparing a Ty against a Kind is what nearly every call site does. Both
// argument orders are spelled out so no call ever resolves through the
// implicit Kind -> Ty conversion and turns into an ambiguity.
// The reverse order and the Ty-vs-Ty forms exist so no call site has to spell
// a conversion; which of them a given release happens to use varies, so the
// unused ones are marked rather than deleted -- clang's -Wunused-function does
// fire on an inline function that nothing calls (gcc's does not), and this file
// is built with -Werror on both.
[[maybe_unused]] inline bool operator==(const Ty& a, Ty::Kind b) { return a.k == b; }
[[maybe_unused]] inline bool operator==(Ty::Kind a, const Ty& b) { return b.k == a; }
[[maybe_unused]] inline bool operator!=(const Ty& a, Ty::Kind b) { return a.k != b; }
[[maybe_unused]] inline bool operator!=(Ty::Kind a, const Ty& b) { return b.k != a; }
[[maybe_unused]] inline bool operator==(const Ty& a, const Ty& b) { return a.k == b.k && a.sid == b.sid; }
[[maybe_unused]] inline bool operator!=(const Ty& a, const Ty& b) { return !(a == b); }
[[maybe_unused]] inline bool operator<(const Ty& a, const Ty& b) { return a.k != b.k ? a.k < b.k : a.sid < b.sid; }
// v0.23.37-dev: a function type, carried *beside* a ptr variable rather than
// as a distinct Ty. A fn-pointer keeps the storage type Ty::Ptr, so gen(Var)
// addressing and the default byte width are untouched; this parallel record
// holds the signature an indirect call may consult (parameter types and the
// return type), exactly as the element type rides beside a ptr<…>.
struct FuncSig { std::vector<Ty> params; Ty ret=Ty::I32; };
// v0.23.38-dev: one parameter's function type — whether it declares one at
// all, and the signature if it does. The flag is needed because `fn() -> i32`
// is a real signature whose parameter list is empty, and "no signature
// declared" has to stay distinguishable from it.
struct ParamSig { bool isFunc=false; FuncSig sig; };
// ---------------------------------------------------------------------------
// Struct types (v0.23.5-dev, P3.3)
//
// One table per translation unit. The layout is the C layout, which on
// AArch64 is the AAPCS64 one: every field starts at the next offset that is a
// multiple of its own alignment, the struct's alignment is the largest field
// alignment (at least 1), and the size is rounded up to that alignment so an
// array of them would keep every element aligned. A field may itself be a
// struct — the rules are applied recursively, so a nested struct contributes
// its own alignment and occupies its own size.
//
// There are no floating-point types, so the HFA (homogeneous aggregate) rules
// never apply; a composite is classified by size alone.
// v0.23.29-dev: a field may itself be a fixed-length array (`xs: i32[4]`),
// so the field carries the element type in `ty` and the length in `len`
// (0 means a scalar field). An array field's storage is `tySize(ty) * len`
// bytes at `offset`, aligned to `tyAlign(ty)` — the same bytes an array of the
// same element type would own.
// v0.23.31-dev: the field may be multi-dimensional (`xs: i32[2][3]`), and then
// `dims` carries each length outermost first while `len` stays the total
// element count — the number the layout already multiplies by.
// v0.23.38-dev: a field may be a fn-pointer (`onClick: fn(i32) -> i32`), and
// then `funcSig` carries the signature beside the ptr storage type, the same
// way a variable, a parameter and a global have carried one since
// v0.23.37-dev. The layout is untouched — a fn-pointer field is an eight-byte
// ptr — but a call through the field can now be checked and staged by the
// signature, which is the whole point of writing the type down.
struct StructField { std::string name; Ty ty; uint32_t offset = 0; uint32_t len = 0; std::vector<uint32_t> dims;
                     FuncSig funcSig; bool isFunc = false; };
struct StructDef {
    std::string name;
    std::vector<StructField> fields;
    uint32_t size = 0, align = 1;
    const StructField* find(const std::string& n) const {
        for (const auto& f : fields) if (f.name == n) return &f;
        return nullptr;
    }
};
// Filled in by the parser as it reads the declarations, before any type is
// measured: a field's struct type must already be in the table, so a struct
// has to be declared before it is used, exactly as in C.
static std::vector<StructDef> g_structs;
static std::map<std::string, int> g_structIndex;
static const StructDef& structOf(int sid) {
    if (sid < 0 || (size_t)sid >= g_structs.size())
        throw Error("internal compiler error: struct index out of range");
    return g_structs[(size_t)sid];
}
// Width in bytes of one value of this type as it sits in memory.
static uint32_t tySize(Ty t) {
    if (t.k == Ty::Struct) return structOf(t.sid).size;
    return t.k == Ty::U8 ? 1u : t.k == Ty::U16 ? 2u : (t.k == Ty::I64 || t.k == Ty::Ptr) ? 8u : 4u;
}
// Alignment in bytes. Structs carry their own; every scalar is naturally
// aligned. This is the number AAPCS64 rounds a field offset up to.
static uint32_t tyAlign(Ty t) {
    if (t.k == Ty::Struct) return structOf(t.sid).align;
    return t.k == Ty::U8 ? 1u : t.k == Ty::U16 ? 2u : (t.k == Ty::I64 || t.k == Ty::Ptr) ? 8u : 4u;
}
static bool tyIsStruct(Ty t) { return t.k == Ty::Struct; }
// A `ptr<S>`: still a 64-bit address with the ordinary pointer ABI, but field
// accesses through it know which struct they are reading.
static bool tyIsPtrToStruct(Ty t) { return t.k == Ty::Ptr && t.sid >= 0; }
// v0.23.34-dev: a pointer that names the element type it strides over
// (`&arr`, an array parameter's decayed form).  Distinct from `ptr<S>` (which
// sets sid).  An untyped `ptr` has ew < 0 and is not one.  Defined after
// tySize because the width is the element's, measured the same way every
// other width in the file is.
static bool tyIsPtrToElem(Ty t) { return t.k == Ty::Ptr && t.ew >= 0; }
static Ty ptrElemType(Ty t) { Ty e(t.ekind); e.sid = t.esid; return e; }
static Ty tyPtrToElem(Ty e) { Ty t(Ty::Ptr); t.ekind = e.k; t.esid = e.sid; t.ew = (int)tySize(e); return t; }
// v0.23.35-dev: the product of a dimension list. Empty means "one element"
// (a scalar type spelling), so the same helper serves sizeof's byte count and
// len's element count.
static uint64_t dimsProduct(const std::vector<uint32_t>& d) {
    uint64_t p = 1; for (uint32_t x : d) p *= x; return p;
}
// v0.23.35-dev: the byte size of a *type* spelled as a sizeof argument, with
// optional array dimensions: `sizeof(i32[4])` = tySize(i32) * 4. The scalar /
// struct / ptr variants all collapse to tySize through this same path.
static uint64_t sizeofTypeValue(Ty t, const std::vector<uint32_t>& dims) {
    return (uint64_t)tySize(t) * dimsProduct(dims);
}
// The byte stride `p[i]` applies: the element width when known, else the
// legacy one-i32 stride every untyped `ptr` has always used.
[[maybe_unused]] static uint32_t ptrElemWidth(Ty t) { return t.ew >= 0 ? (uint32_t)t.ew : 4u; }
// True for the types that occupy an 8-byte slot and use X registers (and, for
// pointers, the existing 64-bit load/store forms). A struct is not one of
// them: it is copied by address, never materialized in a single register.
static bool tyIs64(Ty t) { return t.k == Ty::I64 || t.k == Ty::Ptr; }
// I32/U32/U8/U16/I64: arithmetic and comparison operands that are not bool,
// not an address, and not a composite.
static bool tyIsInteger(Ty t) { return t.k == Ty::I32 || t.k == Ty::U32 || t.k == Ty::U8 || t.k == Ty::U16 || t.k == Ty::I64; }
// U32/U8/U16 compare with the unsigned condition codes (LO/LS/HI/HS) and divide
// with UDIV, unlike i32/i64.
static bool tyIsUnsigned(Ty t) { return t.k == Ty::U32 || t.k == Ty::U8 || t.k == Ty::U16; }
// v0.23.28-dev: log2(tySize(t)) when the size is a power of two — the shift
// `ADD Xd, Xn, Wm, UXTW #sh` folds into one instruction — or -1 when it is
// not. Only a struct reaches the second case: a struct's size is a multiple of
// its alignment, which need not be a power of two (`{ i32, i32, i32 }` is 12).
// This replaces the old tyShift, which answered 2 for every type it did not
// name and so could not scale a struct element at all; for every scalar the
// two agree, which is why no pre-existing element address moves.
static int elemShiftOf(Ty t){
    const uint32_t sz=tySize(t);
    if(sz==0||(sz&(sz-1))!=0u)return -1;
    int s=0;while((1u<<s)!=sz)++s;
    return s;
}
static const char* tyName(Ty t) {
    switch (t.k) {
        case Ty::I32: return "i32"; case Ty::U32: return "u32"; case Ty::U8: return "u8";
        case Ty::U16: return "u16"; case Ty::I64: return "i64"; case Ty::Ptr: return "ptr";
        case Ty::Bool: return "bool";
        case Ty::Struct: break;
    }
    return structOf(t.sid).name.c_str();
}
// A type name for diagnostics: `ptr` for a plain address, `ptr<S>` for one
// that knows what it points at. tyName cannot tell them apart, because the
// pointer path is deliberately identical for both.
static std::string tyNameFull(Ty t) {
    if (tyIsPtrToStruct(t)) return std::string("ptr<") + structOf(t.sid).name + ">";
    return tyName(t);
}
// Give every field its offset and the struct its size and alignment.
//
// A field starts at the next offset that is a multiple of its own alignment;
// the struct's alignment is the largest of its fields'; the size is the
// final offset rounded up to that alignment. This is the AAPCS64 (and C)
// layout, and because a nested struct contributes its own alignment and size,
// one pass over the fields in declaration order computes it.
//
// The table is consulted through tySize/tyAlign while the struct is being
// built, so the struct must already be in it — which it is: the caller appends
// the (still empty) definition first, then lays it out, so a struct that
// contains itself is rejected rather than recursing forever.
static void layoutStruct(StructDef& s) {
    uint32_t off = 0, align = 1;
    for (auto& f : s.fields) {
        // v0.23.29-dev: an array field owns `sizeof(elem) * len` bytes, aligned
        // to the element's alignment — exactly the storage a same-element array
        // would occupy. A scalar field owns `sizeof(ty)` as before.
        const uint32_t a = tyAlign(f.ty);
        const uint32_t elemSize = tySize(f.ty);
        const uint32_t fieldSize = f.len ? elemSize * f.len : elemSize;
        if (a > align) align = a;
        off = (off + a - 1u) & ~(a - 1u);
        f.offset = off;
        off += fieldSize;
    }
    s.align = align;
    s.size = (off + align - 1u) & ~(align - 1u);
}
// The single spelling of "this is not a type name", shared by the parameter,
// return, local and global declaration sites so they cannot drift apart.
static const char* kTypeExpected="expected i32, i64, u8, u16, u32, ptr, ptr<S>, bool, or a struct name";
struct Expr {
    // Field   : a.field   — a is a struct lvalue or a ptr<S>; name is the field
    // AddrOf  : &a        — the address of an lvalue, typed ptr<S> for a struct
    // StructLit: S { .. }  — an aggregate literal, one value per field in order
    // Embed   : @embed("f") — the address of a file's bytes, which the parser
    //           has already read into rodata. It is a sibling of String, not a
    //           kind of it: a string literal's bytes end in a NUL that the
    //           literal owns, and embedded bytes end exactly where the file does.
    enum Kind { Num, Var, String, Call, Index, Deref, Add, Sub, Mul, Div, Neg, Eq, Ne, Lt, Le, Gt, Ge, And, Or, Not,
                Field, AddrOf, StructLit, Embed,
                // v0.23.17-dev (round 1): remainder, shifts, bitwise ops and the
                // conditional. Mod is emitted as SDIV+MSUB; Shl/Shr pick LSR or
                // ASR from the left operand's signedness; BitNot is ORN/xzr.
                Mod, Shl, Shr, BitAnd, BitOr, BitXor, BitNot, Cond,
                // v0.23.35-dev: sizeof / len operators. Both fold to an i32
                // constant at compile time — the type-form at parse time, the
                // expression-form during sema — so every downstream site treats
                // them exactly like a Num.
                SizeOf, Len,
                // v0.23.38-dev: `h.onClick(x)` — a call through a fn-pointer
                // *field*. It is deliberately not `Call`: every call site keys
                // on `e.name`, and a field name that happens to match a
                // function's (`fn onClick` beside `Handlers.onClick`) would
                // then be rerouted to the function. `a` is the Field node, so
                // `a->name` is the field and `a->a` the struct; `name` stays
                // empty, which keeps `argTypes`/`functionArities` — both keyed
                // by name — from ever matching.
                FieldCall } k;
    uint64_t n=0; std::string name; std::unique_ptr<Expr> a,b; std::vector<std::unique_ptr<Expr>> args;
    // v0.23.35-dev: sizeof / len. `ty` + `idims` carry the *type-form* argument
    // (e.g. sizeof(i32[4])); `a` carries the *expression-form* argument
    // (e.g. sizeof(x)). The folded i32 result lives in `n` (set at parse time
    // for the type-form, during sema for the expression-form).
    Ty ty=Ty::I32; std::vector<uint32_t> idims;
    // v0.23.25-dev: this Num node is a Bool literal (true/false), not the
    // integer 0 or 1. Every type rule reads the flag: the literal types as
    // bool, folds as no integer constant at all, and initializes a bool slot
    // — while `let x: i32 = true;` is the type error it always should
    // have been.
    bool boolLit=false;
    unsigned line=0, col=0;   // P4.1: source location of the token that introduces this node
    explicit Expr(Kind kind):k(kind){} Expr(Kind kind,uint64_t value):k(kind),n(value){}
};
using E=std::unique_ptr<Expr>;
// Does a folded constant initializer fit in `t`? Used where the value is known
// at compile time, so a silent truncation would be a bug in the program rather
// than a wrapping operation.
//
// `folded` is the signed result of constantInteger, which sign-extends a
// literal: `4000000000` folds to -294967296 although a u32 slot holds it
// exactly. A bare literal is therefore accepted for every 32-bit-and-wider
// type and only checked for the narrow ones. i32 keeps its historical
// behaviour (the low 32 bits are stored) so no existing program changes.
static bool initializerFits(Ty t,const Expr& e,int64_t folded){
    // v0.23.28-dev: `true`/`false` fill a bool slot and only a bool slot. A
    // bool array element is one, so this is where an out-of-range fill is
    // reported; a bool *scalar* takes its own branch, as it always did.
    if(e.k==Expr::Num&&e.boolLit)return t==Ty::Bool;
    if(e.k==Expr::Num){
        // A bare literal's low bits are what gets stored. It fits a narrow slot
        // only when its value is inside that slot's range; the 32-bit-and-wider
        // slots accept any literal (their low bits are stored, as i32 always did).
        if(t==Ty::U8) return (uint64_t)e.n<=255u;
        if(t==Ty::U16)return (uint64_t)e.n<=65535u;
        if(t==Ty::Bool)return (uint64_t)e.n<=1u;
        return true;
    }
    switch(t.k){
        case Ty::U8:  return folded>=0&&folded<=255;
        case Ty::U16: return folded>=0&&folded<=65535;
        case Ty::U32: return folded>=0;
        case Ty::Bool: return folded==0||folded==1;
        default:      return true;   // i64 holds everything; i32 truncates as before
    }
}
struct Stmt {
    enum Kind { Let, Assign, FieldAssign, IndexAssign, DerefAssign, Return, If, While, For, Break, Continue, Expr } k; std::string name; unsigned line=0, col=0;   // P4.1: source location of this statement's leading token
    E expr; E idx;
    Ty ty=Ty::I32;          // declared value type (v0.23.2-dev); isPtr/isBool mirror it
    bool isPtr=false; bool isBool=false;
    // v0.23.37-dev: when this let declares a fn-pointer, the signature rides
    // here beside the storage type (Ty::Ptr), for Sema/codegen to read.
    FuncSig funcSig; bool isFunc=false;
    bool isArray=false; uint32_t count=1;   // local T[count] declaration (count elements of type ty)
    // v0.23.31-dev: a multi-dimensional local (`T[N][M]`) records every length,
    // outermost first, in `dims`; `count` stays the *total* element count so the
    // frame reservation, the broadcast initializer and every other site that
    // only ever wanted "how many elements" keeps working unchanged. A
    // one-dimensional array has `dims.size() == 1` and `dims[0] == count`.
    std::vector<uint32_t> dims;
    // v0.23.31-dev: how many subscripts an IndexAssign wrote on its target.
    // One subscript arrives as itself; two or more arrive as an Index chain.
    // Sema needs the difference to tell "stores an element" from "stores a
    // row" on a multi-dimensional array, and only the parser knows which
    // shape it built — a chain and a bare subscript are not told apart by
    // looking at the expression alone.
    unsigned subs=1;
    std::vector<Stmt> thenBody, elseBody;
    // for (init; cond; step) body: forInit/forStep hold 0 or 1 statement each
    // (a let declaration is only legal in the initializer); thenBody is the loop body.
    std::vector<Stmt> forInit, forStep;
    Stmt(Kind kind):k(kind){}
    Stmt(Stmt&&)=default; Stmt& operator=(Stmt&&)=default;
    Stmt(const Stmt&)=delete; Stmt& operator=(const Stmt&)=delete;
};
struct Global { std::string name; bool external=false; int32_t init=0; uint64_t wideInit=0; Ty ty=Ty::I32; bool isArray=false; uint32_t count=1; uint64_t align=4; bool runtimeInit=false; E initExpr; bool isString=false; bool isBool=false; FuncSig funcSig; bool isFunc=false; std::vector<uint8_t> rawData;
    // v0.23.31-dev: the per-dimension lengths of a multi-dimensional global
    // (`T[N][M]`), outermost first. `count` stays the total element count, so
    // `.data`/`.bss` sizing and the constant image repeat are unchanged; only
    // the bounds check and the outer stride read the individual lengths.
    std::vector<uint32_t> dims;
    // v0.23.13-dev (P3.4): the placeholder @embed puts in `globals` for the bytes
    // it read. An included file contributes declarations only, and its embedded
    // bytes are not among them, so this is how the merge tells them apart from a
    // global the included file actually declared.
    bool fromEmbed=false;
    // v0.23.13-dev (P3.4): arrived through `include`, so a definition in the
    // including file supersedes it rather than colliding with it.
    bool fromInclude=false; };
struct Function { std::string name; std::vector<std::string> params; std::vector<bool> paramPtr; std::vector<bool> paramBool; std::vector<Ty> paramTypes; std::vector<std::vector<uint32_t>> paramDims; std::vector<FuncSig> paramFuncSig; std::vector<bool> paramIsFunc; Ty retType=Ty::I32; std::vector<Stmt> body; bool external=false; bool returnPtr=false; bool returnBool=false;
    // v0.23.38-dev: a function may return a fn-pointer, and then the signature
    // travels beside the ptr return type exactly as it does beside a ptr
    // parameter. `return inc;` inside `fn get() -> fn(i32) -> i32` can be
    // checked against it, and a `let f: fn(i32) -> i32 = get();` knows what
    // it is holding. There is still no first-class function value: what comes
    // back is an address, and the signature says how to call through it.
    FuncSig returnFuncSig; bool returnIsFunc=false;
    // Position of the declaration (`fn`, or the `extern` in front of it) — the line
    // a debugger should show for the function's prologue. Filled in v0.23.12-dev.
    unsigned line=0,col=0;
    // v0.23.13-dev (P3.4): this entry arrived through `include`, so it is a
    // declaration standing in for a definition that lives in another file. A
    // definition in the including file supersedes it instead of colliding with
    // it — which is what makes "include the header, then define the functions"
    // work the way it does in C.
    bool fromInclude=false; };
// Declared here so the parser can fold a struct literal's field values;
// defined below, next to the other shared helpers.
static bool constantInteger(const Expr& e,int64_t& out);
// The struct a `.field` reads through: a struct value, or the struct a ptr<S>
// points at. An untyped ptr has no layout to index into. One definition,
// shared by the semantic pass and codegen, so the two cannot disagree about
// which fields exist.
static int structBaseId(Ty base,const std::string& field){
    if(tyIsStruct(base))return base.sid;
    if(tyIsPtrToStruct(base))return base.sid;
    throw Error("cannot read field '"+field+"' of "+tyNameFull(base)+": expected a struct or a ptr<S>");
}
// The field itself, or null when the name is not one of the struct's.
static const StructField* structFieldOf(Ty base,const std::string& field){
    const StructField* f=structOf(structBaseId(base,field)).find(field);
    return f;
}
// v0.23.29-dev: a struct literal (`S { … }`) supplies one value per field, so
// it cannot set an array field (which needs N values) or any array field
// nested inside a struct field. Such a struct is populated at runtime instead.
static bool structHasArrayField(uint32_t sid){
    const StructDef& s=structOf(sid);
    for(const auto& f:s.fields){
        if(f.len>0)return true;
        if(tyIsStruct(f.ty)&&structHasArrayField(f.ty.sid))return true;
    }
    return false;
}
// An lvalue — something whose address can be taken: a variable, an array
// element, a field of one, or a dereferenced pointer. A call result or an
// arithmetic result is not. v0.23.28-dev adds the element, which is what makes
// `&a[i]` a `ptr<S>` for a struct array — and which lets a composite argument
// be passed by address rather than copied, exactly as `&s` already did.
static bool isLValue(const Expr& e){
    return e.k==Expr::Var||e.k==Expr::Index||e.k==Expr::Field||e.k==Expr::Deref;
}
// v0.23.29-dev: if `field` is a Field node whose field is a fixed-length array
// field (len > 0), return that field; otherwise nullptr. This is how every
// Index site tells a struct array field element access `s.xs[i]` apart from a
// plain scalar/struct field access and from a named-array Index, whose base is
// the index expression rather than a Field node, so it never lands here as a
// Field. `base` is the type of `field`'s OWN base (field.a) — the struct the
// array field is read from — computed by the caller as exprType or typeOf,
// since this is a free function both Sema and Codegen can call. The first line
// short-circuits on `field.k != Field`, so an unused `base` is never read.
static const StructField* arrayFieldOf(Ty base,const Expr& field){
    if(field.k!=Expr::Field)return nullptr;
    const StructField* f=structFieldOf(base,field.name);
    if(!f||f->len==0)return nullptr;
    return f;
}
// Where a relative path written inside a source file resolves: the file's own
// directory by default, or the directory one of these flags names. Build-wide
// rather than threaded through every signature between main() and the parser,
// so that the top-level source and every file it includes resolve by the same
// rule — the same reasoning that made the source cache a global.
struct SrcPathOpts { std::string embedDir, includeDir; };
static SrcPathOpts g_srcPathOpts;
// ---------------------------------------------------------------------------
// `include` — v0.23.13-dev (P3.4)
//
// One translation unit's view of which files it has already pulled in. It is
// shared by the parser and every sub-parser it spawns, which is the whole point:
// a file that includes itself, directly or through a chain, is only detectable
// if the *stack* outlives the sub-parser that is part-way through it. Including
// the same file twice is not an error — it is a no-op, the same rule @embed
// uses for "the same file embedded twice is embedded once".
// ---------------------------------------------------------------------------
struct IncludeState {
    std::set<std::string> done;        // resolved paths already pulled in
    std::vector<std::string> stack;    // the chain currently being parsed, for cycle messages
};
class Parser {
    std::vector<Token> t; size_t p=0;
    bool requireMain=true;
    const Token& cur()const{return t[p];}
    // Owned by the outermost parser and handed down to every file it includes.
    IncludeState* includes=nullptr;
    IncludeState ownIncludes;
    bool eat(TK k){if(cur().k==k){++p;return true;}return false;}
    Token need(TK k,const char* msg){if(cur().k!=k)throw Error(std::string(msg)+" at "+std::to_string(cur().line)+":"+std::to_string(cur().col));return t[p++];}
    unsigned long long unsignedLiteral(const Token& tok,const char* what) {
        try {
            size_t used=0;
            // v0.23.22-dev: hexadecimal literals carry their `0x`/`0X` prefix
            // in the token text; strtoull consumes the optional prefix under
            // base 16. Every caller (integer literals, array lengths) inherits
            // hex for free, and the range check at the call site still sees a
            // plain unsigned long long.
            const bool hex=tok.s.size()>1&&tok.s[0]=='0'&&(tok.s[1]=='x'||tok.s[1]=='X');
            const unsigned long long value=std::stoull(tok.s,&used,hex?16:10);
            if(used!=tok.s.size())throw Error(std::string("invalid ")+what+" at "+std::to_string(tok.line)+":"+std::to_string(tok.col));
            return value;
        } catch(const std::out_of_range&) {
            throw Error(std::string(what)+" is too large at "+std::to_string(tok.line)+":"+std::to_string(tok.col));
        } catch(const std::invalid_argument&) {
            throw Error(std::string("invalid ")+what+" at "+std::to_string(tok.line)+":"+std::to_string(tok.col));
        }
    }
    std::string functionName(){
        if(cur().k==TK::Ident||cur().k==TK::Main)return t[p++].s;
        throw Error("expected function name at "+std::to_string(cur().line)+":"+std::to_string(cur().col));
    }
    // One type name, consumed when it matches and left alone when it does not,
    // so each call site can name the construct it was parsing. v0.23.2-dev
    // adds i64/u8/u16/u32 to the i32/ptr/bool set; every site that used to
    // accept exactly three types now accepts seven through this helper.
    bool parseType(Ty& out){
        switch(cur().k){
            case TK::I32: out=Ty::I32;  ++p; return true;
            case TK::I64: out=Ty::I64;  ++p; return true;
            case TK::U8:  out=Ty::U8;   ++p; return true;
            case TK::U16: out=Ty::U16;  ++p; return true;
            case TK::U32: out=Ty::U32;  ++p; return true;
            case TK::Ptr: return pointerType(out);
            case TK::Bool:out=Ty::Bool; ++p; return true;
            // A struct type is spelled with the name it was declared with. An
            // identifier that is not a known struct is left alone: the caller
            // reports "expected a type" naming every spelling it accepts.
            case TK::Ident: {
                auto it=g_structIndex.find(cur().s);
                if(it==g_structIndex.end())return false;
                out=Ty::ofStruct(it->second);++p;return true;
            }
            // v0.23.37-dev: a function type spelling `fn (P1, …, Pn) -> R`.
            // The storage type stays Ty::Ptr (a function pointer is an address);
            // the signature is parked in pendingFuncSig for the enclosing
            // declaration to capture, exactly as the element type rides beside
            // a ptr<…>. `fn` is already the function-definition keyword token.
            case TK::Fn: {
                ++p; need(TK::LParen,"expected '(' after fn");
                FuncSig sig;
                if(cur().k!=TK::RParen){
                    do {
                        Ty pt=needType("<function parameter type>");
                        sig.params.push_back(pt);
                    } while(eat(TK::Comma));
                }
                need(TK::RParen,"expected ')' after function parameter types");
                need(TK::Arrow,"expected '->' in a function type");
                sig.ret=needType("<function return type>");
                out=Ty::Ptr; pendingFuncType=true; pendingFuncSig=std::move(sig);
                return true;
            }
            default: return false;
        }
    }
    // `ptr` (untyped, the legacy one-i32 stride), `ptr<T>` (a pointer that
    // knows it strides over elements of type T — `ptr<i64>` indexes at 8 bytes,
    // `ptr<u8>` at 1), or `ptr<S>` for a pointer that knows what struct it
    // points at. All three share one 64-bit ABI; the annotation is what gives
    // `p[i]` its scale and `.field` its offsets.
    bool pointerType(Ty& out){
        need(TK::Ptr,"expected 'ptr'");
        if(cur().k!=TK::Lt){out=Ty::Ptr;return true;}
        ++p;
        // v0.23.34-dev: `ptr<T>` for any non-struct T is a strided element
        // pointer, so `let p: ptr<i64> = &w;` keeps the 8-byte stride `&w`
        // handed over instead of collapsing it back to four. `ptr<S>` stays
        // the field-aware pointer-to-struct it has always been, because
        // `p.f` — not `p[i]` — is what a struct pointer is for. parseType
        // consumes the name in both cases, so which one this is comes from
        // what it returned, never from asking for the identifier twice.
        Ty elem;
        if(parseType(elem)){
            need(TK::Gt,"expected '>' after the type in a ptr<...> type");
            out=(elem.k==Ty::Struct)?Ty::ptrTo(elem.sid):tyPtrToElem(elem);
            return true;
        }
        auto id=need(TK::Ident,"expected a struct name after 'ptr<'");
        need(TK::Gt,"expected '>' after the struct name in a ptr<...> type");
        auto it=g_structIndex.find(id.s);
        if(it==g_structIndex.end())
            throw Error("unknown struct type in ptr<"+id.s+"> at "+std::to_string(id.line)+":"+std::to_string(id.col));
        out=Ty::ptrTo(it->second);return true;
    }
    Ty needType(const char* what){
        // v0.23.37-dev: a fresh type parse starts with no pending function
        // signature. parseType sets pendingFuncType only when it consumes a
        // fn(…)->… spelling; everything else leaves it false, so a signature
        // cannot survive into an unrelated declaration.
        pendingFuncType=false;pendingFuncSig=FuncSig();
        Ty t=Ty::I32;
        if(!parseType(t))throw Error(std::string(what)+" at "+std::to_string(cur().line)+":"+std::to_string(cur().col));
        return t;
    }
    // v0.23.34-dev: a parameter type, which may take the array form `T[N]`
    // (or `T[N][M]`). An array parameter is taken *by address*: it decays to a
    // pointer to its first element, typed to stride at the element's real
    // width, so `fn sum(a: i32[4])` accepts the array itself, `&a`, or any
    // i32 pointer, and `a[i]` inside the body reads at the element's width —
    // exactly the value `&arr` hands over at the call site. The lengths are
    // validated like any array declaration but not remembered: a pointer
    // carries no extent, which is also why `a[i]` through the parameter is not
    // bounds-checked (there is no length to check against).
    Ty arrayParamType(std::vector<uint32_t>* outDims=nullptr){
        Ty t=needType(kTypeExpected);
        if(cur().k!=TK::LBracket)return t;
        std::vector<uint32_t> dims=arrayDimList("array parameter length",1000,"parameter");
        dimsTotal(dims,1000,"array parameter length","parameter",cur().line,cur().col);
        if(outDims)*outDims=dims;
        return tyPtrToElem(t);
    }
    uint32_t stringCounter=0, embedCounter=0;
    // v0.23.37-dev: needType parses a type; if it was a fn(…)->… spelling, the
    // signature is parked here for the enclosing declaration to capture (the
    // flag is cleared at the next needType, so it never leaks past a single
    // type). pendingFuncType is reset at the top of needType itself.
    bool pendingFuncType=false; FuncSig pendingFuncSig;
    // ---------------------------------------------------------------- @embed
    //
    // @embed("path") is the address of a file's bytes and @embed_len("path") is
    // how many there are. Both are resolved while parsing, because the bytes
    // have to be in the object by the time code generation asks for the symbol.
    //
    // A path is relative to the directory the source file is in — the same rule
    // C uses for #include — so a program compiles the same wherever it is built
    // from. --embed-dir overrides it for a build that keeps its sources and its
    // assets apart.
    //
    // The same file embedded twice is one copy. Embedding is not a copy of the
    // file into every expression that names it; it is one object placed once.
    // --embed-dir / --include-dir when they were given, otherwise the directory
    // this file itself lives in. Keeping the flag and the file's own directory
    // apart is what lets an *included* file resolve its own paths against its
    // own directory instead of its includer's: before v0.23.13-dev there was
    // only one file, so the two were the same string and `embedDir` was set to
    // whichever one applied.
    std::string selfDir;
    std::map<std::string,std::string> embedSymbols;             // resolved path -> global name
    std::map<std::string,std::vector<uint8_t>> embedBlobs;      // the bytes themselves; a map, so
                                                                // a reference to one stays valid
    std::string resolveEmbedPath(const std::string& path) const {
        if (path.empty()) return path;
        if (path[0] == '/') return path;
        if (!g_srcPathOpts.embedDir.empty()) return g_srcPathOpts.embedDir + "/" + path;
        if (!selfDir.empty()) return selfDir + "/" + path;
        return path;
    }
    // `include "path"` resolves by the same rule with its own override, and
    // against the *including* file's directory by default — C's #include rule,
    // which is what lets a file find its neighbours from any working directory.
    std::string resolveIncludePath(const std::string& path) const {
        if (path.empty()) return path;
        if (path[0] == '/') return path;
        if (!g_srcPathOpts.includeDir.empty()) return g_srcPathOpts.includeDir + "/" + path;
        if (!selfDir.empty()) return selfDir + "/" + path;
        return path;
    }
    // The bytes of `path`, read once and remembered. Every failure here is a
    // diagnostic rather than silence, because the alternative is a pointer to
    // something the program did not mean to point at.
    const std::vector<uint8_t>& embedFile(const std::string& path, unsigned line, unsigned col) {
        const std::string full = resolveEmbedPath(path);
        auto seen = embedBlobs.find(full);
        if (seen != embedBlobs.end()) return seen->second;
        struct stat st{};
        if (::stat(full.c_str(), &st) != 0) {
            throw Error("cannot open embedded file \"" + path + "\" (looked for \"" + full + "\") at "
                        + std::to_string(line) + ":" + std::to_string(col));
        }
        if (S_ISDIR(st.st_mode))
            throw Error("embedded file is a directory: \"" + full + "\" at "
                        + std::to_string(line) + ":" + std::to_string(col));
        if (st.st_size == 0)
            throw Error("embedded file is empty: \"" + full + "\" at "
                        + std::to_string(line) + ":" + std::to_string(col)
                        + " — a zero-byte resource is almost always the wrong path");
        // 16 MiB. Past this the file is not an asset, it is a mistake: rodata is
        // one segment and a build that quietly absorbs a hundreds-of-megabytes
        // blob is a build whose author meant to pass a different path.
        if (st.st_size > (1 << 24))
            throw Error("embedded file is too large (" + std::to_string((long long)st.st_size)
                        + " bytes, limit 16777216): \"" + full + "\"");
        std::ifstream f(full, std::ios::binary);
        if (!f) throw Error("cannot open embedded file \"" + full + "\" at "
                            + std::to_string(line) + ":" + std::to_string(col));
        std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
        if (bytes.size() != (size_t)st.st_size)
            throw Error("short read of embedded file \"" + full + "\"");
        // A map, not a vector: inserting a second blob must not move the first
        // one out from under a reference already handed to the caller.
        const std::vector<uint8_t>& data = embedBlobs.emplace(full, std::move(bytes)).first->second;
        const std::string symName = "__aster_embed_" + std::to_string(embedCounter++);
        Global g; g.name = symName;
        g.isString = true;                 // rodata, laid out as the bytes it holds
        g.rawData = data;
        g.align = 1;
        g.fromEmbed = true;                // v0.23.13-dev: not a declared global
        globals.push_back(std::move(g));
        embedSymbols[full] = symName;
        return data;
    }
    E primary() {
        // v0.23.35-dev: sizeof / len operators. Try the type spelling first
        // (sizeof(i32[4]), len(P[2])); failing that, parse an expression
        // (sizeof(x), len(a)). The type-form folds here with no context; the
        // expression-form folds later in sema (it needs the binding's dims).
        if(cur().k==TK::Ident&&(cur().s=="sizeof"||cur().s=="len")){
            const std::string op=cur().s; const unsigned ln=cur().line, cl=cur().col; ++p;
            need(TK::LParen,("expected '(' after "+op).c_str());
            Ty t=Ty::I32; std::vector<uint32_t> dims;
            if(parseType(t)){
                while(cur().k==TK::LBracket){
                    ++p; const auto lt=need(TK::Number,"expected array length after '['");
                    const uint64_t d=unsignedLiteral(lt,"array length");
                    if(d==0||d>1000)throw Error("array length out of range at "+std::to_string(lt.line)+":"+std::to_string(lt.col));
                    dims.push_back((uint32_t)d);
                    need(TK::RBracket,"expected ']' after array length");
                }
                need(TK::RParen,("expected ')' after "+op+" type").c_str());
                E x(new Expr(op=="sizeof"?Expr::SizeOf:Expr::Len));
                x->ty=t; x->idims=dims; x->line=ln; x->col=cl;
                // Type-form folds immediately: no binding context is required.
                if(op=="len"){
                    if(dims.empty())throw Error(loc(ln,cl,"len() requires an array type, e.g. len(i32[4])"));
                    x->n=dimsProduct(dims);
                } else x->n=sizeofTypeValue(t,dims);
                return x;
            }
            E inner=expr();
            need(TK::RParen,("expected ')' after "+op+" expression").c_str());
            E x(new Expr(op=="sizeof"?Expr::SizeOf:Expr::Len));
            x->a=std::move(inner); x->line=ln; x->col=cl;
            return x;
        }
        // @embed("path") / @embed_len("path"): a file's bytes, resolved now.
        if (cur().k == TK::At) {
            const Token at = t[p++];
            auto kw = need(TK::Ident, "expected 'embed' or 'embed_len' after '@'");
            if (kw.s != "embed" && kw.s != "embed_len")
                throw Error("unknown attribute '@" + kw.s + "' at " + std::to_string(at.line) + ":"
                            + std::to_string(at.col) + " (expected '@embed' or '@embed_len')");
            const std::string afterAt = "expected '(' after '@" + kw.s + "'";
            const std::string wantPath = "expected a file path after '@" + kw.s + "('";
            need(TK::LParen, afterAt.c_str());
            auto pathTok = need(TK::String, wantPath.c_str());
            need(TK::RParen, "expected ')' after the file path");
            const std::vector<uint8_t>& data = embedFile(pathTok.s, at.line, at.col);
            if (kw.s == "embed_len") {
                // Folded here, so it is a literal everywhere downstream: a
                // global initializer, an array bound, a return value.
                if (data.size() > 0x7fffffffULL) throw Error("embedded file is too large to measure: " + pathTok.s);
                return E(new Expr(Expr::Num, (uint64_t)data.size()));
            }
            E x(new Expr(Expr::Embed));
            x->name = embedSymbols[resolveEmbedPath(pathTok.s)];
            x->line = pathTok.line; x->col = pathTok.col;
            return x;
        }
        if(cur().k==TK::String){auto tok=t[p++];Global g;g.name="__aster_string_"+std::to_string(stringCounter++);g.isString=true;g.rawData.assign(tok.s.begin(),tok.s.end());g.rawData.push_back(0);g.align=1;globals.push_back(std::move(g));E x(new Expr(Expr::String));x->name=globals.back().name;x->line=tok.line;x->col=tok.col;return x;}
        if(eat(TK::LParen)){E x=expr();need(TK::RParen,"expected ')' ");return x;}
        // Literals are accepted up to the signed i64 maximum (9.2e18). Anything
        // wider would not fit the widest supported type (i64) anyway. The u32/u8/u16
        // widths are checked later, at the declaration site, against the declared type.
        if(cur().k==TK::Number){auto tok=t[p++];unsigned long long n=unsignedLiteral(tok,"integer literal");if(n>0x7fffffffffffffffULL)throw Error("integer literal exceeds i64 range at "+std::to_string(tok.line)+":"+std::to_string(tok.col));E nn(new Expr(Expr::Num,(uint64_t)n)); nn->line=tok.line; nn->col=tok.col; return nn;}
        // v0.23.25-dev: true/false — Bool literals. They ride the Num node
        // (there is no other constant kind) but carry boolLit, so no type
        // rule can mistake them for the integers 0 and 1.
        if(cur().k==TK::True||cur().k==TK::False){
            auto tok=t[p++];
            E z(new Expr(Expr::Num,tok.k==TK::True?1u:0u));
            z->boolLit=true;z->line=tok.line;z->col=tok.col;return z;
        }
        if(cur().k==TK::Ident||cur().k==TK::Main){auto tok=t[p++];
            if(eat(TK::LParen)){E x(new Expr(Expr::Call));x->name=tok.s;x->line=tok.line;x->col=tok.col;
                if(cur().k!=TK::RParen){do{x->args.push_back(expr());}while(eat(TK::Comma));}
                need(TK::RParen,"expected ')' after function arguments");
                if(x->args.size()>32)throw Error(loc(x->line,x->col,"function calls support at most 32 arguments"));
                return x;}
            if(eat(TK::LBracket)){E idx=expr();need(TK::RBracket,"expected ']' after array index");E x(new Expr(Expr::Index));x->name=tok.s;x->line=tok.line;x->col=tok.col;x->a=std::move(idx);return x;}
            // S { v1, v2 } : an aggregate literal, one value per field, in
            // declaration order. The name must be a declared struct, which is
            // what tells this apart from an identifier followed by a block.
            if(cur().k==TK::LBrace&&g_structIndex.count(tok.s)){
                ++p;E z(new Expr(Expr::StructLit));z->name=tok.s;z->line=tok.line;z->col=tok.col;
                if(cur().k!=TK::RBrace){do{z->args.push_back(expr());}while(eat(TK::Comma));}
                need(TK::RBrace,"expected '}' after struct literal");
                return z;}
            E x(new Expr(Expr::Var));x->name=tok.s;x->line=tok.line;x->col=tok.col;return x;
        }
        throw Error("expected expression at "+std::to_string(cur().line)+":"+std::to_string(cur().col));
    }
    // a.b , a.b.c , s.xs[i] , s.xs[i].f : field access and array-field
    // subscripting, interleaved left to right. v0.23.27-dev: this used to claim
    // that `*p.f` reads as `(*p).f` "as in C". It did read that way, but C does
    // the opposite — `*p.f` is `*(p.f)` there, because a unary operator's
    // operand reaches the postfix level. The prefix operators moved to unary()
    // above postfix(), which is what makes `-s.v` mean `-(s.v)` and `*p.f`
    // mean `*(p.f)`. v0.23.29-dev folds the once-separate `[]` pass into this
    // same loop so a `.` may follow a subscript: `s.xs[i].f` is a field of a
    // struct array element, which a struct-with-array-fields program needs.
    E postfix(){
        E x=primary();
        // v0.23.38-dev: `(` joins `.` and `[` — but only after a `.field`,
        // because only a field has a signature to call through (see the
        // FieldCall note at the Kind). A name followed by `(` is already a
        // Call the moment primary() returns it, and anything else keeps the
        // `(` for the enclosing level to report, so no existing diagnostic
        // changes.
        while(cur().k==TK::Dot||cur().k==TK::LBracket||(cur().k==TK::LParen&&x->k==Expr::Field)){
            if(cur().k==TK::Dot){
                ++p;auto f=need(TK::Ident,"expected field name after '.'");
                E z(new Expr(Expr::Field));z->a=std::move(x);z->name=f.s;z->line=f.line;z->col=f.col;x=std::move(z);
            } else if(cur().k==TK::LParen){
                // `h.onClick(x)`: the call through a fn-pointer field. `a` is
                // the Field node, so the callee is found through the field's
                // own signature rather than through any name in scope; `name`
                // stays empty so nothing keys on it.
                const Token lp=cur();++p;
                E z(new Expr(Expr::FieldCall));
                z->a=std::move(x);z->name="";z->line=lp.line;z->col=lp.col;
                if(cur().k!=TK::RParen){do{z->args.push_back(expr());}while(eat(TK::Comma));}
                need(TK::RParen,"expected ')' after function arguments");
                if(z->args.size()>32)throw Error(loc(z->line,z->col,"function calls support at most 32 arguments"));
                x=std::move(z);
            } else {
                // v0.23.29-dev: a fixed-length array field may be subscripted
                // — `s.xs[i]`. The base is a Field (the array field), the
                // index goes in `b`, and `name` is left empty so the named-array
                // Index path (which keys on `name`) never mistakes it for one.
                // Whether the field is actually an array field is decided by
                // sema; a `[` after a scalar or struct field is rejected there
                // as "cannot index non-array field".
                //
                // v0.23.31-dev: a `[` may now follow an *Index* too — that is
                // multi-dimensional indexing, `a[i][j]` and `s.xs[i][j]`. The
                // shape is the same one a Field takes: the base goes in `a`, the
                // index in `b`, `name` stays empty. What the base subscripts is
                // decided by sema, which answers "is this still an array?" from
                // the dimension list of whatever the base names — so the same
                // loop builds one, two and three dimensions without knowing
                // which it is looking at, exactly as the `.` and `[` passes were
                // folded into one loop in v0.23.29-dev.
                //
                // v0.23.34-dev: a `[` may follow an `&` too — `(&arr)[i]`. An
                // array parameter decays to a typed pointer and `&arr` yields
                // one, so the pointer a program can hold in a variable it can
                // also subscript where it is written: `let p = &arr; p[i]` and
                // `(&arr)[i]` are the same two steps. Only `&` is let through
                // here — a number, a call or a parenthesised sum still has no
                // stride, and refusing those in the parser keeps sema's
                // "cannot index this expression" for the shapes that have no
                // reading at all rather than for one that does.
                if(x->k!=Expr::Field&&x->k!=Expr::Index&&x->k!=Expr::AddrOf)
                    throw Error(loc(cur().line,cur().col,"cannot index this expression"));
                ++p;E idx=expr();need(TK::RBracket,"expected ']' after array index");
                E z(new Expr(Expr::Index));z->a=std::move(x);z->b=std::move(idx);
                z->name="";z->line=cur().line;z->col=cur().col;x=std::move(z);
            }
        }
        // v0.23.38-dev: a `(` that reached the end of the chain unclaimed. A
        // call's result and a subscript's element are the two shapes a program
        // plausibly tries to call on the spot — `get()(x)`, `h.cbs[0](x)` —
        // and both used to be reported as a missing ';'. Say what is wrong
        // instead: neither one is a field, and only a field carries a
        // signature here.
        if(cur().k==TK::LParen&&(x->k==Expr::Call||x->k==Expr::Index))
            throw Error(loc(cur().line,cur().col,"cannot call the result of this expression: assign it to a fn(...) variable or a fn(...) field first"));
        return x;
    }
    // v0.23.27-dev: the prefix operators, at their own level between postfix()
    // and the binary ones. An operand is parsed at unary() depth, so a prefix
    // operator sees the whole postfix chain: `-s.v` is `-(s.v)`, `!s.ok` is
    // `!(s.ok)`, `~s.v` is `~(s.v)` and `*p.f` is `*(p.f)` — the C reading.
    // Until this release each took a primary() operand, which put the `.` on
    // the outside (`(-s).v`) and made every one of those a compile error when
    // the operand was a struct. `&` moves here too; it already reached
    // postfix(), so its meaning is unchanged.
    //
    // `&&` cannot be mistaken for two `&`: the lexer emits one token for the
    // logical form, and `eat(TK::Amp)` matches only the single one.
    E unary(){
        if(eat(TK::Star)){E x=unary();E z(new Expr(Expr::Deref));z->line=x->line;z->col=x->col;z->a=std::move(x);return z;}
        // &x : the address of an lvalue. Only a struct lvalue has a typed
        // address today (Sema rejects the rest), so this is how a struct
        // reaches a C function that wants a pointer to one.
        if(eat(TK::Amp)){E x=unary();E z(new Expr(Expr::AddrOf));z->line=x->line;z->col=x->col;z->a=std::move(x);return z;}
        if(eat(TK::Minus)){E x=unary();E z(new Expr(Expr::Neg));z->line=x->line;z->col=x->col;z->a=std::move(x);return z;}
        if(eat(TK::Not)){E x=unary();E z(new Expr(Expr::Not));z->line=x->line;z->col=x->col;z->a=std::move(x);return z;}
        // v0.23.17-dev (round 1): `~x` — one's complement. Emitted as ORN with
        // the zero register, which is what a C compiler calls `mvn`.
        if(eat(TK::Tilde)){E x=unary();E z(new Expr(Expr::BitNot));z->line=x->line;z->col=x->col;z->a=std::move(x);return z;}
        return postfix();
    }
    // v0.23.17-dev (round 1): `%` joins `*` and `/`.
    E product(){E x=unary();while(cur().k==TK::Star||cur().k==TK::Slash||cur().k==TK::Percent){TK op=t[p++].k;E y=unary();E z(new Expr(op==TK::Star?Expr::Mul:op==TK::Slash?Expr::Div:Expr::Mod));z->a=std::move(x);z->b=std::move(y);z->line=z->a->line;z->col=z->a->col;x=std::move(z);}return x;}
    E sum(){E x=product();while(cur().k==TK::Plus||cur().k==TK::Minus){TK op=t[p++].k;E y=product();E z(new Expr(op==TK::Plus?Expr::Add:Expr::Sub));z->a=std::move(x);z->b=std::move(y);z->line=z->a->line;z->col=z->a->col;x=std::move(z);}return x;}
    // `<<` / `>>` sit between additive and relational, as in C: `a + b << c`
    // is `(a + b) << c`, and `a << b < c` is `(a << b) < c`.
    E shift(){E x=sum();while(cur().k==TK::Shl||cur().k==TK::Shr){TK op=t[p++].k;E y=sum();E z(new Expr(op==TK::Shl?Expr::Shl:Expr::Shr));z->a=std::move(x);z->b=std::move(y);z->line=z->a->line;z->col=z->a->col;x=std::move(z);}return x;}
    bool isRelationalOp(TK op)const{return op==TK::Lt||op==TK::Le||op==TK::Gt||op==TK::Ge;}
    bool isEqualityOp(TK op)const{return op==TK::EqEq||op==TK::Ne;}
    // Relational and equality are two levels (`<` binds tighter than `==`, so
    // `a < b == c` is `(a < b) == c`), and the v0.22.51-dev rule is kept: two
    // comparison operators from the *same* level in a row are rejected rather
    // than silently re-associated. Use && / || to combine.
    //
    // v0.23.27-dev: "same level" is the whole point. Until this release the
    // check asked whether *any* comparison operator followed, so `a < b == c`
    // was rejected even though the comment right above it promised `(a < b)
    // == c` and C agrees. A chain within a level (`a < b < c`, `a == b == c`)
    // is still refused — that is the rule the comment described; `a < b == c`
    // is a level crossing, not a chain.
    E relational(){
        E x=shift();TK op=cur().k;
        if(isRelationalOp(op)){
            ++p;E y=shift();
            Expr::Kind k=op==TK::Lt?Expr::Lt:op==TK::Le?Expr::Le:op==TK::Gt?Expr::Gt:Expr::Ge;
            E z(new Expr(k));z->a=std::move(x);z->b=std::move(y);z->line=z->a->line;z->col=z->a->col;x=std::move(z);
            if(isRelationalOp(cur().k))throw Error("chained comparisons are not supported at "+std::to_string(cur().line)+":"+std::to_string(cur().col));
        }
        return x;
    }
    E equality(){
        E x=relational();TK op=cur().k;
        if(isEqualityOp(op)){
            ++p;E y=relational();
            E z(new Expr(op==TK::EqEq?Expr::Eq:Expr::Ne));z->a=std::move(x);z->b=std::move(y);z->line=z->a->line;z->col=z->a->col;x=std::move(z);
            if(isEqualityOp(cur().k))throw Error("chained comparisons are not supported at "+std::to_string(cur().line)+":"+std::to_string(cur().col));
        }
        return x;
    }
    // `&` | `^` | `|` — three levels, all below equality, as in C. `&` is the
    // same token as address-of; that is unambiguous because unary() consumes
    // a leading `&` as a prefix and this level only ever sees one in operator
    // position, i.e. after a complete left operand.
    E bitand_(){E x=equality();while(cur().k==TK::Amp){++p;E y=equality();E z(new Expr(Expr::BitAnd));z->a=std::move(x);z->b=std::move(y);z->line=z->a->line;z->col=z->a->col;x=std::move(z);}return x;}
    E bitxor_(){E x=bitand_();while(cur().k==TK::BitXor){++p;E y=bitand_();E z(new Expr(Expr::BitXor));z->a=std::move(x);z->b=std::move(y);z->line=z->a->line;z->col=z->a->col;x=std::move(z);}return x;}
    E bitor_(){E x=bitxor_();while(cur().k==TK::BitOr){++p;E y=bitxor_();E z(new Expr(Expr::BitOr));z->a=std::move(x);z->b=std::move(y);z->line=z->a->line;z->col=z->a->col;x=std::move(z);}return x;}
    // v0.23.27-dev: `&&` binds tighter than `||`, as in C. Until this release
    // both were one left-associative level, so `a || b && c` read as
    // `(a || b) && c` — a different answer, and a silent one. Two levels now:
    // logicalAnd() collects `&&`, logical() collects `||` over it.
    //
    // Both still short-circuit; this is a matter of which tree is built, and
    // no shipped example mixes the two, so nothing changes bytes.
    E logicalAnd(){
        E x=bitor_();
        while(cur().k==TK::And){
            ++p;E y=bitor_();
            E z(new Expr(Expr::And));z->a=std::move(x);z->b=std::move(y);z->line=z->a->line;z->col=z->a->col;x=std::move(z);
        }
        return x;
    }
    E logical(){
        E x=logicalAnd();
        while(cur().k==TK::Or){
            ++p;E y=logicalAnd();
            E z(new Expr(Expr::Or));z->a=std::move(x);z->b=std::move(y);z->line=z->a->line;z->col=z->a->col;x=std::move(z);
        }
        return x;
    }
    // `c ? a : b` — the last level, so a conditional can be the whole right
    // hand side of another conditional (`c ? a : d ? b : e` nests right, as in
    // C). Both arms are parsed at full expr() precedence.
    E expr(){
        E x=logical();
        if(cur().k==TK::Question){
            auto q=t[p++];
            E a=expr();need(TK::Colon,"expected ':' in conditional expression");E b=expr();
            E z(new Expr(Expr::Cond));z->a=std::move(x);z->b=std::move(a);
            z->args.push_back(std::move(b));
            z->line=q.line;z->col=q.col;
            return z;
        }
        return x;
    }
    std::vector<Stmt> block(){need(TK::LBrace,"expected '{'");std::vector<Stmt> v;while(cur().k!=TK::RBrace&&cur().k!=TK::End)v.push_back(statement());need(TK::RBrace,"expected '}'");return v;}
    // Assignment-form statements, shared by statement() and the for-loop
    // initializer/step slots (a for clause accepts the same forms minus let,
    // and the initializer additionally accepts a let declaration).
    // ---------------------------------------------------------------------
    // v0.23.17-dev (round 1): compound assignment and ++ / --
    //
    // `x OP= e` is desugared to `x = x OP e` here in the parser, so no
    // code-generation path changes and every existing output stays byte for
    // byte what it was. Desugaring is observable in exactly one case: a target
    // whose *address* comes from an expression, where `a[f()] += 1` would call
    // f twice and C would not. Aster has no other source of side effects in an
    // expression — there is no assignment expression, and ++ / -- are
    // statements — so rejecting a call inside the address sub-expression is
    // precisely what makes the desugaring unobservable, and it is rejected
    // rather than silently done wrong.
    // ---------------------------------------------------------------------
    static bool compoundAssignOp(TK t,Expr::Kind& out){
        switch(t){
            case TK::PlusEq:    out=Expr::Add;    return true;
            case TK::MinusEq:   out=Expr::Sub;    return true;
            case TK::StarEq:    out=Expr::Mul;    return true;
            case TK::SlashEq:   out=Expr::Div;    return true;
            case TK::PercentEq: out=Expr::Mod;    return true;
            case TK::ShlEq:     out=Expr::Shl;    return true;
            case TK::ShrEq:     out=Expr::Shr;    return true;
            case TK::AndEq:     out=Expr::BitAnd; return true;
            case TK::OrEq:      out=Expr::BitOr;  return true;
            case TK::XorEq:     out=Expr::BitXor; return true;
            default: return false;
        }
    }
    bool isCompoundAssign(TK t)const{Expr::Kind dummy=Expr::Add;return compoundAssignOp(t,dummy);}
    static bool containsCall(const Expr& e){
        if(e.k==Expr::Call)return true;
        if(e.a&&containsCall(*e.a))return true;
        if(e.b&&containsCall(*e.b))return true;
        for(const auto& x:e.args)if(containsCall(*x))return true;
        return false;
    }
    // v0.23.39-dev: does the statement starting here discard a call? The two
    // shapes that reach the top of an expression as a Call or a FieldCall are a
    // direct call `foo(` and a field call `h.x.y(`; everything else (a bare
    // variable, an assignment target, a plain field read) returns false so the
    // dispatch below keeps its existing reading. The peek reaches past the dot
    // chain to the `(` so `h.onClick(41)` is told from `h.field = v` — the
    // former is a discarded call, the latter a field store — without consuming
    // a single token (the assignment forms below re-parse from the same spot).
    bool isCallStatement() const {
        if(cur().k!=TK::Ident) return false;
        size_t q=p+1;
        if(t[q].k==TK::LParen) return true;          // foo(...)
        if(t[q].k==TK::Dot){                          // h.x.y(...)
            q++;
            while(t[q].k==TK::Ident){
                q++;
                if(t[q].k==TK::LParen) return true;
                if(t[q].k==TK::Dot){ q++; continue; }
                break;
            }
        }
        return false;
    }
    // A fresh copy of a target expression, so the statement's target and the
    // value it is combined with can each own their own tree.
    static E cloneExpr(const Expr& e){
        E z(new Expr(e.k));z->n=e.n;z->name=e.name;z->line=e.line;z->col=e.col;
        if(e.a)z->a=cloneExpr(*e.a);
        if(e.b)z->b=cloneExpr(*e.b);
        for(const auto& x:e.args)z->args.push_back(cloneExpr(*x));
        return z;
    }
    // Consume '=' or a compound-assignment token. Returns true for a plain '=';
    // for a compound token it returns false with `op` set to the binary
    // operator the token stands for. Anything else is `what`.
    bool assignOp(Expr::Kind& op,const char* what,unsigned line,unsigned col){
        if(eat(TK::Eq))return true;
        if(compoundAssignOp(cur().k,op)){++p;return false;}
        throw Error(loc(line,col,what));
    }
    // `target OP rhs`, with the double-evaluation guard described above.
    E compoundValue(Expr::Kind op,const Expr& target,unsigned line,unsigned col){
        if(containsCall(target))
            throw Error(loc(line,col,"compound assignment would evaluate this target's address twice; write the assignment out in full instead"));
        E rhs=expr();
        E z(new Expr(op));z->a=cloneExpr(target);z->b=std::move(rhs);z->line=line;z->col=col;
        return z;
    }
    // ++i; --i; i++; i--; — a statement, not an expression. The value of an
    // increment is discarded in a statement either way, so prefix and postfix
    // are the same store, and keeping ++ out of expression position is what
    // lets an expression stay free of side effects (see the note above).
    bool isIncDec(TK t)const{return t==TK::PlusPlus||t==TK::MinusMinus;}
    // The store both spellings share: `name = name +/- 1`.
    static Stmt incDecStore(const Token& opTok,const Token& idTok){
        const bool up=opTok.k==TK::PlusPlus;
        Stmt s(Stmt::Assign);
        E rd(new Expr(Expr::Var));rd->name=idTok.s;rd->line=idTok.line;rd->col=idTok.col;
        E z(new Expr(up?Expr::Add:Expr::Sub));z->a=std::move(rd);
        E one(new Expr(Expr::Num,uint64_t(1)));one->line=opTok.line;one->col=opTok.col;z->b=std::move(one);
        z->line=opTok.line;z->col=opTok.col;
        s.name=idTok.s;s.line=opTok.line;s.col=opTok.col;s.expr=std::move(z);
        return s;
    }
    // prefix: ++name ; --name
    Stmt incDecForm(){
        auto tok=t[p++];
        if(cur().k!=TK::Ident)throw Error(loc(tok.line,tok.col,"'++' and '--' apply to a variable, and only as a statement"));
        auto id=t[p++];
        return incDecStore(tok,id);
    }
    // postfix: name++ ; name--  — same store as the prefix spelling.
    Stmt postIncDecForm(){
        auto id=t[p++];auto tok=t[p++];
        return incDecStore(tok,id);
    }
    Stmt incDecStatement(){Stmt s=incDecForm();need(TK::Semi,"expected ';' after increment");return s;}
    Stmt postIncDecStatement(){Stmt s=postIncDecForm();need(TK::Semi,"expected ';' after increment");return s;}
    Stmt derefAssignStatement(){
        // '*' then a postfix chain, so `*p.f = v` is a field store through the
        // dereferenced pointer rather than a parse error at the '.'.
        ++p;E ptr=unary();   // v0.23.27-dev: `*p.f = v` is `*(p.f) = v`, the same reading as in an expression
        Stmt s(ptr->k==Expr::Field?Stmt::FieldAssign:Stmt::DerefAssign);s.line=ptr->line;s.col=ptr->col;
        Expr::Kind op;
        if(assignOp(op,"expected '=' after dereference target",ptr->line,ptr->col))s.expr=expr();
        else s.expr=compoundValue(op,*ptr,s.line,s.col);
        s.idx=std::move(ptr);need(TK::Semi,"expected ';'");return s;}
    // p.f = v , p.f.g = v : a store through a struct lvalue or a ptr<S>.
    Stmt fieldAssignStatement(){
        E target=postfix();
        Stmt s(Stmt::FieldAssign);s.line=target->line;s.col=target->col;
        Expr::Kind op;
        if(assignOp(op,"expected '=' after field target",s.line,s.col))s.expr=expr();
        else s.expr=compoundValue(op,*target,s.line,s.col);
        s.idx=std::move(target);need(TK::Semi,"expected ';'");return s;}
    // v0.23.31-dev: the `[N]` suffix of an array declaration, one pair per
    // dimension — `T[N]`, `T[N][M]`, `T[N][M][K]`. The lengths come back
    // outermost first, so `dims[0]` is the length the first subscript indexes
    // and `dims.back()` the last; an empty vector means no bracket was there.
    //
    // Each length is bounded where it is read, and the caller bounds the
    // *total* element count against its own limit — a local array and a global
    // one have never shared one, and `T[1000][1000]` must not become a legal
    // local just because each dimension on its own is small.
    //
    // The three diagnostics are exactly the ones the single-dimension
    // spellings have always produced: this function is what reads them now, so
    // a suite that pins the message still pins it.
    std::vector<uint32_t> arrayDimList(const std::string& what,uint32_t limit,const std::string& subject){
        std::vector<uint32_t> dims;
        while(cur().k==TK::LBracket){
            ++p;                                                    // the '['
            auto n=need(TK::Number,("expected "+what).c_str());
            unsigned long long cnt=unsignedLiteral(n,what.c_str());
            if(cnt==0||cnt>limit)
                throw Error(loc(n.line,n.col,what+" must be between 1 and "+std::to_string(limit)+": "+subject));
            need(TK::RBracket,("expected ']' after "+what).c_str());
            dims.push_back((uint32_t)cnt);
        }
        return dims;
    }
    // The total element count of a dimension list, and the guard that keeps a
    // multi-dimensional declaration inside the same total-element limit the
    // one-dimensional spelling has always had.
    uint32_t dimsTotal(std::vector<uint32_t>& dims,uint32_t limit,const std::string& what,
                       const std::string& subject,unsigned line,unsigned col){
        if(dims.empty())return 1;
        uint64_t total=1;
        for(uint32_t d:dims)total*=d;
        if(total>limit)
            throw Error(loc(line,col,what+" must be between 1 and "+std::to_string(limit)+": "+subject));
        return (uint32_t)total;
    }
    // v0.23.31-dev: the subscripts of an indexed assignment target —
    // `a[i]`, `a[i][j]`, `a[i][j][k]`. One subscript comes back as itself, so
    // the one-dimensional path is unchanged in every respect. Two or more come
    // back as the outermost `Index` of a chain whose innermost node is the
    // named array, which is exactly the shape `postfix()` builds for the same
    // expression — so an assignment and a read of `a[i][j]` reach the same
    // address computation, and there is no second spelling of it to disagree.
    // The count rides along in `subs`, because a chain and a bare subscript
    // cannot be told apart by looking at the expression alone (`a[b[0][1]]`
    // writes one subscript that happens to be a chain), and Sema needs the
    // difference to tell a row store from an element store.
    E indexSubscripts(const std::string& name,unsigned line,unsigned col,unsigned& subs){
        subs=1;
        need(TK::LBracket,"expected '['");
        E first=expr();need(TK::RBracket,"expected ']' after array index");
        if(cur().k!=TK::LBracket)return first;
        E target(new Expr(Expr::Index));target->name=name;target->line=line;target->col=col;target->a=std::move(first);
        while(cur().k==TK::LBracket){
            ++p;E j=expr();need(TK::RBracket,"expected ']' after array index");
            E z(new Expr(Expr::Index));z->a=std::move(target);z->b=std::move(j);z->name="";
            z->line=line;z->col=col;target=std::move(z);
            ++subs;
        }
        return target;
    }
    Stmt letStatement(){
        auto id=need(TK::Ident,"expected variable name");need(TK::Colon,"expected ':'");
        const Ty ty=needType(kTypeExpected);
        Stmt s(Stmt::Let);s.name=id.s;s.line=id.line;s.col=id.col;s.ty=ty;s.isPtr=(ty==Ty::Ptr);s.isBool=(ty==Ty::Bool);
        // v0.23.37-dev: a fn-pointer let keeps its signature beside the ptr
        // storage type, for Sema/codegen to read at the call site.
        if(pendingFuncType){s.funcSig=pendingFuncSig;s.isFunc=true;pendingFuncType=false;pendingFuncSig=FuncSig();}
        // v0.23.28-dev: a local array extension, open to every element type.
        // It used to be gated on the type being an integer one, so `bool[4]`,
        // `Point[4]` and a local `ptr[4]` were not declarations Aster could
        // parse — and a ptr one was refused with a message of its own. The
        // element type is the type written before the `[`, and every later
        // read, write and address computation reads it back from there.
        // v0.23.31-dev: one `[N]` per dimension. `count` is the total
        // element count, which is what the frame reservation and the
        // broadcast initializer want; `dims` is what a subscript's bounds
        // check and the outer stride want. The bracket is consumed by
        // arrayDimList itself — the same shape every declaration site uses,
        // so one function owns the whole spelling.
        if(cur().k==TK::LBracket){
            s.dims=arrayDimList("local array length",1000,id.s);
            if(!s.dims.empty()){s.isArray=true;s.count=dimsTotal(s.dims,1000,"local array length",id.s,id.line,id.col);}
        }
        if(!s.isArray&&cur().k==TK::At)throw Error(loc(id.line,id.col,"local alignment is not supported: "+id.s));
        // v0.23.29-dev: a struct local may be declared without an initializer —
        // its frame slots are zero-filled — which is what lets a struct that
        // contains an array field be a local: an array field cannot be set by a
        // struct literal, so for such a struct the literal form is unavailable
        // and zero-fill plus runtime element writes is the only shape.
        if(tyIsStruct(ty)&&!s.isArray&&cur().k!=TK::Eq){s.expr=nullptr;need(TK::Semi,"expected ';'");return s;}
        need(TK::Eq,"expected '='");s.expr=expr();need(TK::Semi,"expected ';'");return s;
    }
    Stmt indexAssignStatement(){
        auto id=t[p++];
        Stmt s(Stmt::IndexAssign);s.name=id.s;s.line=id.line;s.col=id.col;
        E idx=indexSubscripts(id.s,id.line,id.col,s.subs);
        Expr::Kind op;
        if(assignOp(op,"expected '=' in array element assignment",id.line,id.col))s.expr=expr();
        else{
            // A compound store reads the element back through the same
            // subscript, so the subscript has to be side-effect free.
            if(containsCall(*idx))
                throw Error(loc(id.line,id.col,"compound assignment would evaluate the subscript twice; write the assignment out in full instead"));
            // The read-back is the same target the store writes: one subscript
            // rebuilds the named-array Index, several clone the whole chain.
            E rd;
            if(idx->k==Expr::Index&&idx->name.empty())rd=cloneExpr(*idx);
            else { E n(new Expr(Expr::Index));n->name=id.s;n->line=id.line;n->col=id.col;n->a=cloneExpr(*idx);rd=std::move(n); }
            E rhs=expr();E z(new Expr(op));z->a=std::move(rd);z->b=std::move(rhs);z->line=id.line;z->col=id.col;
            s.expr=std::move(z);
        }
        s.idx=std::move(idx);need(TK::Semi,"expected ';'");return s;}
    Stmt assignStatement(){
        auto id=t[p++];
        Stmt s(Stmt::Assign);s.name=id.s;s.line=id.line;s.col=id.col;
        Expr::Kind op;
        if(assignOp(op,"expected '=' after variable name",id.line,id.col))s.expr=expr();
        else{
            // A plain variable has no address computation to repeat, so a
            // compound assignment to one is always exactly `x = x OP e`.
            E rd(new Expr(Expr::Var));rd->name=id.s;rd->line=id.line;rd->col=id.col;
            E rhs=expr();E z(new Expr(op));z->a=std::move(rd);z->b=std::move(rhs);z->line=id.line;z->col=id.col;
            s.expr=std::move(z);
        }
        need(TK::Semi,"expected ';'");return s;}
    // The token after the current one, or End at the end of the stream (for-loop
    // clauses sit outside block()'s RBrace/End guard, so lookahead must be safe).
    TK after()const{return p+1<t.size()?t[p+1].k:TK::End;}
    // A for initializer/step slot. The initializer accepts a let declaration
    // (and every assignment form); the step accepts assignment forms only.
    // Assignment clauses consume their trailing ';' only in the initializer —
    // in C's for header the step is followed by ')', not ';'. Returns false
    // when the slot is empty.
    bool forClause(std::vector<Stmt>& out,bool allowLet,bool wantSemi){
        if(cur().k==TK::Semi||cur().k==TK::RParen)return false;
        if(cur().k==TK::Let){
            if(!allowLet)throw Error("for step cannot declare a variable at "+std::to_string(cur().line)+":"+std::to_string(cur().col));
            ++p; // consume 'let' before delegating
            out.push_back(letStatement());return true; // let carries its own ';'
        }
        // v0.23.17-dev: a for step may be `i += 2` or `i++` as well as `i = …`.
        if(cur().k==TK::PlusPlus||cur().k==TK::MinusMinus){
            Stmt s=incDecForm();if(wantSemi)need(TK::Semi,"expected ';'");
            out.push_back(std::move(s));return true;
        }
        if(cur().k==TK::Ident&&isIncDec(after())){
            Stmt s=postIncDecForm();if(wantSemi)need(TK::Semi,"expected ';'");
            out.push_back(std::move(s));return true;
        }
        Stmt s(cur().k==TK::Star?Stmt::DerefAssign:(cur().k==TK::Ident&&after()==TK::LBracket)?Stmt::IndexAssign:Stmt::Assign);
        if(s.k==Stmt::DerefAssign){++p;E ptr=unary();Expr::Kind op;   // v0.23.27-dev: as above
            if(assignOp(op,"expected '=' after dereference target",ptr->line,ptr->col))s.expr=expr();
            else s.expr=compoundValue(op,*ptr,ptr->line,ptr->col);
            s.idx=std::move(ptr);}
        else if(s.k==Stmt::IndexAssign){auto id=t[p++];E idx=indexSubscripts(id.s,id.line,id.col,s.subs);
            Expr::Kind op;
            if(assignOp(op,"expected '=' in array element assignment",id.line,id.col))s.expr=expr();
            else{
                if(containsCall(*idx))
                    throw Error(loc(id.line,id.col,"compound assignment would evaluate the subscript twice; write the assignment out in full instead"));
                E rd;
                if(idx->k==Expr::Index&&idx->name.empty())rd=cloneExpr(*idx);
                else { E n(new Expr(Expr::Index));n->name=id.s;n->line=id.line;n->col=id.col;n->a=cloneExpr(*idx);rd=std::move(n); }
                E rhs=expr();E z(new Expr(op));z->a=std::move(rd);z->b=std::move(rhs);z->line=id.line;z->col=id.col;
                s.expr=std::move(z);
            }
            s.name=id.s;s.idx=std::move(idx);}
        else if(cur().k==TK::Ident&&(after()==TK::Eq||isCompoundAssign(after()))){auto id=t[p++];
            Expr::Kind op;
            if(assignOp(op,"expected '=' after variable name",id.line,id.col))s.expr=expr();
            else{
                E rd(new Expr(Expr::Var));rd->name=id.s;rd->line=id.line;rd->col=id.col;
                E rhs=expr();E z(new Expr(op));z->a=std::move(rd);z->b=std::move(rhs);z->line=id.line;z->col=id.col;
                s.expr=std::move(z);
            }
            s.name=id.s;}
        else throw Error(allowLet?"expected 'let', assignment, or ';' in for initializer at "+std::to_string(cur().line)+":"+std::to_string(cur().col)
                           :"expected assignment or ')' in for step at "+std::to_string(cur().line)+":"+std::to_string(cur().col));
        if(wantSemi)need(TK::Semi,"expected ';'");
        out.push_back(std::move(s));return true;
    }
    // An `if` statement. `else if (c) { }` is sugar for `else { if (c) { } }`:
    // after the optional `else`, if the next token is `if` we parse another
    // if statement and wrap it in the else branch, so a chain desugars to the
    // same nested-block shape the explicit `else { if … }` form already uses.
    // v0.23.22-dev: `else` is now optional. It used to be mandatory, which
    // forced `} else { }` filler blocks into real code (the icon demo carries
    // one) and made the plain `if (c) { … }` without a fallback — the most
    // common shape in C — a compile error. An absent else leaves elseBody
    // empty: codegen's `block({})` emits nothing, and sema's
    // `definitelyReturns` already demands both branches, so a then-branch
    // return no longer proves the function returns. No codegen path changes,
    // which is what keeps every existing output byte-identical.
    Stmt ifStatement(){
        Stmt s(Stmt::If);need(TK::LParen,"expected '(' after if");s.expr=expr();s.line=s.expr->line;s.col=s.expr->col;need(TK::RParen,"expected ')' after condition");s.thenBody=block();
        if(eat(TK::Else)){
            if(eat(TK::If)){std::vector<Stmt> eb;eb.push_back(ifStatement());s.elseBody=std::move(eb);}
            else s.elseBody=block();
        }
        return s;
    }
    // `a[i].f` at the head of a statement: an identifier, a bracketed
    // subscript, and a '.' after the closing bracket. Only the token *after*
    // the subscript distinguishes it from `a[i] = v`, so the brackets are
    // matched here — the subscript is an arbitrary expression and may itself
    // contain one.
    bool indexedThenField() const {
        if(cur().k!=TK::Ident||t[p+1].k!=TK::LBracket)return false;
        size_t i=p+1;int depth=0;
        for(;i<t.size();++i){
            const TK k=t[i].k;
            if(k==TK::End)return false;
            if(k==TK::LBracket)++depth;
            else if(k==TK::RBracket&&--depth==0){++i;break;}
        }
        return depth==0&&i<t.size()&&t[i].k==TK::Dot;
    }
    Stmt statement(){
        if(cur().k==TK::Star)return derefAssignStatement();
        if(eat(TK::Let))return letStatement();
        if(eat(TK::Return)){Stmt s(Stmt::Return);s.expr=expr();s.line=s.expr->line;s.col=s.expr->col;need(TK::Semi,"expected ';'");return s;}
        if(eat(TK::If))return ifStatement();
        // v0.23.17-dev: `i++;` / `++i;` / `i--;` / `--i;` as statements. The
        // value is discarded either way, so prefix and postfix are the same
        // store — and keeping ++ out of expression position is what lets an
        // Aster expression stay free of side effects (see compoundValue above).
        if(cur().k==TK::PlusPlus||cur().k==TK::MinusMinus)return incDecStatement();
        if(eat(TK::While)){Stmt s(Stmt::While);need(TK::LParen,"expected '(' after while");s.expr=expr();s.line=s.expr->line;s.col=s.expr->col;need(TK::RParen,"expected ')' after condition");s.thenBody=block();return s;}
        if(eat(TK::For)){
            // for (init; cond; step) body  ==  { init; while (cond) { body; step; } }
            // with continue landing on the step (standard for semantics). The
            // three clauses are kept as statements so codegen can place the
            // step between the body and the back-edge without an extra scope.
            Stmt s(Stmt::For);
            need(TK::LParen,"expected '(' after for");
            if(!forClause(s.forInit,true,true))need(TK::Semi,"expected ';' after for initializer");
            if(cur().k==TK::Semi)throw Error("for condition cannot be empty at "+std::to_string(cur().line)+":"+std::to_string(cur().col));
            s.expr=expr();s.line=s.expr->line;s.col=s.expr->col;
            need(TK::Semi,"expected ';' after for condition");
            forClause(s.forStep,false,false);
            need(TK::RParen,"expected ')' after for step");
            s.thenBody=block();
            return s;
        }
        if(cur().k==TK::Break){const Token& bt=cur();++p;Stmt s(Stmt::Break);s.line=bt.line;s.col=bt.col;need(TK::Semi,"expected ';' after break");return s;}
        if(cur().k==TK::Continue){const Token& ct=cur();++p;Stmt s(Stmt::Continue);s.line=ct.line;s.col=ct.col;need(TK::Semi,"expected ';' after continue");return s;}
        // v0.23.39-dev: a bare call whose result is discarded — `foo();` and
        // `h.onClick(41);` — for fire-and-forget callbacks (an event loop that
        // only wants the side effect, never the return value). Only an
        // expression whose outermost node is a Call or a FieldCall qualifies;
        // `x;`, `a+b;` and the assignment forms below keep their readings, so
        // the language gains no meaningless expression statement. isCallStatement()
        // peeks far enough to tell `h.onClick(41)` (a field call) from
        // `h.field = v` (a field store) without consuming tokens, so it runs
        // before the field-assign dispatch catches the `h.` spelling.
        if(isCallStatement()){
            const Token lead=cur();
            E e=expr();
            need(TK::Semi,"expected ';' after call statement");
            Stmt s(Stmt::Expr);s.expr=std::move(e);s.line=lead.line;s.col=lead.col;
            return s;
        }
        // v0.23.17-dev: `x OP= e` is an assignment form too, so the dispatch
        // cannot key on a literal '=' the way it used to.
        // v0.23.28-dev: `a[i].f = v` — a field store through an array element,
        // which a struct array is the first thing to need. The dispatch has to
        // look past the subscript to tell it from `a[i] = v`, so the brackets
        // are matched (they nest: `a[b[i]].f`) and the token after the last
        // `]` decides. The target itself is an ordinary postfix chain.
        if(indexedThenField())return fieldAssignStatement();
        if(cur().k==TK::Ident&&t[p+1].k==TK::Dot)return fieldAssignStatement();
        if(cur().k==TK::Ident&&t[p+1].k==TK::LBracket)return indexAssignStatement();
        // v0.23.17-dev: the postfix spelling sits after the variable name, so
        // it needs its own dispatch entry next to the prefix one above.
        if(cur().k==TK::Ident&&isIncDec(after()))return postIncDecStatement();
        if(cur().k==TK::Ident&&(t[p+1].k==TK::Eq||isCompoundAssign(t[p+1].k)))return assignStatement();
        throw Error("expected let, assignment, return, if, while, for, break, or continue at "+std::to_string(cur().line)+":"+std::to_string(cur().col));
    }
    int64_t foldConst(const Expr& e){
        switch(e.k){
            case Expr::Num: return (int64_t)e.n;
            case Expr::SizeOf: case Expr::Len: return (int64_t)e.n;   // v0.23.35-dev: the type-form folded at parse time
            case Expr::Neg: return -foldConst(*e.a);
            case Expr::Add: return foldConst(*e.a)+foldConst(*e.b);
            case Expr::Sub: return foldConst(*e.a)-foldConst(*e.b);
            case Expr::Mul: return foldConst(*e.a)*foldConst(*e.b);
            case Expr::Div: {
                int64_t a=foldConst(*e.a),b=foldConst(*e.b);
                if(b==0)throw Error(loc(e.line,e.col,"division by zero in global variable initializer"));
                return a/b;
            }
            // v0.23.17-dev (round 1): the new operators fold too, so
            // `let g: i32 = 1 << 4;` and a `~` mask are constants like any other.
            case Expr::Mod: {
                int64_t a=foldConst(*e.a),b=foldConst(*e.b);
                if(b==0)throw Error(loc(e.line,e.col,"division by zero in global variable initializer"));
                return a%b;
            }
            // A shift count outside [0,63] has no defined meaning, and a left
            // shift whose result leaves i64 has nowhere to put its bits. Both
            // are compile errors here — the same rule constantInteger() applies
            // in every other constant position, so a shift cannot silently mean
            // two different things depending on where it is written.
            case Expr::Shl: case Expr::Shr: {
                int64_t a=foldConst(*e.a),b=foldConst(*e.b);
                if(b<0||b>63)throw Error(loc(e.line,e.col,"shift count "+std::to_string(b)+" is out of range (0..63) in global variable initializer"));
                if(e.k==Expr::Shr)return a>>b;
                int64_t r=0;
                if(__builtin_mul_overflow(a,static_cast<int64_t>(1)<<b,&r))
                    throw Error(loc(e.line,e.col,"left shift overflows i64 in global variable initializer"));
                return r;
            }
            case Expr::BitAnd: return foldConst(*e.a)&foldConst(*e.b);
            case Expr::BitOr:  return foldConst(*e.a)|foldConst(*e.b);
            case Expr::BitXor: return foldConst(*e.a)^foldConst(*e.b);
            case Expr::BitNot: return ~foldConst(*e.a);
            default: throw Error(loc(e.line,e.col,"global variable initializer must be a constant expression"));
        }
    }
    static bool isConstExpr(const Expr& e){
        switch(e.k){
            case Expr::Num: return true;
            case Expr::SizeOf: case Expr::Len: return true;   // v0.23.35-dev: a compile-time constant
            case Expr::Neg: return isConstExpr(*e.a);
            case Expr::Add: case Expr::Sub: case Expr::Mul: case Expr::Div:
            case Expr::Mod: case Expr::Shl: case Expr::Shr:
            case Expr::BitAnd: case Expr::BitOr: case Expr::BitXor:
                return isConstExpr(*e.a)&&isConstExpr(*e.b);
            case Expr::BitNot: return isConstExpr(*e.a);
            default: return false;
        }
    }
    // struct Name { field : T, ... }
    //
    // The definition is entered into the table before its fields are read, so
    // a field of this same struct type resolves and is then rejected — a
    // struct cannot contain itself. A field may be another struct, but only
    // one that is already declared, exactly as in C.
    static constexpr uint32_t kMaxStructSize = 1024;
    // The bytes a constant aggregate initializer leaves in the object: one
    // constant per field, written at that field's offset in the struct's own
    // layout. A nested aggregate is folded the same way, field by field, into
    // the bytes its own layout owns. A pointer field cannot be given a
    // constant value, so a struct with one is rejected rather than silently
    // zero-filled.
    std::vector<uint8_t> structConstantImage(Ty ty,const Expr& init,const std::string& name){
        const StructDef& sd=structOf(ty.sid);
        if(structHasArrayField(ty.sid))
            throw Error(loc(init.line,init.col,"struct '"+sd.name+"' contains an array field and cannot be initialized by a literal; declare it without an initializer or fill its elements at runtime: "+name));
        if(init.k!=Expr::StructLit)
            throw Error(loc(init.line,init.col,"global struct initializer must be a struct literal: "+name));
        if(init.args.size()!=sd.fields.size())
            throw Error(loc(init.line,init.col,"struct literal for '"+sd.name+"' has "+std::to_string(init.args.size())+" values but the struct has "+std::to_string(sd.fields.size())+" fields: "+name));
        std::vector<uint8_t> raw(sd.size,0);
        for(size_t i=0;i<sd.fields.size();++i){
            const StructField& f=sd.fields[i];
            const Expr& e=*init.args[i];
            if(f.ty==Ty::Ptr)
                throw Error(loc(e.line,e.col,"global struct field '"+sd.name+"."+f.name+"' cannot be initialized by a constant: "+name));
            if(tyIsStruct(f.ty)){
                if(e.k!=Expr::StructLit)
                    throw Error(loc(e.line,e.col,"global struct field '"+sd.name+"."+f.name+"' must be initialized by a struct literal: "+name));
                const std::vector<uint8_t> sub=structConstantImage(f.ty,e,name);
                std::memcpy(raw.data()+f.offset,sub.data(),sub.size());
                continue;
            }
            int64_t v=0;
            // v0.23.25-dev: true/false initialize a bool field — and only a
            // bool field. constantInteger deliberately does not fold them,
            // so the literal is recognized here instead of being reported
            // as a non-constant initializer.
            if(e.k==Expr::Num&&e.boolLit){
                if(f.ty!=Ty::Bool)
                    throw Error(loc(e.line,e.col,"global struct initializer type mismatch: field '"+sd.name+"."+f.name+"' is "+tyNameFull(f.ty)+", got bool: "+name));
                v=(int64_t)e.n;
            } else if(!constantInteger(e,v))
                throw Error(loc(e.line,e.col,"global struct initializer must be a constant expression: "+name));
            if(f.ty==Ty::Bool&&v!=0&&v!=1)
                throw Error(loc(e.line,e.col,"bool field '"+sd.name+"."+f.name+"' must be initialized with 0 or 1: "+name));
            if(f.ty!=Ty::Bool&&!initializerFits(f.ty,e,v))
                throw Error(loc(e.line,e.col,"initializer does not fit in "+std::string(tyName(f.ty))+" field '"+sd.name+"."+f.name+"': "+name));
            const uint64_t u=(uint64_t)v;
            for(uint32_t b=0;b<tySize(f.ty);++b)raw[f.offset+b]=(uint8_t)(u>>(8*b));
        }
        return raw;
    }
    void structDeclaration(){
        auto id=need(TK::Ident,"expected struct name");
        if(g_structIndex.count(id.s))throw Error(loc(id.line,id.col,"duplicate struct declaration: "+id.s));
        for(const auto& g:globals)if(g.name==id.s)throw Error(loc(id.line,id.col,"struct name conflicts with a global variable: "+id.s));
        for(const auto& f:functions)if(f.name==id.s)throw Error(loc(id.line,id.col,"struct name conflicts with a function: "+id.s));
        StructDef s;s.name=id.s;
        const int sid=(int)g_structs.size();
        g_structs.push_back(StructDef());
        g_structIndex[id.s]=sid;
        need(TK::LBrace,"expected '{' after struct name");
        if(cur().k!=TK::RBrace){
            do{
                auto fn=need(TK::Ident,"expected field name");
                need(TK::Colon,"expected ':' after field name");
                const Ty fty=needType(kTypeExpected);
                // v0.23.38-dev: a struct field may be a fn-pointer, and then
                // the signature lives in the field itself — the layout table is
                // where every other field property lives, so it is where a
                // `h.onClick(x)` finds out how to stage its arguments. This
                // used to be refused ("use a pointer instead"); a field is a
                // declaration like a global or a parameter, and it carries its
                // signature the same way those two do.
                bool fieldIsFunc=false; FuncSig fieldFuncSig;
                if(pendingFuncType){fieldIsFunc=true;fieldFuncSig=pendingFuncSig;pendingFuncType=false;pendingFuncSig=FuncSig();}
                if(tyIsStruct(fty)&&fty.sid==sid)throw Error(loc(id.line,id.col,"struct "+id.s+" cannot contain itself"));
                // v0.23.29-dev: a field may be a fixed-length array (`xs: T[N]`).
                // Any element type is allowed (scalar, bool, struct or ptr) —
                // the element is a value of its own type once indexed. The
                // length shares the local-array limit (1..1000).
                // v0.23.31-dev: it may be multi-dimensional (`xs: T[N][M]`), so
                // the field carries each length outermost first in `dims` while
                // `len` stays the total the layout already multiplies by.
                std::vector<uint32_t> dims;
                if(cur().k==TK::LBracket)
                    dims=arrayDimList("array field length",1000,id.s+"."+fn.s);
                uint32_t flen=0;
                if(!dims.empty()){
                    // v0.23.38-dev: an array of fn-pointers is refused here
                    // rather than silently losing its signature — `h.cbs[0](x)`
                    // has no field to read one from, and a field that declares
                    // `fn(...)` and then behaves like a bare ptr would be the
                    // worst of both. A plain `ptr[4]` field is unaffected.
                    if(fieldIsFunc)
                        throw Error(loc(fn.line,fn.col,"an array of function pointers is not supported: "+id.s+"."+fn.s));
                    flen=1;for(uint32_t d:dims)flen*=d;
                    if(flen>1000)
                        throw Error(loc(fn.line,fn.col,"array field length must be between 1 and 1000: "+id.s+"."+fn.s));
                }
                for(const auto& old:s.fields)if(old.name==fn.s)throw Error(loc(fn.line,fn.col,"duplicate field in struct "+id.s+": "+fn.s));
                s.fields.push_back({fn.s,fty,0,flen,std::move(dims),std::move(fieldFuncSig),fieldIsFunc});
            } while(eat(TK::Comma));
        }
        need(TK::RBrace,"expected '}' after struct fields");
        if(s.fields.empty())throw Error(loc(id.line,id.col,"struct "+id.s+" must declare at least one field"));
        layoutStruct(s);
        if(s.size>kMaxStructSize)
            throw Error(loc(id.line,id.col,"struct "+id.s+" is too large: "+std::to_string(s.size)+" bytes (limit "+std::to_string(kMaxStructSize)+")"));
        g_structs[(size_t)sid]=std::move(s);
    }
    // Global declaration grammar (array and @align extension):
    //   let name : T [ '[' length ']' ] [ '@' 'align' '(' power_of_two ')' ] '=' expr ;
    //   extern let name : T [ '[' length ']' ] ;
    // T is the element type for an array and the value type otherwise; the
    // wider integer types (v0.23.2-dev) carry their own storage width.
    void globalDeclaration(bool external){
        auto id=need(TK::Ident,"expected global variable name");
        need(TK::Colon,"expected ':'");
        const Ty ty=needType(kTypeExpected);
        // v0.23.37-dev: a fn-pointer global keeps its signature beside the ptr
        // storage type. Capture it up front; the scalar branch below (a
        // fn-pointer is a ptr scalar) seeds its Global from here.
        bool isFuncType=false; FuncSig funcTypeSig;
        if(pendingFuncType){isFuncType=true;funcTypeSig=pendingFuncSig;pendingFuncType=false;pendingFuncSig=FuncSig();}
        if(ty==Ty::Bool){
            // Bool globals are stored as a 4-byte i32 (0/1) and accept only a
            // constant initializer — non-constant bool initializers would need
            // the runtime-init path, which this release keeps for i32 arrays only.
            // v0.23.28-dev: `let flags : bool [ 4 ] = true;` — one 4-byte slot
            // per element, filled with the same 0/1 an integer array is filled
            // with. The length used to be unreachable here: the Bool branch
            // never looked for a `[`, so a bool array was a syntax error.
            Global g;g.name=id.s;g.external=external;g.isBool=true;g.ty=Ty::Bool;
            for(const auto& old:globals)if(old.name==g.name)throw Error(loc(id.line,id.col,"duplicate global variable: "+g.name));
            if(cur().k==TK::LBracket){
                // v0.23.31-dev: one `[N]` per dimension, outermost first; the
                // total element count is what `.data`/`.bss` sizing uses.
                g.dims=arrayDimList("array length",1048576,g.name);
                if(!g.dims.empty()){g.isArray=true;g.count=dimsTotal(g.dims,1048576,"array length",g.name,id.line,id.col);}
            }
            if(external){need(TK::Semi,"expected ';' after extern global declaration");}
            else {
                need(TK::Eq,"expected '=' in global variable declaration");E init=expr();need(TK::Semi,"expected ';'");
                if(!isConstExpr(*init))throw Error(loc(init->line,init->col,"bool global initializer must be a constant expression: "+g.name));
                const int64_t v=foldConst(*init);
                if(v!=0&&v!=1)throw Error(loc(init->line,init->col,"bool global initializer must be 0 or 1: "+g.name));
                g.init=(int32_t)v;
            }
            globals.push_back(std::move(g));
            return;
        }
        // A struct global: `let g : Point = Point { 1, 2 };` or an extern
        // declaration of one defined elsewhere. The initializer has to be a
        // constant aggregate, because there is no run-time initializer for a
        // composite, so its bytes are laid out here and copied to .data as is.
        if(tyIsStruct(ty)){
            Global g;g.name=id.s;g.external=external;g.ty=ty;g.align=tyAlign(ty);
            for(const auto& old:globals)if(old.name==g.name)throw Error(loc(id.line,id.col,"duplicate global variable: "+g.name));
            // v0.23.28-dev: `let pts : Point [ 4 ] = Point { 0, 0 };` — N
            // elements laid out end to end, each a copy of the constant
            // aggregate. An array of composites used to be unreachable from
            // this branch, which looked for `=` and never for `[`.
            if(cur().k==TK::LBracket){
                // v0.23.31-dev: several `[N]` pairs; the total element count is
                // the number of copies `layoutObject` lays out end to end.
                g.dims=arrayDimList("array length",1048576,g.name);
                if(!g.dims.empty()){g.isArray=true;g.count=dimsTotal(g.dims,1048576,"array length",g.name,id.line,id.col);}
            }
            if(external){need(TK::Semi,"expected ';' after extern global declaration");}
            else if(structHasArrayField(ty.sid)){
                // v0.23.29-dev: a struct with an array field cannot be set by a
                // literal (the field alone needs N separate values), so declare
                // it without an initializer and zero-fill it in .bss; its
                // elements are filled at run time. A literal `=` is refused.
                if(cur().k==TK::Eq)throw Error(loc(cur().line,cur().col,"struct '"+structOf(ty.sid).name+"' contains an array field and cannot be initialized by a literal; declare it without an initializer: "+g.name));
                g.rawData=std::vector<uint8_t>(structOf(ty.sid).size*(g.isArray?g.count:1),0);
                g.init=0;
                need(TK::Semi,"expected ';' after global variable declaration");
            }
            else{
                need(TK::Eq,"expected '=' in global variable declaration");E init=expr();need(TK::Semi,"expected ';'");
                g.rawData=structConstantImage(ty,*init,g.name);
            }
            bool allZero=true;for(const uint8_t b:g.rawData)if(b){allZero=false;break;}
            g.init=allZero?0:1;   // zero-initialized: .bss, like a zero scalar
            globals.push_back(std::move(g));
            return;
        }
        Global g;g.name=id.s;g.external=external;g.ty=ty;g.funcSig=funcTypeSig;g.isFunc=isFuncType;
        if(cur().k==TK::LBracket){
            // v0.23.31-dev: one `[N]` per dimension. The element type is the
            // type written before the first `[` and every later read, write and
            // address computation reads it back from there.
            g.dims=arrayDimList("array length",1048576,g.name);
            if(!g.dims.empty()){g.isArray=true;g.count=dimsTotal(g.dims,1048576,"array length",g.name,id.line,id.col);}
        }
        if(eat(TK::At)){
            auto a=need(TK::Ident,"expected 'align' after '@'");
            if(a.s!="align")throw Error("expected 'align' after '@' at "+std::to_string(a.line)+":"+std::to_string(a.col));
            need(TK::LParen,"expected '(' after align");
            auto v=need(TK::Number,"expected alignment value");
            unsigned long long al=unsignedLiteral(v,"alignment value");
            need(TK::RParen,"expected ')' after alignment");
            if(al==0||(al&(al-1))!=0)throw Error("alignment must be a power of two: "+g.name);
            if(al>4096)throw Error("alignment must not exceed 4096 bytes: "+g.name);
            g.align=al;
        }
        for(const auto& old:globals)if(old.name==g.name){
            if(!old.fromInclude)throw Error("duplicate global variable: "+g.name);
            dropIncluded(g.name);break;   // this file's own definition wins
        }
        if(external){need(TK::Semi,"expected ';' after extern global declaration");}
        else if(isFuncType&&cur().k!=TK::Eq){
            // v0.23.37-dev: a fn-pointer global may be declared without an
            // initializer — it holds a null pointer until assigned — the way a
            // struct global may be declared without one. g stays zero, so it
            // lands in .bss exactly like any other zero scalar.
            need(TK::Semi,"expected ';' after global variable declaration");
        }
        else {
            need(TK::Eq,"expected '=' in global variable declaration");E init=expr();need(TK::Semi,"expected ';'");
            // v0.23.25-dev: a bool literal is not an integer constant. The
            // folder below would happily store `true` as the value 1 in an
            // i32 — or u8, or array — slot; the type system says it may not.
            // (A bool global took its own branch above, where true/false
            // fold to the 0/1 that slot holds.)
            if(init->k==Expr::Num&&init->boolLit)
                throw Error(loc(init->line,init->col,"global initializer type mismatch: expected "+tyNameFull(ty)+", got bool"));
            if(g.isArray){
                if(!isConstExpr(*init))throw Error("array initializer must be a constant expression: "+g.name);
                const int64_t value=foldConst(*init);
                if(!initializerFits(ty,*init,value))
                    throw Error("array initializer does not fit in "+tyNameFull(ty)+": "+g.name+" ("+std::to_string(value)+")");
                if(tyIs64(ty))g.wideInit=(uint64_t)value;else g.init=(int32_t)(uint32_t)(uint64_t)value;
            } else if(isConstExpr(*init)){
                const int64_t value=foldConst(*init);
                if(!initializerFits(ty,*init,value))
                    throw Error("global initializer does not fit in "+tyNameFull(ty)+": "+g.name+" ("+std::to_string(value)+")");
                if(tyIs64(ty))g.wideInit=(uint64_t)value;else g.init=(int32_t)(uint32_t)(uint64_t)value;
            } else {
                g.runtimeInit=true;g.initExpr=std::move(init);
            }
        }
        globals.push_back(std::move(g));
    }
public:
    explicit Parser(const std::string&s,bool requireEntry=true,
                    const std::string& selfDir_="",IncludeState* inc=nullptr)
        :t(Lexer(s).run()),requireMain(requireEntry),includes(inc?inc:&ownIncludes),selfDir(selfDir_){}
    std::vector<Function> functions;
    std::vector<Global> globals;

    // `include "path";` — another file's declarations, brought into this
    // translation unit.
    //
    // What comes across is *declarations only*. A function's body and a global's
    // initializer stay in the file that owns them, because there has to be
    // exactly one definition of each symbol for the link to make sense. The
    // interesting consequence is that the declaration cannot drift from the
    // definition: it is not a second hand-written copy of the signature, it is
    // the signature read out of the file that holds the body. (Including a file
    // that itself only holds `extern` declarations works exactly as you'd
    // expect — those come across unchanged.)
    void includeDirective(){
        const Token at=cur();
        const Token pathTok=need(TK::String,"expected a file path in quotes after include");
        need(TK::Semi,"expected ';' after include");
        const std::string full=resolveIncludePath(pathTok.s);
        // The cycle check comes FIRST, before "already pulled in", because a
        // file that is part-way through being parsed is in both: reached again
        // through a cycle it has to be an error, and reached again through a
        // diamond (two files that both include a third) it has to be a no-op.
        // The stack is what tells those two apart, and only the stack check
        // distinguishes them — so checking `done` first would make every cycle
        // silently look like a repeat, and the check below would never fire.
        for(size_t i=0;i<includes->stack.size();++i){
            if(includes->stack[i]!=full)continue;
            std::string chain;
            for(size_t j=i;j<includes->stack.size();++j){
                if(j>i)chain+=" -> ";
                chain+="\""+includes->stack[j]+"\"";
            }
            throw Error(loc(at.line,at.col,"include cycle: "+chain+" -> \""+full+"\""));
        }
        // Already pulled in and finished: a no-op, not an error. The same file
        // reached by two routes is one file, exactly as @embed treats one
        // embedded twice.
        if(includes->done.count(full))return;
        struct stat st{};
        if(::stat(full.c_str(),&st)!=0)
            throw Error(loc(at.line,at.col,"cannot open included file \""+pathTok.s+"\" (looked for \""+full+"\")"));
        if(S_ISDIR(st.st_mode))
            throw Error(loc(at.line,at.col,"included file is a directory: \""+full+"\""));
        std::ifstream f(full,std::ios::binary);
        if(!f)throw Error(loc(at.line,at.col,"cannot open included file \""+full+"\""));
        const std::string text((std::istreambuf_iterator<char>(f)),std::istreambuf_iterator<char>());
        // Parsed into its own parser so that what it declares is a separate,
        // inspectable list — and so its own `include` lines resolve against *its*
        // directory, not this file's.
        Parser sub(text,false,dirNameOf(full),includes);
        includes->stack.push_back(full);
        includes->done.insert(full);
        try{ sub.parse(); }
        catch(...){ includes->stack.pop_back(); throw; }
        includes->stack.pop_back();
        mergeIncluded(sub);
    }
    // Declarations only, and nothing that would put a second copy of anything in
    // the output: no bodies, no initializers, and not the bytes an included file
    // happened to @embed (those are that file's business).
    // `sub` is taken by reference and consumed: a Function owns its body, which
    // owns unique_ptrs, so a declaration is *made* out of one rather than copied
    // from it. Nothing else looks at the sub-parser after this.
    void mergeIncluded(Parser& sub){
        for(auto& f:sub.functions){
            if(findFunction(f.name))continue;      // a local declaration wins
            f.external=true;f.fromInclude=true;f.body.clear();
            functions.push_back(std::move(f));
        }
        for(const auto& g:sub.globals){
            if(g.fromEmbed)continue;              // those bytes belong to the file that embeds them
            if(findGlobal(g.name))continue;
            // Built field by field rather than copied: a Global owns its
            // initializer through a unique_ptr, and what crosses an include is
            // deliberately less than the whole thing — the name and its type,
            // with the initializer left behind in the file that owns it.
            Global d;
            d.name=g.name;d.ty=g.ty;d.isArray=g.isArray;d.count=g.count;d.isBool=g.isBool;d.align=g.align;
            d.external=true;d.fromInclude=true;
            globals.push_back(std::move(d));
        }
    }
    const Function* findFunction(const std::string& n)const{
        for(const auto& f:functions)if(f.name==n)return &f;
        return nullptr;
    }
    const Global* findGlobal(const std::string& n)const{
        for(const auto& g:globals)if(g.name==n)return &g;
        return nullptr;
    }
    // A definition in this file supersedes a declaration that arrived through
    // `include` — which is what makes "include the header, then define the
    // functions" legal. Two declarations this file wrote itself are still an
    // error, so the check only ever gives way to an included one.
    void dropIncluded(const std::string& name){
        auto fit=std::find_if(functions.begin(),functions.end(),
            [&](const Function& x){return x.name==name&&x.fromInclude;});
        if(fit!=functions.end())functions.erase(fit);
        auto git=std::find_if(globals.begin(),globals.end(),
            [&](const Global& x){return x.name==name&&x.fromInclude;});
        if(git!=globals.end())globals.erase(git);
    }
    void parse(){
        while(cur().k!=TK::End){
            if(eat(TK::Include)){includeDirective();continue;}
            if(eat(TK::Struct)){structDeclaration();continue;}
            if(eat(TK::Let)){globalDeclaration(false);continue;}
            if(cur().k==TK::Extern&&t[p+1].k==TK::Let){++p;eat(TK::Let);globalDeclaration(true);continue;}
            Function f;f.external=eat(TK::Extern);
            f.line=cur().line;f.col=cur().col;   // v0.23.12-dev: the `fn` token, for the prologue row
            need(TK::Fn,"expected fn");f.name=functionName();
            need(TK::LParen,"expected '(' after function name");
            if(cur().k!=TK::RParen){do{
                auto id=need(TK::Ident,"expected parameter name");need(TK::Colon,"expected ':' after parameter name");
                std::vector<uint32_t> pd;
                const Ty pty=arrayParamType(&pd);
                f.paramTypes.push_back(pty);
                // v0.23.37-dev: a fn-pointer parameter keeps its signature
                // beside the ptr storage type, so a call through it can be
                // checked and staged by the signature.
                if(pendingFuncType){f.paramFuncSig.push_back(pendingFuncSig);f.paramIsFunc.push_back(true);pendingFuncType=false;pendingFuncSig=FuncSig();}
                else{f.paramFuncSig.push_back(FuncSig());f.paramIsFunc.push_back(false);}
                f.paramPtr.push_back(pty.k==Ty::Ptr);f.paramBool.push_back(pty==Ty::Bool);
                f.paramDims.push_back(pd);
                for(const auto& old:f.params)if(old==id.s)throw Error("duplicate parameter name in function "+f.name+": "+id.s);
                f.params.push_back(id.s);
                if(f.params.size()>32)throw Error("functions support at most 32 parameters: "+f.name);
            }while(eat(TK::Comma));}
            need(TK::RParen,"expected ')' after parameters");
            need(TK::Arrow,"expected ->");
            const Ty rty=needType(kTypeExpected);
            // v0.23.38-dev: a function may return a fn-pointer. The return
            // type is still `ptr` — an address comes back, not a function
            // value — and the signature travels beside it, the same way it
            // does beside a ptr parameter. That is what lets `return inc;`
            // inside `fn get() -> fn(i32) -> i32` be checked, and what tells
            // a `let f: fn(i32) -> i32 = get();` what it is holding.
            if(pendingFuncType){f.returnFuncSig=pendingFuncSig;f.returnIsFunc=true;pendingFuncType=false;pendingFuncSig=FuncSig();}
            // v0.23.34-dev: a function cannot return an array. C refuses it
            // for the reason Aster has to: a return value travels in the
            // registers one value fits in, and an array is not one value. The
            // parser used to stop at the `[` with "expected '{'", which names
            // the token it wanted and not the thing that is wrong — so say
            // what an array-returning function should do instead, which is
            // the same two answers a pointer parameter accepts.
            if(cur().k==TK::LBracket)
                throw Error(loc(cur().line,cur().col,"a function cannot return an array: return ptr<"+tyNameFull(rty)
                                +">, or take the array as a parameter and let the caller's storage be written through"));
            f.retType=rty;f.returnPtr=(rty==Ty::Ptr);f.returnBool=(rty==Ty::Bool);
            if(f.name=="main"&&rty!=Ty::I32)throw Error("main must return i32");
            if(f.external)need(TK::Semi,"expected ';' after extern function declaration");
            else {f.body=block();if(f.body.empty())throw Error("function body cannot be empty: "+f.name);}
        for(const auto& old:functions)if(old.name==f.name){
            if(!old.fromInclude)throw Error("duplicate function declaration: "+f.name);
            dropIncluded(f.name);break;   // this file's own definition wins
        }
        functions.push_back(std::move(f));
        }
        if(requireMain)for(const auto& f:functions)if(f.name=="main"&&!f.external&&!f.params.empty())throw Error("main must not have parameters");
        for(const auto& g:globals)for(const auto& f:functions)if(g.name==f.name)throw Error("global variable conflicts with function: "+g.name);
    }
};
// ---------------------------------------------------------------------------
// Shared helpers: constant folding and comparison classification.
//
// These used to live inside Codegen, but v0.23.0-dev (P3.1) runs a semantic
// pass *before* any code is emitted, and that pass must decide the very same
// questions -- "does this index fold to a constant?" and "is this a
// comparison?" -- using the very same rules. Keeping one definition means the
// two passes can never drift apart.
// ---------------------------------------------------------------------------
// Constant folding for compile-time array bounds checks: literals and the
// +,-,*,/ combinations of them — plus, since v0.23.17-dev, `%`, the shifts
// and the bitwise operators, so `buf[(1 << 3) | 1]` is checked like `buf[9]`.
// Overflow, division by zero, and anything else (variables, calls,
// dereferences) simply do not fold, leaving the index unchecked at run time.
static bool constantInteger(const Expr& e,int64_t& out){
    int64_t a=0,b=0;
    switch(e.k){
        // v0.23.25-dev: a bool literal is not an integer constant. Folding it
        // to 0/1 here would let `let x: i32 = true;` and `a[true]` through the
        // constant paths, which is exactly the interchangeability the type
        // system forbids; the bool-specific readers test boolLit directly.
        case Expr::Num: if(e.boolLit)return false; out=static_cast<int64_t>(e.n); return true;
        case Expr::SizeOf: case Expr::Len: out=static_cast<int64_t>(e.n); return true;   // v0.23.35-dev
        case Expr::Neg:
            if(!constantInteger(*e.a,a)||a==INT64_MIN)return false;
            out=-a;return true;
        case Expr::Add:
            if(!constantInteger(*e.a,a)||!constantInteger(*e.b,b))return false;
            return !__builtin_add_overflow(a,b,&out);
        case Expr::Sub:
            if(!constantInteger(*e.a,a)||!constantInteger(*e.b,b))return false;
            return !__builtin_sub_overflow(a,b,&out);
        case Expr::Mul:
            if(!constantInteger(*e.a,a)||!constantInteger(*e.b,b))return false;
            return !__builtin_mul_overflow(a,b,&out);
        case Expr::Div:
            if(!constantInteger(*e.a,a)||!constantInteger(*e.b,b)||b==0||(a==INT64_MIN&&b==-1))return false;
            out=a/b;return true;
        case Expr::Mod:
            if(!constantInteger(*e.a,a)||!constantInteger(*e.b,b)||b==0||(a==INT64_MIN&&b==-1))return false;
            out=a%b;return true;
        case Expr::BitAnd:
            if(!constantInteger(*e.a,a)||!constantInteger(*e.b,b))return false;
            out=a&b;return true;
        case Expr::BitOr:
            if(!constantInteger(*e.a,a)||!constantInteger(*e.b,b))return false;
            out=a|b;return true;
        case Expr::BitXor:
            if(!constantInteger(*e.a,a)||!constantInteger(*e.b,b))return false;
            out=a^b;return true;
        case Expr::BitNot:
            if(!constantInteger(*e.a,a))return false;
            out=~a;return true;
        // A shift is the one operator here whose count is not part of the
        // result's type, and whose C semantics are undefined past the width;
        // refuse to fold an out-of-range count rather than pick a meaning.
        case Expr::Shl: case Expr::Shr: {
            if(!constantInteger(*e.a,a)||!constantInteger(*e.b,b)||b<0||b>63)return false;
            if(e.k==Expr::Shl){
                if(__builtin_mul_overflow(a,(int64_t)1<<b,&out))return false;
                return true;
            }
            out=a>>b;return true;
        }
        default:return false;
    }
}
// The value a bool array is filled with: the `true`/`false` literal, or the
// 0/1 integer constant a bool slot has always accepted. constantInteger folds
// the second and deliberately refuses the first (v0.23.25-dev), so the two
// spellings are read here — the same pair a bool scalar accepts — and the
// range check is left to initializerFits, which is what says `= 2` does not
// fit instead of pretending the initializer was not constant.
static bool boolArrayValue(const Expr& e,int64_t& out){
    if(e.k==Expr::Num&&e.boolLit){out=static_cast<int64_t>(e.n);return true;}
    return constantInteger(e,out);
}
// A comparison, a && / || / ! combination, or a bool-typed value is a bool
// expression. Comparisons produce 0/1 through CSET; a bool variable holds an
// i32 whose truthiness is tested against 0, so no normalization is required.
static bool isComparison(Expr::Kind k){
    return k==Expr::Eq||k==Expr::Ne||k==Expr::Lt||k==Expr::Le||k==Expr::Gt||k==Expr::Ge;
}
// v0.23.26-dev: the null pointer constant. The literal `0` is Aster's spelling
// of a null `ptr` — as in C, and for the same reason: an address has no
// arithmetic relationship to an integer, but a program has to be able to say
// "nothing here". It may initialize, be assigned to, be passed to and be
// returned from a ptr, and it is the only integer a ptr may be compared with.
// `false` is a Bool literal whose value is also 0, so the boolLit flag must be
// consulted: a bool is not an address, and never was.
static bool isNullConstant(const Expr& e){return e.k==Expr::Num&&!e.boolLit&&e.n==0;}
// Usual arithmetic conversion for the integer types: equal types keep their own
// width (u8 + u8 wraps at 256), a 64-bit operand wins, and a mixed pair widens
// to 32 bits taking the unsigned reading when either side is unsigned.
static Ty promoteInt(Ty a,Ty b){
    if(a==b)return a;
    if(tyIs64(a)||tyIs64(b))return Ty::I64;
    return (tyIsUnsigned(a)||tyIsUnsigned(b))?Ty::U32:Ty::I32;
}
// May a value of type `from` be stored into a slot of type `to`?
//
//   * the same type always may;
//   * a folded constant takes on the target type, range-checked by
//     initializerFits (this is what lets `let b: u8 = 200;` and
//     `let q: i64 = 3000000000;` through while rejecting `let b: u8 = 300;`);
//   * i32 and u32 interconvert, sharing one 32-bit representation;
//   * a narrower integer widens losslessly to a wider one;
//   * everything else — narrowing a value, mixing in a bool or a pointer — is
//     an error. Aster has no cast expressions, so there is no way to ask for a
//     truncation, and silently dropping bits would be a bug in the program.
static bool tyAssignable(Ty to,Ty from,const Expr& e){
    if(to==from)return true;
    // v0.23.26-dev: the null pointer constant is the one integer a ptr slot
    // accepts. Everything else about pointers is unchanged — no cast, no
    // truncation, no address arithmetic into a value.
    if(to==Ty::Ptr)return isNullConstant(e);
    int64_t v=0;
    if(constantInteger(e,v))return tyIsInteger(to)&&initializerFits(to,e,v);
    if(!tyIsInteger(to)||!tyIsInteger(from))return false;
    if(to==Ty::I64)return true;                     // every integer widens to i64
    const uint32_t wt=tySize(to),wf=tySize(from);
    if(wt<wf)return false;                          // narrowing
    if(wt==wf)return (to==Ty::I32&&from==Ty::U32)||(to==Ty::U32&&from==Ty::I32)||(to==Ty::U32&&tyIsUnsigned(from));
    return true;                                    // u8/u16 -> wider: zero-extension is lossless
}
// AArch64 condition code for a comparison: eq, ne, lt, le, gt, ge. The ordered
// comparisons have two spellings — LO/LS/HI/HS compare the operands as unsigned
// values, LT/LE/GT/GE as signed ones (v0.23.2-dev). eq/ne do not care.
static int comparisonCond(Expr::Kind k,bool unsignedCompare=false){
    switch(k){
        case Expr::Eq: return 0;
        case Expr::Ne: return 1;
        case Expr::Lt: return unsignedCompare?3:11;   // LO : LT
        case Expr::Le: return unsignedCompare?9:13;   // LS : LE
        case Expr::Gt: return unsignedCompare?8:12;   // HI : GT
        default:       return unsignedCompare?2:10;   // HS : GE
    }
}
// Name of the GOT-style address slot that stands in for a global in shared-object output.
std::string gatSymbol(const std::string& n){return "__aster_gat_"+n;}
// v0.23.32-dev: one entry per parameter and per local slot, collected while a
// function is compiled and carried out to the object's .debug_info. `slot` is
// the whole address: every local is fbreg(slot*8) from the function's frame
// base, and a local array's base slot is the address its name decays to.
struct DebugVar {
    std::string name;
    Ty ty=Ty::I32;                 // the scalar's own type, or an array's element type
    int slot=0;
    bool isParam=false;
    bool isArray=false;
    std::vector<uint32_t> dims;    // outermost first; empty for a scalar
    unsigned line=0;
};
struct Codegen {
    struct Reloc { uint64_t offset; std::string symbol; uint32_t type; };
    std::vector<uint32_t> code;
    std::vector<Reloc> relocations;
    std::string functionName; bool isMain=false; bool currentReturnPtr=false; bool currentReturnBool=false; Ty currentReturnType=Ty::I32;
    const std::map<std::string,size_t>& functionArities;
    const std::set<std::string>& globals;
    const std::set<std::string>& externGlobals;
    const std::set<std::string>& externFunctions;
    const std::set<std::string>& arrayGlobals;
    const std::set<std::string>& boolGlobals;              // globals declared `let g: bool`
    const std::set<std::string>& pointerFunctions;
    const std::set<std::string>& pointerReturnFunctions;
    const std::set<std::string>& boolReturnFunctions;      // functions declared `-> bool`
    const std::map<std::string,std::vector<bool>>& functionParamPointers;
    const std::map<std::string,std::vector<bool>>& functionParamBools;   // per-parameter bool flags
    const std::map<std::string,uint32_t>& arrayLengths;   // declared lengths of fixed-size global arrays (incl. extern declarations)
    // v0.23.31-dev: the full dimension list of every file-scope array,
    // outermost first. `arrayLengths` answers only the outer length — all a
    // one-dimensional array ever needed — while a subscript on a subscript
    // needs the inner ones too, for both the stride and the bound.
    const std::map<std::string,std::vector<uint32_t>>& globalArrayDims;
    // v0.23.2-dev (P3.2): declared types. These used to be a pile of booleans
    // (boolGlobals, functionParamPointers, functionParamBools, pointerReturn-
    // Functions, boolReturnFunctions); the maps below carry the same facts plus
    // the new widths. They are filled in by compileProgram right after
    // construction, which keeps the constructor's parameter list unchanged.
    std::map<std::string,Ty> globalTypes;                 // global name -> type (element type for an array)
    std::map<std::string,std::vector<Ty>> argTypes;       // function name -> parameter types
    std::map<std::string,Ty> returnTypes;                 // function name -> return type
    // v0.23.37-dev: the signature of every fn-pointer global, so a call
    // through a global callee can be checked and staged like a typed one.
    std::map<std::string,FuncSig> globalFuncSig;
    std::map<int,Ty> slotTypes;                           // frame slot -> declared type
    // v0.23.37-dev: a fn-pointer local/parameter carries its signature beside
    // the storage type Ty::Ptr, keyed by its frame slot; slotIsFunc marks which
    // slots those are (a plain ptr slot is absent from both).
    std::map<int,FuncSig> slotFuncSig;
    std::map<int,bool> slotIsFunc;
    std::map<int,Ty> slotElemTypes;                       // frame slot -> element type of a local array
    bool shared=false;
    bool injectInit=false;
    std::string initSymbol;
    int callDepth=0;
    // --bounds-check: emit a run-time range test before every dynamic index
    // into a fixed-size array. Off by default, so an ordinary build emits the
    // same bytes it always did.
    bool boundsCheck=false;
    // -g / --debug-line: record, at every statement boundary, the instruction
    // index it starts at together with the source line it came from. Off by
    // default, so an ordinary build collects nothing and emits the bytes it
    // always did. The rows are turned into a DWARF .debug_line table at emit
    // time; they never influence instruction selection.
    bool emitLineInfo=false;
    struct LineRow { uint32_t ins; uint32_t line; };
    std::vector<LineRow> lineRows;
    // v0.23.32-dev: the same gate, and the same reason — only a -g build pays
    // for the names and types, and they never influence instruction selection.
    std::vector<DebugVar> debugVars;
    Codegen(std::string name,const std::map<std::string,size_t>& arities,const std::set<std::string>& globalNames,
            const std::set<std::string>& externalGlobals,const std::set<std::string>& externalFunctions,
            const std::set<std::string>& arrayNames,const std::set<std::string>& pointerFunctionNames,
            const std::set<std::string>& pointerReturnFunctionNames,const std::map<std::string,std::vector<bool>>& paramPointerMap,
            const std::set<std::string>& boolGlobalNames,const std::set<std::string>& boolReturnFunctionNames,
            const std::map<std::string,std::vector<bool>>& paramBoolMap,
            const std::map<std::string,uint32_t>& arrayLengthMap,
            const std::map<std::string,std::vector<uint32_t>>& arrayDimsMap,
            bool sharedObject,bool injectInitCall,std::string initSym,bool runtimeBoundsCheck=false,bool debugLine=false)
        :functionName(std::move(name)),isMain(functionName=="main"&&!sharedObject),functionArities(arities),globals(globalNames),
         externGlobals(externalGlobals),externFunctions(externalFunctions),arrayGlobals(arrayNames),boolGlobals(boolGlobalNames),
         pointerFunctions(pointerFunctionNames),
         pointerReturnFunctions(pointerReturnFunctionNames),boolReturnFunctions(boolReturnFunctionNames),
         functionParamPointers(paramPointerMap),functionParamBools(paramBoolMap),arrayLengths(arrayLengthMap),
         globalArrayDims(arrayDimsMap),
         shared(sharedObject),
         injectInit(injectInitCall),initSymbol(std::move(initSym)),boundsCheck(runtimeBoundsCheck),emitLineInfo(debugLine) {}
    std::vector<std::map<std::string,int>> scopes;
    std::map<int,bool> pointerSlots;
    std::map<int,bool> boolSlots;              // frame slots holding a bool (stored as a 4-byte i32 0/1)
    std::map<int,uint32_t> localArrayLength;   // frame slot -> element count for local i32[N] arrays
    // v0.23.31-dev: frame slot -> the local array's dimension list. A
    // one-dimensional array's list has one entry, equal to the length above;
    // a two-dimensional one's first entry is the outer length (which is what
    // the length above carries) and the rest are what a second subscript
    // needs. Only multi-dimensional arrays are ever looked up here — the
    // one-dimensional paths read the length and stop.
    std::map<int,std::vector<uint32_t>> slotDims;
    // v0.23.36-dev: frame slot -> total element count of an ARRAY PARAMETER.
    // Deliberately NOT localArrayLength: gen(Var) keys off localArrayLength.count(slot)
    // to decide whether a bare `a` is the array's own address (local) or the caller's
    // pointer value (parameter, which decays). Putting a parameter here would make `a`
    // resolve to the frame slot instead of the array the caller passed — a silent
    // semantic break. This map is consulted only by the bounds-check sites.
    std::map<int,uint32_t> paramArrayLength;
    int nextSlot=0, nextTemp=0;
    // continue sites are patched after the body: a while loop sends them back
    // to the condition, a for loop to its step (see Stmt::For).
    struct LoopContext { size_t start; std::vector<size_t> breaks; std::vector<size_t> continues; };
    std::vector<LoopContext> loops;
    static constexpr int kMaxLocals=500;
    static constexpr int kMaxTemps=16;
    // R_AARCH64_ADR_PREL_PG_HI21 / R_AARCH64_ADD_ABS_LO12_NC / R_AARCH64_CALL26
    static constexpr uint32_t kRelAdrp=275, kRelAddLo=277, kRelCall26=283;
    // x16 (IP0) is reserved for global-address materialization; expression temporaries use w0-w15.
    static constexpr int kGlobalBase=16;

    void emit(uint32_t x){code.push_back(x);}
    int temp(){if(nextTemp>=kMaxTemps)throw Error("expression too complex: temporary register limit exceeded");return nextTemp++;}
    void releaseTemp(int r){
        if(r!=nextTemp-1)throw Error("internal compiler error: temporary registers released out of order");
        --nextTemp;
    }
    int lookup(const std::string& name) const {
        for(auto it=scopes.rbegin();it!=scopes.rend();++it){
            auto found=it->find(name);
            if(found!=it->end())return found->second;
        }
        return -1;
    }
    static uint32_t loadLocal(int reg,int slot){
        if(slot<0||slot>=2048)throw Error("internal compiler error: invalid frame slot");
        return 0xb94003e0u|(uint32_t(slot)<<10)|uint32_t(reg); // LDR Wt, [SP, #slot*4]
    }
    static uint32_t storeLocal(int reg,int slot){
        if(slot<0||slot>=2048)throw Error("internal compiler error: invalid frame slot");
        return 0xb90003e0u|(uint32_t(slot)<<10)|uint32_t(reg); // STR Wt, [SP, #slot*4]
    }
    static uint32_t loadVar32(int reg,int slot){
        if(slot<0||slot>=kMaxLocals)throw Error("internal compiler error: invalid variable slot");
        return 0xb94003e0u|(uint32_t(slot*2)<<10)|uint32_t(reg); // LDR Wt, [SP, #slot*8]
    }
    static uint32_t storeVar32(int reg,int slot){
        if(slot<0||slot>=kMaxLocals)throw Error("internal compiler error: invalid variable slot");
        return 0xb90003e0u|(uint32_t(slot*2)<<10)|uint32_t(reg); // STR Wt, [SP, #slot*8]
    }
    static uint32_t loadVar64(int reg,int slot){
        if(slot<0||slot>=kMaxLocals)throw Error("internal compiler error: invalid variable slot");
        return 0xf94003e0u|(uint32_t(slot)<<10)|uint32_t(reg); // LDR Xt, [SP, #slot*8]
    }
    static uint32_t storeVar64(int reg,int slot){
        if(slot<0||slot>=kMaxLocals)throw Error("internal compiler error: invalid variable slot");
        return 0xf90003e0u|(uint32_t(slot)<<10)|uint32_t(reg); // STR Xt, [SP, #slot*8]
    }
    // Narrow and wide load/store forms (v0.23.2-dev). LDRB/LDRH zero-extend a
    // 1-/2-byte memory value into a W register; STRB/STRH write the low 1/2
    // bytes. The 64-bit forms are the ones pointers already used.
    //
    // The unsigned immediate is scaled by the access size on every form except
    // the byte ones: LDRB/STRB take an unscaled byte offset, but LDRH/STRH
    // encode bytes/2, and the 32-/64-bit forms bytes/4 and bytes/8. Getting a
    // scale wrong silently moves the access to a neighbouring slot, so the
    // scaling is written out at each site (all four verified against GAS).
    static uint32_t loadVar8(int reg,int slot){
        if(slot<0||slot>=kMaxLocals)throw Error("internal compiler error: invalid variable slot");
        return 0x394003e0u|(uint32_t(slot*8)<<10)|uint32_t(reg); // LDRB Wt, [SP, #slot*8]
    }
    static uint32_t loadVar16(int reg,int slot){
        if(slot<0||slot>=kMaxLocals)throw Error("internal compiler error: invalid variable slot");
        return 0x794003e0u|(uint32_t(slot*4)<<10)|uint32_t(reg); // LDRH Wt, [SP, #slot*8] (imm = bytes/2)
    }
    static uint32_t storeVar8(int reg,int slot){
        if(slot<0||slot>=kMaxLocals)throw Error("internal compiler error: invalid variable slot");
        return 0x390003e0u|(uint32_t(slot*8)<<10)|uint32_t(reg); // STRB Wt, [SP, #slot*8]
    }
    static uint32_t storeVar16(int reg,int slot){
        if(slot<0||slot>=kMaxLocals)throw Error("internal compiler error: invalid variable slot");
        return 0x790003e0u|(uint32_t(slot*4)<<10)|uint32_t(reg); // STRH Wt, [SP, #slot*8] (imm = bytes/2)
    }
    // One entry point per access, chosen by the declared type of the slot or
    // global: every new width is handled here and nowhere else.
    static uint32_t loadVarT(int reg,int slot,Ty t){
        if(tyIs64(t))return loadVar64(reg,slot);
        if(t==Ty::U8)return loadVar8(reg,slot);
        if(t==Ty::U16)return loadVar16(reg,slot);
        return loadVar32(reg,slot);
    }
    static uint32_t storeVarT(int reg,int slot,Ty t){
        if(tyIs64(t))return storeVar64(reg,slot);
        if(t==Ty::U8)return storeVar8(reg,slot);
        if(t==Ty::U16)return storeVar16(reg,slot);
        return storeVar32(reg,slot);
    }
    // The declared type of a frame slot (a parameter, a local, or — for a local
    // array — the ptr that is its frame address).
    Ty slotType(int slot) const {
        auto it=slotTypes.find(slot);
        return it==slotTypes.end()?Ty::I32:it->second;
    }
    // The element type of an indexable name: a local T[N], a fixed-size global,
    // a pointer slot's element, or i32 for `p[i]` on an untyped ptr (the
    // existing one-i32-stride behaviour).
    Ty elementTypeOf(const std::string& name) const {
        const int slot=lookup(name);
        if(slot>=0){
            auto it=slotElemTypes.find(slot);
            if(it!=slotElemTypes.end())return it->second;
            // v0.23.34-dev: a ptr<S> indexes at sizeof(S), the same stride
            // emitElemAddr gives it, so `p[1].a` on a ptr<V3> reads the field
            // of the second V3 and not of the i32 four bytes in.
            const Ty st=slotType(slot);
            if(tyIsPtrToStruct(st))return Ty::ofStruct(st.sid);
            return Ty::I32;
        }
        auto it=globalTypes.find(name);
        return it==globalTypes.end()?Ty::I32:it->second;
    }
    // v0.23.29-dev: `arrayFieldOf` (a free function just above structFieldOf)
    // tells a struct array field element access `s.xs[i]` apart from a plain
    // scalar/struct field access and from a named-array Index (whose base is
    // the index expression, never a Field). It is defined outside this class
    // because both Sema and Codegen need it.
    Ty globalTypeOf(const std::string& name) const {
        auto it=globalTypes.find(name);
        return it==globalTypes.end()?Ty::I32:it->second;
    }
    Ty returnTypeOf(const std::string& name) const {
        auto it=returnTypes.find(name);
        return it==returnTypes.end()?Ty::I32:it->second;
    }
    // up through the scope stack, so shadowing picks the innermost declaration)
    // or a fixed-size global. Returns 0 when the name is not a known array.
    uint32_t arrayLengthOf(const std::string& name) const {
        const int slot=lookup(name);
        if(slot>=0){auto it=localArrayLength.find(slot);return it==localArrayLength.end()?0:it->second;}
        auto length=arrayLengths.find(name);
        return length==arrayLengths.end()?0:length->second;
    }
    // Reject constant out-of-bounds indexes before code generation. The
    // length-taking overload is the one the field-array sites call; the
    // name-taking overload looks the length up for a named array.
    void checkArrayBounds(uint32_t length,const Expr& index){
        if(!length)return;
        int64_t value=0;if(!constantInteger(index,value))return;
        if(value<0||static_cast<uint64_t>(value)>=length)
            throw Error(loc(index.line,index.col,"array index out of bounds: index "+std::to_string(value)+", length "+std::to_string(length)));
    }
    // v0.23.31-dev: the dimension list of a named array — a local's frame
    // slots or a global's declaration — or null when the name is not a
    // fixed-length array (a scalar, a ptr), which is every shape its callers
    // have already refused with a message of their own.
    const std::vector<uint32_t>* arrayDimsOf(const std::string& name) const {
        const int slot=lookup(name);
        if(slot>=0){
            auto it=slotDims.find(slot);
            return it==slotDims.end()?nullptr:&it->second;
        }
        auto it=globalArrayDims.find(name);
        return it==globalArrayDims.end()?nullptr:&it->second;
    }
    // v0.23.31-dev: what a subscript chain says about the array it starts
    // from — the twin of Sema's indexChainOf, so codegen's answers cannot
    // drift from the ones the type pass verified. `a[i][j]` parses as an
    // Index whose left side is itself an Index (the name rides on the
    // innermost node), so the level of a node is the number of subscripts
    // below it: the base's own subscript is level 0, and `dims[level]` is
    // the bound it is checked against.
    struct IndexChain {
        const std::vector<uint32_t>* dims=nullptr;
        Ty elem=Ty::I32;
        unsigned level=0;
    };
    bool indexChainOf(const Expr& e,IndexChain& out) const {
        const Expr* n=&e;
        unsigned level=0;
        while(n->k==Expr::Index&&n->name.empty()&&n->a->k==Expr::Index){n=n->a.get();++level;}
        if(n->k!=Expr::Index)return false;
        if(!n->name.empty()){
            const std::vector<uint32_t>* d=arrayDimsOf(n->name);
            if(!d)return false;
            out.dims=d;out.elem=elementTypeOf(n->name);out.level=level;return true;
        }
        if(n->a->k!=Expr::Field)return false;
        const StructField* f=arrayFieldOf(exprType(*n->a->a),*n->a);
        if(!f||f->dims.empty())return false;
        out.dims=&f->dims;out.elem=f->ty;out.level=level;return true;
    }
    // v0.23.31-dev: the name a subscript chain starts from — the array's, or
    // for a struct array field the field's — which is what the innermost node
    // carries. Only for diagnostics that spell the target out.
    std::string chainBaseName(const Expr& e) const {
        const Expr* n=&e;
        while(n->k==Expr::Index&&n->name.empty()&&n->a->k==Expr::Index)n=n->a.get();
        if(n->k!=Expr::Index)return "";
        return n->name.empty()?n->a->name:n->name;
    }
    void checkArrayBounds(const std::string& name,const Expr& index){
        checkArrayBounds(arrayLengthOf(name),index);
    }
    // Run-time range test for an index whose value is not a compile-time
    // constant. One unsigned comparison covers both halves of the range: a
    // negative index is a huge unsigned value, so `CMP widx, #len` followed by
    // `B.LO` (unsigned <) skips the trap for index < 0 and index >= len alike.
    //
    //   CMP widx, #len        ; SUBS WZR, widx, #len — flags only
    //   B.LO  skip            ; unsigned < len: in range, jump over the trap
    //   BRK #1                ; out of range: SIGTRAP
    // skip:
    //
    // The branch must jump *over* the BRK, not to it: the trap sits on the
    // fall-through path, so branching to it would trap on every index.
    // Constant indexes are skipped: checkArrayBounds already proved them in
    // range, so turning the flag on never changes the bytes of a program that
    // only ever indexes with literals.
    void emitBoundsCheck(uint32_t length,const Expr& index,int idxReg){
        if(!boundsCheck)return;
        if(!length)return;                       // pointer index or an array of unknown extent
        int64_t folded=0;
        if(constantInteger(index,folded))return; // compile-time check already covers it
        if(length>0xfffu)throw Error("array is too long for --bounds-check: length "+std::to_string(length)+" exceeds the 4095 compare-immediate limit");
        emit(cmpImm(idxReg,length));
        size_t at=code.size();emit(0);
        emit(brk(1));
        patchCond(at,3,(int)code.size());        // 3 = LO/CC: unsigned < length, skip the trap
    }
    void emitBoundsCheck(const std::string& name,const Expr& index,int idxReg){
        emitBoundsCheck(arrayLengthOf(name),index,idxReg);
    }
    // The type of an expression, from the declared types of the slots, globals
    // and signatures in scope. v0.23.2-dev folds the old `exprIsPtr` and
    // `exprIsBool` questions into this one function: "is it a pointer?" is
    // `t == Ptr`, "is it a bool?" is `t == Bool`, and "which instruction
    // width?" falls out of the same answer. One definition means the three
    // questions can never disagree.
    Ty exprType(const Expr& e) const {
        switch(e.k){
            case Expr::Num: return e.boolLit?Ty::Bool:Ty::I32;   // a literal takes on the type its context asks for — but true/false are bool, not the integers 0/1 (v0.23.25-dev)
            case Expr::String: return Ty::Ptr;   // a string literal is its rodata address
            case Expr::Embed: return Ty::Ptr;    // @embed is likewise the address of its bytes
            case Expr::SizeOf: case Expr::Len: return Ty::I32;   // v0.23.35-dev: a folded compile-time i32 constant
            case Expr::Var: {
                const int slot=lookup(e.name);
                if(slot>=0){
                    if(localArrayLength.count(slot))return Ty::Ptr;   // decays to its frame address
                    return slotType(slot);
                }
                if(arrayGlobals.count(e.name))return Ty::Ptr;         // likewise for a global array
                if(globalTypes.count(e.name))return globalTypes.at(e.name);
                // A non-extern function name in a non-call position is its address (ptr).
                if(functionArities.count(e.name)&&!externFunctions.count(e.name))return Ty::Ptr;
                return Ty::I32;
            }
            case Expr::Call: return callType(e);
            // v0.23.38-dev: `h.onClick(x)` answers its field's return type,
            // the same way a call through a typed fn-pointer variable does.
            case Expr::FieldCall: return fieldCallType(e);
            case Expr::Index: {
                // v0.23.31-dev: a subscript on a subscript — `a[i][j]`,
                // `s.xs[i][j]` — answers a row address (a ptr) or the element
                // type, exactly as sema's Index case decides from the same
                // dimension list. One function answering "which dimension
                // does this subscript address?" keeps the two passes from
                // disagreeing about what a chain denotes.
                IndexChain ch;
                if(indexChainOf(e,ch))
                    return ch.level+1<ch.dims->size()?Ty::Ptr:ch.elem;
                // v0.23.29-dev: a struct array field element's type is the
                // field's element type. A `[` after a non-array field is
                // rejected here so it never reaches code generation.
                if(e.a->k==Expr::Field){
                    const StructField* af=arrayFieldOf(exprType(*e.a->a),*e.a);
                    if(af)return af->ty;
                    throw Error("cannot index non-array field: "+e.a->name);
                }
                // v0.23.34-dev: a typed pointer to array elements — `p[i]` is
                // the element, scaled at the element's real width.
                {
                    const Ty at=exprType(*e.a);
                    if(tyIsPtrToElem(at))return ptrElemType(at);
                }
                if(exprType(*e.a)==Ty::Ptr)throw Error("pointer indexing is not supported yet");
                return elementTypeOf(e.name);
            }
            case Expr::Deref: {
                // *(p) reads one i32 as before — unless p is a ptr<S>, in
                // which case it is the struct itself.
                const Ty inner=exprType(*e.a);
                return tyIsPtrToStruct(inner)?Ty::ofStruct(inner.sid):Ty::I32;
            }
            case Expr::Field: {
                const Ty base=exprType(*e.a);
                const StructField* f=structFieldOf(base,e.name);
                return f?f->ty:Ty::I32;              // an unknown field: reported where it is used
            }
            case Expr::AddrOf: {
                const Ty inner=exprType(*e.a);
                if(tyIsStruct(inner))return Ty::ptrTo(inner.sid);
                // v0.23.34-dev: the address of a whole array is a pointer to
                // its first element, at the element's real width (no longer
                // restricted to 4-byte elements).
                if(e.a->k==Expr::Var&&arrayLengthOf(e.a->name)>0)
                    return tyPtrToElem(elementTypeOf(e.a->name));
                return Ty::Ptr;
            }
            case Expr::StructLit: {
                auto it=g_structIndex.find(e.name);
                return it==g_structIndex.end()?Ty::I32:Ty::ofStruct(it->second);
            }
            case Expr::Neg: {
                const Ty a=exprType(*e.a);
                if(a==Ty::Ptr)throw Error("pointer arithmetic is not supported yet");
                return tyIsInteger(a)?a:Ty::I32;
            }
            case Expr::Add: {
                const Ty a=exprType(*e.a),b=exprType(*e.b);
                if(a==Ty::Ptr&&b==Ty::Ptr)throw Error(loc(e.line,e.col,"invalid pointer arithmetic: ptr + ptr is not supported"));
                if(a==Ty::Ptr||b==Ty::Ptr)return Ty::Ptr;   // ptr +/- i32 stays ptr
                return promoteInt(a,b);
            }
            case Expr::Sub: {
                const Ty a=exprType(*e.a),b=exprType(*e.b);
                if(a==Ty::Ptr&&b!=Ty::Ptr)return Ty::Ptr;
                if(a==Ty::Ptr||b==Ty::Ptr)throw Error(loc(e.line,e.col,"invalid pointer arithmetic: expected ptr - i32"));
                return promoteInt(a,b);
            }
            case Expr::Mul: case Expr::Div: {
                const Ty a=exprType(*e.a),b=exprType(*e.b);
                // Scaling an address is meaningless, but earlier releases
                // accepted it and produced an i32; keep that shape rather than
                // adding a rejection a working program might trip over.
                if(a==Ty::Ptr||b==Ty::Ptr)return Ty::I32;
                return promoteInt(a,b);
            }
            // v0.23.17-dev (round 1). `%` follows Mul/Div (integer promotion,
            // unsigned picks UDIV). A shift takes the left operand's type and
            // ignores the right's — the count is not part of the value type,
            // which is also what makes `u8 << 24` a u8. The bitwise operators
            // promote like the arithmetic ones. `~` keeps its operand's type.
            case Expr::Mod: {
                const Ty a=exprType(*e.a),b=exprType(*e.b);
                if(a==Ty::Ptr||b==Ty::Ptr)return Ty::I32;   // Sema rejects this; keep the old shape here
                return promoteInt(a,b);
            }
            case Expr::Shl: case Expr::Shr: return exprType(*e.a);
            case Expr::BitAnd: case Expr::BitOr: case Expr::BitXor:
                return promoteInt(exprType(*e.a),exprType(*e.b));
            case Expr::BitNot: return exprType(*e.a);
            case Expr::Cond: return exprType(*e.b);   // Sema has already required both arms to agree
            default: return Ty::Bool;   // comparisons and && / || / !
        }
    }
    // The type a call yields. The byte-memory intrinsics are i32 in and i32 out
    // except load_ptr, which yields an address; everything else comes from the
    // function's declared return type. An indirect call (v0.23.24-dev) — the
    // callee is a ptr variable, so there is no declaration to read — answers
    // i32, exactly like the undeclared-name fallthrough below, which is where
    // it lands: no signature exists, so none is consulted.
    Ty callType(const Expr& e) const {
        // A user-defined function of this name shadows the intrinsic — a
        // program that defined its own `load_ptr` before the intrinsic
        // existed must keep compiling, and "user code wins" is the only rule
        // that guarantees it. Same guard in checkCall and gen below.
        if(e.name=="load_ptr"&&!functionArities.count(e.name))return Ty::Ptr;
        // v0.23.41-dev: the heap intrinsics answer an address, the only calls
        // besides load_ptr that do. Codegen's exprType reads the answer here,
        // so without this a `let heap: ptr = mmap(...)` declaration is typed
        // i32 and refused as a mismatch — Sema's checkCall answers Ptr, and
        // the two passes must not disagree about what a call yields.
        if((e.name=="mmap"||e.name=="brk")&&!functionArities.count(e.name))return Ty::Ptr;
        // The quadword intrinsics are i64 in and i64 out (v0.23.23-dev). The
        // halfword pair answers i32 in and i32 out, exactly like the byte
        // pair, and therefore shares the fallthrough below.
        if((e.name=="load_i64"||e.name=="store_i64")&&!functionArities.count(e.name))return Ty::I64;
        // v0.23.37-dev: a call through a typed fn-pointer answers its declared
        // return type; a bare ptr still falls through to the i32 default.
        if(!functionArities.count(e.name)){
            if(const FuncSig* fs=funcSigOf(e.name))return fs->ret;
        }
        if(!functionArities.count(e.name))return Ty::I32;  // undeclared: reported when the call is emitted
        return returnTypeOf(e.name);
    }
    // v0.23.38-dev: what `h.onClick(x)` answers — the return type of the
    // field's declared signature, and nothing else. There is no name here to
    // look up or to be shadowed by, which is the whole reason a call through a
    // field is its own expression kind. Sema has already refused a field with
    // no function type, so the fallthrough is unreachable in a program that
    // compiles.
    Ty fieldCallType(const Expr& e) const {
        const FuncSig* fs=fieldSigOf(e);
        return fs?fs->ret:Ty::I32;
    }
    // v0.23.38-dev: the declared signature of the field a FieldCall reads, or
    // null when the field has no function type. One answer, read by both the
    // type question above and the emission below, so the two cannot disagree
    // about what `h.onClick(x)` is.
    const FuncSig* fieldSigOf(const Expr& e) const {
        const Expr& field=*e.a;
        const Ty base=exprType(*field.a);
        const StructField* f=structFieldOf(base,field.name);
        return (f&&f->isFunc)?&f->funcSig:nullptr;
    }
    // v0.23.24-dev: does this name denote a ptr variable an indirect call can
    // branch through? A local or a global *scalar* of type ptr — never an
    // array (its name is its address, and branching to data is not a thing),
    // never a narrower or composite type. The same three-question resolution
    // Sema's checkCall performs; gen repeats it because codegen emits what it
    // verified itself, never what another pass promised.
    bool indirectCallee(const std::string& name) const {
        const int slot=lookup(name);
        if(slot>=0)return !localArrayLength.count(slot)&&slotType(slot)==Ty::Ptr;
        return globals.count(name)&&!arrayGlobals.count(name)&&globalTypeOf(name)==Ty::Ptr;
    }
    // v0.23.37-dev: the signature of a fn-pointer name, or null for a bare ptr
    // (which keeps the legacy untyped indirect-call behaviour). Mirrors Sema's
    // resolver: a local/parameter reads slotFuncSig by its frame slot; a global
    // reads globalFuncSig by name.
    const FuncSig* funcSigOf(const std::string& name) const {
        const int slot=lookup(name);
        if(slot>=0){
            auto it=slotIsFunc.find(slot);
            if(it!=slotIsFunc.end()&&it->second){
                auto s=slotFuncSig.find(slot);
                if(s!=slotFuncSig.end())return &s->second;
            }
            return nullptr;
        }
        auto it=globalFuncSig.find(name);
        if(it!=globalFuncSig.end())return &it->second;
        return nullptr;
    }
    bool exprIsPtr(const Expr& e) const { return exprType(e)==Ty::Ptr; }
    bool exprIsBool(const Expr& e) const { return exprType(e)==Ty::Bool; }
    // A bool slot may also be initialized from the literal 0 or 1 (there is no
    // other way to spell a bool constant); any other constant is rejected.
    bool isBoolConstant(const Expr& e) const {
        int64_t v=0;
        return constantInteger(e,v)&&(v==0||v==1);
    }
    // CSET Wd, <cond>: materializes 1 when cond holds, 0 otherwise. The hardware
    // evaluates the condition-select family as (cond ? Wn : Wm+1), so the assembler
    // stores cond^1. Rn = Rm = WZR (31) spans bits 9-5, so the low three bits
    // (0xe0) belong to the base word — dropping them would materialize the
    // result from whatever register 24 happens to hold instead of zero.
    static uint32_t csetBool(int reg,int cond){return 0x1a9f07e0u|(uint32_t(cond^1)<<12)|uint32_t(reg);}
    // CMP Wn, #0 — SUBS with Rd = WZR so the subtraction is discarded and only
    // the flags survive. Rd is bits 4-0: leaving it at 0 encodes
    // `subs w0, Wn, #0`, which silently overwrites w0 (a live expression
    // temporary) with Wn's value. The bug was invisible in the && / || shape
    // because the clobbered value is immediately recomputed, but it is wrong:
    // `cmp w1, #0` is what the comment always claimed.
    static uint32_t cmpZero(int reg){return 0x71000000u|(uint32_t(reg)<<5)|31u;}
    // CMP Xn, #0 — the 64-bit spelling (sf = 1), for an i64 condition tested
    // against zero. Same discard-the-result shape as cmpZero; a separate
    // helper so the 32-bit encoding keeps its own home and its own guard.
    static uint32_t cmpZeroX(int reg){return 0xf1000000u|(uint32_t(reg)<<5)|31u;}
    // CMP Wn, #imm — same encoding with a 12-bit immediate.
    static uint32_t cmpImm(int reg,uint32_t imm){return 0x71000000u|((imm&0xfffu)<<10)|(uint32_t(reg)<<5)|31u;}
    // BRK #imm: #1 (not the #0 a debugger plants) marks an Aster bounds trap.
    // Linux turns it into SIGTRAP, which a plain run under qemu reports as a
    // deterministic exit status instead of silent memory corruption.
    static uint32_t brk(uint32_t imm){return 0xd4200000u|((imm&0xffffu)<<5);}
    static uint32_t movInt(int reg,uint32_t value){return 0x52800000u|((value&0xffffu)<<5)|uint32_t(reg);}
    // MOVZ/MOVK into an X register: a 64-bit constant takes up to four 16-bit
    // pieces, each MOVK shifting its piece into place (hw = 1/2/3 for bits
    // 16-31, 32-47 and 48-63). A literal in Aster source is at most 0xffffffff,
    // so in practice two instructions suffice; the rest are there so the
    // helper is correct for any value a folded expression can produce.
    // Materialize a full 64-bit literal with MOVZ (low 16 bits) + MOVK (the
    // three higher 16-bit chunks). The MOVK base MUST be the hw=0 (lsl #0)
    // form 0xf2800000: the hw shift lives in bits [22:21], so adding
    // (1<<21)/(2<<21)/(3<<21) yields lsl #16/#32/#48. The earlier 0xf2a00000
    // base had hw=1 (lsl #16) baked in, which pushed every chunk one shift too
    // far — the v>>32 chunk landed at lsl #48 and corrupted every i64 literal
    // wider than 32 bits (verified against aarch64 GAS: 0xf2800020/0xf2a00020/
    // 0xf2c00020/0xf2e00020 for lsl #0/#16/#32/#48).
    void emitMov64(int reg,uint64_t v){
        emit(0xd2800000u|((v&0xffffu)<<5)|uint32_t(reg));                      // MOVZ Xd, #imm16
        if(v>>16)emit(0xf2800000u|(1u<<21)|(((v>>16)&0xffffu)<<5)|uint32_t(reg));
        if(v>>32)emit(0xf2800000u|(2u<<21)|(((v>>32)&0xffffu)<<5)|uint32_t(reg));
        if(v>>48)emit(0xf2800000u|(3u<<21)|(((v>>48)&0xffffu)<<5)|uint32_t(reg));
    }
    // -----------------------------------------------------------------------
    // v0.23.18-dev (round 2): the width rules that make i64 arithmetic agree
    // with C. All three grow out of one fact — a literal's static type is
    // always I32 ("a literal takes on the type its context asks for"), so its
    // *value* and its *consumer* each have to be consulted separately.
    //
    // (1) A constant operand whose value does not fit in 32 bits forces the
    //     operation to 64 bits: C types such a constant as long, whatever the
    //     consumer does with the result. `-900000000000` reaches the parser
    //     as Neg(Num), so the sign is peeled off before the magnitude is
    //     tested — and -2147483648, which does fit, must not trip it.
    static bool constExceedsI32(const Expr& e){
        const Expr* p=&e; bool neg=false;
        if(p->k==Expr::Neg){ neg=true; p=p->a.get(); }
        if(!p||p->k!=Expr::Num)return false;
        return neg ? (p->n>0x80000000ull) : (p->n>0x7fffffffull);
    }
    // (2) Widening an operand is the operand's own job, never the consumer's.
    //     Generating an expression with want=I64 already leaves a full 64-bit
    //     value in its register: a literal materializes at full width
    //     (emitMov64), an i32 local/field/element/dereference sign-extends on
    //     load, a call result is sign-extended on return, `-x` uses the 64-bit
    //     SUB form, and a nested arithmetic operation ran at 64 bits because
    //     rule (3) includes tyIs64(want). A consumer that sign-extends again
    //     after the fact is therefore wrong twice over: it truncates every
    //     wide sub-expression (which is how `-9223372036854775807-1` on the
    //     right of `==` came back unequal to the same expression on the left)
    //     and it corrupts a literal that was materialized full width. The
    //     comparison paths did exempt a bare literal from this the day the
    //     exemption was written; round 2 removes the extension instead, so the
    //     exemption no longer has to guess which operands are constants.
    // (3) An operation runs at 64 bits when the context asks for i64, when
    //     either operand is i64, or when a constant operand does not fit in
    //     32 bits. Deriving it from `want` alone dropped the high word of an
    //     i64 operand whenever the result was consumed as i32 — which is how
    //     `return x % 7` came back as 1 for x = 4294967297.
    static bool wideOp(Ty want,Ty ta,Ty tb,const Expr& a,const Expr& b){
        return tyIs64(want)||tyIs64(ta)||tyIs64(tb)||constExceedsI32(a)||constExceedsI32(b);
    }
    // Load/store between a register and the global whose address sits in x16.
    static uint32_t loadGlobalT(int reg,Ty t){
        if(t==Ty::U8) return 0x39400000u|(uint32_t(kGlobalBase)<<5)|uint32_t(reg);   // LDRB Wt, [X16]
        if(t==Ty::U16)return 0x79400000u|(uint32_t(kGlobalBase)<<5)|uint32_t(reg);   // LDRH Wt, [X16]
        if(tyIs64(t)) return 0xf9400000u|(uint32_t(kGlobalBase)<<5)|uint32_t(reg);   // LDR  Xt, [X16]
        return loadGlobal(reg);
    }
    static uint32_t storeGlobalT(int reg,Ty t){
        if(t==Ty::U8) return 0x39000000u|(uint32_t(kGlobalBase)<<5)|uint32_t(reg);   // STRB Wt, [X16]
        if(t==Ty::U16)return 0x79000000u|(uint32_t(kGlobalBase)<<5)|uint32_t(reg);   // STRH Wt, [X16]
        if(tyIs64(t)) return 0xf9000000u|(uint32_t(kGlobalBase)<<5)|uint32_t(reg);   // STR  Xt, [X16]
        return storeGlobal(reg);
    }
    // Same choice for an arbitrary byte offset from SP (argument scratch slots
    // and array elements), where the offset is not on the slot grid.
    static uint32_t loadStackT(int reg,uint32_t off,Ty t){
        if(tyIs64(t))return 0xf94003e0u|((off/8)<<10)|uint32_t(reg);
        if(t==Ty::U8) return 0x394003e0u|(off<<10)|uint32_t(reg);
        if(t==Ty::U16)return 0x794003e0u|((off/2)<<10)|uint32_t(reg);
        return 0xb94003e0u|((off/4)<<10)|uint32_t(reg);
    }
    static uint32_t storeStackT(int reg,uint32_t off,Ty t){
        if(tyIs64(t))return 0xf90003e0u|((off/8)<<10)|uint32_t(reg);
        if(t==Ty::U8) return 0x390003e0u|(off<<10)|uint32_t(reg);
        if(t==Ty::U16)return 0x790003e0u|((off/2)<<10)|uint32_t(reg);
        return 0xb90003e0u|((off/4)<<10)|uint32_t(reg);
    }
    // ----------------------------------------------------------------------
    // The AArch64 unsigned immediate offset is width-scaled, so its RANGE is
    // different for every width: LDRB/STRB carry the byte offset UNSCALED in
    // 12 bits (0..4095), LDRH/STRH scale by 2 (0..8190, even offsets only),
    // LDR/STR W by 4 (0..16380, 4-byte aligned) and LDR/STR X by 8 (0..32760,
    // 8-byte aligned). An offset past the range is not rejected and does not
    // simply wrap onto a neighbouring byte: bit 12 of an unscaled byte offset
    // lands on bit 22 of the instruction, which is exactly the bit separating
    // STRB (0x39000000) from LDRB (0x39400000) — so storeStackT(v, 4160, U8)
    // emitted a *load* at offset 64.
    //
    // Every call argument is staged in the scratch area at 4160 +
    // callDepth*256, which is past 4095, so this was not a corner case: the
    // caller stored a u8 argument by loading it, and handed the callee
    // whatever the uninitialized stack held. `fn g(a: u8) -> u8 { return a; }`
    // called as g(200) returned 0, and had never returned anything else — a
    // u8 parameter had not worked since it was introduced in v0.23.2-dev,
    // while u8 locals, globals, array elements and struct fields (all at small
    // offsets) were correct, which is what made it look like an ABI problem.
    //
    // u16 survived only by arithmetic: 4160/2 == 2080 fits, and even the
    // deepest scratch (4160 + 14*256 + 31*8 == 7992) is 3996 after the shift.
    // Struct fields cannot reach it either — a struct is capped at 1024 bytes.
    // ----------------------------------------------------------------------
    static bool stackOffFits(uint32_t off,Ty t){
        if(t==Ty::U8) return off<=4095u;                     // unscaled 12 bits
        if(t==Ty::U16)return off<=8190u&&(off&1u)==0u;       // imm12 << 1
        if(tyIs64(t)) return off<=32760u&&(off&7u)==0u;      // imm12 << 3
        return off<=16380u&&(off&3u)==0u;                    // imm12 << 2
    }
    // Load/store at [SP + off], falling back to a base register when the
    // offset does not fit the width's immediate range. x16 is the global base
    // and is clobbered freely between accesses — except when it is itself the
    // destination, in which case x17 (the struct-address scratch) carries the
    // address instead. That is a convenience on the load side (x16 would hold
    // the address only until the next instruction consumed it) but load-bearing
    // on the store side, where staging through x16 would overwrite the value
    // about to be stored. A fitting offset takes the encoding it always did,
    // so no pre-existing output changes by a byte.
    void loadStackOff(int reg,uint32_t off,Ty t){
        if(stackOffFits(off,t)){emit(loadStackT(reg,off,t));return;}
        if(reg==kGlobalBase){emitAddOff(17,31,off);emit(loadAtT(reg,17,0,t));return;}
        emitAddOff(kGlobalBase,31,off);emit(loadGlobalT(reg,t));
    }
    void storeStackOff(int reg,uint32_t off,Ty t){
        if(stackOffFits(off,t)){emit(storeStackT(reg,off,t));return;}
        if(reg==kGlobalBase){emitAddOff(17,31,off);emit(storeAtT(reg,17,0,t));return;}
        emitAddOff(kGlobalBase,31,off);emit(storeGlobalT(reg,t));
    }
    // An incoming stack argument (the 9th and later): its 8-byte slot is
    // addressed through X16 (X16 = SP + 8192) and the load width follows the
    // declared parameter type. i32/ptr keep the exact forms they used before
    // the v0.23.2 type lattice, so every pre-existing example is unchanged.
    static uint32_t loadIncomingArgT(uint32_t off,Ty t){
        if(tyIs64(t))return 0xf9400210u|((off/8)<<10);          // LDR  X16, [X16, #off]
        if(t==Ty::U8) return 0x39400000u|(off<<10)|0x210u;      // LDRB W16, [X16, #off]
        if(t==Ty::U16)return 0x79400000u|((off/2)<<10)|0x210u;  // LDRH W16, [X16, #off]
        return 0xb9400210u|((off/4)<<10);                       // LDR  W16, [X16, #off]
    }
    // ADRP x16, symbol ; ADD x16, x16, :lo12:symbol
    // In shared-object mode the symbol is the global's GOT-style address slot: the ADRP/ADD pair
    // targets the slot and one extra LDR X16, [X16] loads the load-time address the dynamic loader
    // stored there through the slot's R_AARCH64_RELATIVE relocation.
    void emitGlobalAddress(const std::string& name){
        const std::string target=shared?gatSymbol(name):name;
        size_t adrp=code.size();emit(0x90000000u|(uint32_t(kGlobalBase)));relocations.push_back({uint64_t(adrp)*4,target,kRelAdrp});
        size_t add=code.size();emit(0x91000000u|(uint32_t(kGlobalBase)<<5)|uint32_t(kGlobalBase));relocations.push_back({uint64_t(add)*4,target,kRelAddLo});
        if(shared)emit(0xf9400210u); // LDR X16, [X16]
    }
    static uint32_t loadGlobal(int reg){return 0xb9400000u|(uint32_t(kGlobalBase)<<5)|uint32_t(reg);} // LDR Wt, [X16]
    static uint32_t storeGlobal(int reg){return 0xb9000000u|(uint32_t(kGlobalBase)<<5)|uint32_t(reg);} // STR Wt, [X16]
    // Emit `e` and return the temporary register holding it.
    //
    // `want` is the type the caller is going to store the result into. It only
    // steers arithmetic: a literal and every 32-bit value already sit in a W
    // register whose upper half is zero, so the same materialization works for
    // both widths, but `i32 * i32` stored into an i64 slot has to be a 64-bit
    // multiply or the product wraps at 2^32. Comparisons ignore it — they
    // materialize a bool.
    // v0.23.40-dev: emit a raw Linux AArch64 system call (SVC #0, x8 = num) with
    // zero libc dependency — the same mechanism `write` uses. `args` are the
    // call's argument expressions in x0..xn order, `tys` their declared types
    // (I32 or Ptr). Every live temporary is parked in the frame first, the
    // arguments are generated and staged through the scratch grid exactly like a
    // call's argument sequence, loaded into x0..xn, x8 is set to the syscall
    // number, and the i32 result is read from w0. A system call preserves every
    // register but x0, so only the argument staging needs saving — this mirrors
    // the `write` intrinsic at 0.23.21-dev line-for-line so the two stay in
    // lockstep.
    int syscallInsn(int num, const std::vector<std::unique_ptr<Expr>>& args, const std::vector<Ty>& tys, Ty resultTy=Ty::I32){
        const int live=nextTemp;
        for(int r=0;r<live;++r)emit(storeLocal(r,1020+r));
        const uint32_t scratchByte=4160u+uint32_t(callDepth)*256u;++callDepth;
        for(size_t i=0;i<args.size();++i){
            int v=gen(*args[i],tys[i]);
            storeStackOff(v,scratchByte+uint32_t(i)*8u,tys[i]);
            releaseTemp(v);
        }
        --callDepth;
        // Allocate every destination temporary up front (r0..rn distinct) and
        // only then load them — releasing between iterations would make temp()
        // hand back the same register each time, so loading argument i would
        // clobber x0/x1/… already staged for an earlier argument. `write` relies
        // on exactly this distinctness; x0/x1/x2 are the pool's first temporaries.
        std::vector<int> rs(args.size());
        for(size_t i=0;i<args.size();++i)rs[i]=temp();
        for(size_t i=0;i<args.size();++i)
            loadStackOff(rs[i],scratchByte+uint32_t(i)*8u,tys[i]);
        for(size_t i=0;i<args.size();++i){
            // An i64 argument rides at full width exactly like a ptr does —
            // staging it through W would silently truncate a length or an
            // offset above 4 GiB (mmap's second and sixth arguments,
            // v0.23.41-dev; every argument before that round was at most a
            // ptr or an i32, so the ptr test used to be enough).
            const uint32_t mov=tyIs64(tys[i])?0xaa0003e0u:0x2a0003e0u; // MOV X (64-bit) / MOV W (32-bit)
            emit(mov|(uint32_t(rs[i])<<16)|uint32_t(i));               // MOV Xi, Xri
        }
        for(int i=int(rs.size())-1;i>=0;--i)releaseTemp(rs[i]); // release top-down: releaseTemp is strict LIFO
        emit(0xd2800000u|(uint32_t(num)<<5)|8u); // MOV X8, #num
        emit(0xd4000001u);                        // SVC #0
        // The result width follows the intrinsic's answer. A byte count lives
        // in w0 and reads as an i32, but mmap/brk answer an address — reading
        // it through W would hand back 0x00000000_7fxxxxxx and every later
        // access through that pointer would fault (v0.23.41-dev).
        int d=temp();emit((tyIs64(resultTy)?0xaa0003e0u:0x2a0003e0u)|uint32_t(d)); // MOV (X|W)d, (X|W)0
        for(int r=live-1;r>=0;--r)emit(loadLocal(r,1020+r));
        return d;
    }
    int gen(const Expr& e,Ty want=Ty::I32){
        switch(e.k){
            case Expr::String:{emitGlobalAddress(e.name);int d=temp();emit(0xaa1003e0u|uint32_t(d));return d;}
            // @embed: the same thing as a string literal — the address of a
            // rodata object — without the NUL the literal owns.
            case Expr::Embed:{emitGlobalAddress(e.name);int d=temp();emit(0xaa1003e0u|uint32_t(d));return d;}
            case Expr::Num:{
                int d=temp();uint64_t n=e.n;
                // A literal in an i64 context is materialized at full width:
                // the 32-bit MOVZ/MOVK pair would sign-extend through the
                // constant folder's int64 view and turn 3000000000 negative.
                if(tyIs64(want)){emitMov64(d,n);return d;}
                emit(0x52800000u|((n&0xffffu)<<5)|uint32_t(d));
                if(n>>16)emit(0x72a00000u|(((n>>16)&0xffffu)<<5)|uint32_t(d));
                return d;
            }
            case Expr::SizeOf: case Expr::Len: {
                // v0.23.35-dev: a folded i32 constant, materialised exactly
                // like Num — the value already lives in e.n.
                int d=temp();uint64_t n=e.n;
                if(tyIs64(want)){emitMov64(d,n);return d;}
                emit(0x52800000u|((n&0xffffu)<<5)|uint32_t(d));
                if(n>>16)emit(0x72a00000u|(((n>>16)&0xffffu)<<5)|uint32_t(d));
                return d;
            }
            case Expr::Var:{
                int slot=lookup(e.name);
                if(slot>=0){
                    // A local array name decays to its frame address (ptr), like a global array.
                    if(localArrayLength.count(slot)){
                        int d=temp();
                        // ADD Xd, SP, #slot*8 — the 0x91.. base keeps the sh bit (bit 22) at 0.
                        // With sh=1 (0x91 4 00000) the imm12 field is scaled by 4096, which is
                        // invisible while the array sits in slot 0 (offset 0) and writes far
                        // outside the 8 KiB frame for any other slot.
                        emit(0x91000000u|(uint32_t(slot*8)<<10)|(31u<<5)|uint32_t(d));
                        return d;
                    }
                    if(tyIsStruct(slotType(slot)))
                        throw Error("cannot use a whole struct as a value: '"+e.name+"' (read its fields, or pass &"+e.name+")");
                    int d=temp();emit(loadVarT(d,slot,slotType(slot)));
                    // An i32 local widening into an i64 context must be sign-extended, or a
                    // negative value becomes a huge unsigned i64. The unsigned widths already
                    // zero-extend into the full X register through their load form.
                    if(tyIs64(want)&&slotType(slot)==Ty::I32)emit(0x93407c00u|(uint32_t(d)<<5)|uint32_t(d));
                    return d;
                }
                if(globals.count(e.name)){
                    if(arrayGlobals.count(e.name)){int d=temp();emitGlobalAddress(e.name);emit(0xaa1003e0u|uint32_t(d));return d;}
                    if(tyIsStruct(globalTypeOf(e.name)))
                        throw Error("cannot use a whole struct as a value: '"+e.name+"' (read its fields, or pass &"+e.name+")");
                    emitGlobalAddress(e.name);int d=temp();emit(loadGlobalT(d,globalTypeOf(e.name)));
                    if(tyIs64(want)&&globalTypeOf(e.name)==Ty::I32)emit(0x93407c00u|(uint32_t(d)<<5)|uint32_t(d));
                    return d;
                }
                // A non-extern function name in a non-call position is its address (ptr):
                // the shared-object loader fills a GOT-style slot (R_AARCH64_RELATIVE) with the
                // run-time function address, so a callback table can be populated at runtime.
                if(functionArities.count(e.name)&&!externFunctions.count(e.name)){
                    emitGlobalAddress(e.name);int d=temp();emit(0xaa1003e0u|uint32_t(d));return d;
                }
                throw Error(loc(e.line,e.col,"unknown variable: "+e.name));
            }
            // v0.23.38-dev: `h.onClick(x)` — the call through a fn-pointer
            // field. The field's signature stages the arguments and names the
            // result, and the branch is a BLR through the value the field
            // holds; emitCallSeq reads that value at the branch itself, since
            // the struct address it needs (X16) does not survive the staging.
            case Expr::FieldCall:{
                const FuncSig* fs=fieldSigOf(e);
                int d=emitCallSeq(e,fs,0,0,true);
                // A 32-bit return read at 64-bit width is sign-extended, as it
                // is for a direct call and for a call through a fn-pointer
                // variable: AAPCS64 leaves the upper half of X0 unspecified.
                if(fs&&tyIs64(want)&&fs->ret==Ty::I32)emit(0x93407c00u|(uint32_t(d)<<5)|uint32_t(d));
                return d;
            }
            case Expr::Call:{
                // load_ptr(ptr) loads an 8-byte pointer from memory and yields a ptr value,
                // so code can read a function pointer or a window-buffer pointer stored in memory.
                // A user-defined function shadows the intrinsic (see checkCall):
                // the name is answered by the program's own definition when it
                // has one, and by the intrinsic only when it does not.
                if(e.name=="load_ptr"&&!functionArities.count(e.name)){
                    if(e.args.size()!=1)throw Error(loc(e.line,e.col,"load_ptr expects exactly one ptr argument"));;
                    if(!exprIsPtr(*e.args[0]))throw Error(loc(e.line,e.col,"load_ptr expects a ptr argument"));
                    int a=gen(*e.args[0]);
                    emit(0xf9400000u|(uint32_t(a)<<5)|uint32_t(a)); // LDR Xa, [Xa]
                    return a;
                }
                // Byte memory intrinsics: load_u8(ptr) zero-extends one byte to i32;
                // store_u8(ptr, i32) writes the low 8 bits and returns the original i32.
                if(e.name=="load_u8"&&!functionArities.count(e.name)){
                    if(e.args.size()!=1)throw Error(loc(e.line,e.col,"load_u8 expects exactly one ptr argument"));
                    if(!exprIsPtr(*e.args[0]))throw Error(loc(e.line,e.col,"load_u8 expects a ptr argument"));
                    int a=gen(*e.args[0]);
                    emit(0x39400000u|(uint32_t(a)<<5)|uint32_t(a)); // LDRB Wa, [Xa]
                    return a;
                }
                if(e.name=="store_u8"&&!functionArities.count(e.name)){
                    if(e.args.size()!=2)throw Error(loc(e.line,e.col,"store_u8 expects (ptr, i32)"));
                    if(!exprIsPtr(*e.args[0]))throw Error(loc(e.line,e.col,"store_u8 first argument must be ptr"));
                    if(exprIsPtr(*e.args[1]))throw Error(loc(e.line,e.col,"store_u8 second argument must be i32"));
                    int v=gen(*e.args[1]);int a=gen(*e.args[0]);
                    emit(0x39000000u|(uint32_t(a)<<5)|uint32_t(v)); // STRB Wv, [Xa]
                    releaseTemp(a);
                    return v;
                }
                // Halfword memory intrinsics (v0.23.23-dev): load_u16(ptr)
                // zero-extends one halfword to i32 — the byte pair's exact
                // shape one width up, and LDRH is the instruction that does
                // it; store_u16(ptr, i32) writes the low 16 bits and returns
                // the original i32, as store_u8 does for the low 8.
                if(e.name=="load_u16"&&!functionArities.count(e.name)){
                    if(e.args.size()!=1)throw Error(loc(e.line,e.col,"load_u16 expects exactly one ptr argument"));
                    if(!exprIsPtr(*e.args[0]))throw Error(loc(e.line,e.col,"load_u16 expects a ptr argument"));
                    int a=gen(*e.args[0]);
                    emit(0x79400000u|(uint32_t(a)<<5)|uint32_t(a)); // LDRH Wa, [Xa]
                    return a;
                }
                if(e.name=="store_u16"&&!functionArities.count(e.name)){
                    if(e.args.size()!=2)throw Error(loc(e.line,e.col,"store_u16 expects (ptr, i32)"));
                    if(!exprIsPtr(*e.args[0]))throw Error(loc(e.line,e.col,"store_u16 first argument must be ptr"));
                    if(exprIsPtr(*e.args[1]))throw Error(loc(e.line,e.col,"store_u16 second argument must be i32"));
                    int v=gen(*e.args[1]);int a=gen(*e.args[0]);
                    emit(0x79000000u|(uint32_t(a)<<5)|uint32_t(v)); // STRH Wv, [Xa]
                    releaseTemp(a);
                    return v;
                }
                // Quadword memory intrinsics (v0.23.23-dev): load_i64(ptr)
                // yields the full 64-bit value; store_i64(ptr, i64) writes
                // eight bytes and returns the original. An i32 value widens
                // by sign-extension — gen(..., Ty::I64) applies exactly the
                // rule storing it into an i64 local would, so a negative i32
                // does not become a huge unsigned quadword on the way to
                // memory. That is the difference between this intrinsic and
                // the eight-load_u8 shift-and-or it replaces, where `<< 32`
                // on an i32 silently drops the high half (32-bit arithmetic).
                if(e.name=="load_i64"&&!functionArities.count(e.name)){
                    if(e.args.size()!=1)throw Error(loc(e.line,e.col,"load_i64 expects exactly one ptr argument"));
                    if(!exprIsPtr(*e.args[0]))throw Error(loc(e.line,e.col,"load_i64 expects a ptr argument"));
                    int a=gen(*e.args[0]);
                    emit(0xf9400000u|(uint32_t(a)<<5)|uint32_t(a)); // LDR Xa, [Xa]
                    return a;
                }
                if(e.name=="store_i64"&&!functionArities.count(e.name)){
                    if(e.args.size()!=2)throw Error(loc(e.line,e.col,"store_i64 expects (ptr, i64)"));
                    if(!exprIsPtr(*e.args[0]))throw Error(loc(e.line,e.col,"store_i64 first argument must be ptr"));
                    if(exprIsPtr(*e.args[1]))throw Error(loc(e.line,e.col,"store_i64 second argument must be i64"));
                    if(exprIsBool(*e.args[1]))throw Error(loc(e.line,e.col,"store_i64 second argument must be i64"));
                    int v=gen(*e.args[1],Ty::I64);int a=gen(*e.args[0]);
                    emit(0xf9000000u|(uint32_t(a)<<5)|uint32_t(v)); // STR Xv, [Xa]
                    releaseTemp(a);
                    return v;
                }
                // write(fd, buf, len) — v0.23.21-dev: one write(2) system call,
                // x8 = 64, arguments in x0/x1/x2, the count in x0. `main`'s
                // return already exits through a system call (x8 = 93); this is
                // the same idea on the output side, and it is what lets an ELF
                // program print without libc — build-elf stays static and
                // self-contained, and the .so path keeps libc for the Android
                // host. Like the byte intrinsics, the value is i32 in and i32
                // out: MOV Wd, W0 leaves the upper half zero, and the count is
                // never negative, so widening it later cannot diverge.
                //
                // The arguments are staged in the frame's scratch grid first,
                // exactly as emitCallSeq stages a call's, and only then loaded
                // into x0/x1/x2. That is not decoration: x0/x1/x2 ARE the first
                // three temporaries of the w0–w15 pool, so moving an argument
                // into its syscall register and releasing its temporary lets
                // the next argument's gen reuse that very register and
                // overwrite what was just placed — fd moved to x0 and freed,
                // then buf's gen taking w0 for its own, is how the first cut
                // of this intrinsic called write(buf_as_fd, ...) and got EBADF.
                if(e.name=="write"&&!functionArities.count(e.name)){
                    if(e.args.size()!=3)throw Error(loc(e.line,e.col,"write expects (fd: i32, buf: ptr, len: i32)"));
                    if(exprIsPtr(*e.args[0]))throw Error(loc(e.line,e.col,"write first argument must be i32"));
                    if(!exprIsPtr(*e.args[1]))throw Error(loc(e.line,e.col,"write second argument must be ptr"));
                    if(exprIsPtr(*e.args[2]))throw Error(loc(e.line,e.col,"write third argument must be i32"));
                    // The syscall registers x0/x1/x2 are the pool's first three
                    // temporaries, and loading them is exactly what a call's
                    // argument sequence does to them — so the write borrows the
                    // call's discipline wholesale: park every live temporary in
                    // the frame (the same save area emitCallSeq uses), stage and
                    // move the arguments, run the syscall, and bring the parked
                    // values back before handing out the result. Two failures
                    // taught this shape. First cut moved fd into x0 and freed
                    // its temporary, so the next argument's gen reused w0 and
                    // the syscall ran with the buffer as the fd (EBADF).
                    // Second cut staged through the stack but loaded straight
                    // into x0, clobbering the surrounding expression's own w0 —
                    // `total = total + write(...)` summed the byte count with
                    // itself. A syscall preserves every register but x0, so the
                    // only damage is the argument loading itself.
                    const int live=nextTemp;
                    for(int r=0;r<live;++r)emit(storeLocal(r,1020+r));
                    static const Ty wts[3]={Ty::I32,Ty::Ptr,Ty::I32};
                    const uint32_t woff[3]={0,8,16};
                    const int scratchByte=4160+callDepth*256;++callDepth;
                    for(int i=0;i<3;++i){
                        int v=gen(*e.args[i],wts[i]);
                        storeStackOff(v,uint32_t(scratchByte+woff[i]),wts[i]);
                        releaseTemp(v);
                    }
                    --callDepth;
                    int r0=temp(),r1=temp(),r2=temp();
                    loadStackOff(r0,uint32_t(scratchByte+woff[0]),Ty::I32); // LDR Wr0 = fd
                    loadStackOff(r1,uint32_t(scratchByte+woff[1]),Ty::Ptr); // LDR Xr1 = buf
                    loadStackOff(r2,uint32_t(scratchByte+woff[2]),Ty::I32); // LDR Wr2 = len
                    emit(0x2a0003e0u|(uint32_t(r0)<<16));       // MOV W0, Wr0
                    emit(0xaa0003e0u|(uint32_t(r1)<<16)|1u);    // MOV X1, Xr1
                    emit(0xaa0003e0u|(uint32_t(r2)<<16)|2u);    // MOV X2, Wr2 (upper half zero)
                    releaseTemp(r2);releaseTemp(r1);releaseTemp(r0);
                    emit(0xd2800000u|(64u<<5)|8u);             // MOV X8, #64
                    emit(0xd4000001u);                          // SVC #0
                    int d=temp();emit(0x2a0003e0u|uint32_t(d));// MOV Wd, W0 — bytes written
                    for(int r=live-1;r>=0;--r)emit(loadLocal(r,1020+r));
                    return d;
                }
                // v0.23.40-dev: raw system-call intrinsics (zero libc). Each
                // mirrors `write` — dispatched only when the program has not
                // defined its own function of that name — and funnels through
                // syscallInsn above. read(2)/openat(2)/close(2)/fstat(2) are the
                // minimum a self-hosting compiler needs to pull source bytes in
                // and emit an ELF out; output already rides `write`. NOTE these
                // are AArch64 syscall numbers (asm-generic): there is no plain
                // `open` on aarch64 — 56 is `openat(dirfd, path, flags, mode)`,
                // and `fstat` is 80 (79 is `newfstatat`). `main`'s exit at 93 and
                // `write` at 64 already pin this numbering.
                if(e.name=="read"&&!functionArities.count(e.name)){
                    if(e.args.size()!=3)throw Error(loc(e.line,e.col,"read expects (fd: i32, buf: ptr, len: i32)"));
                    if(exprIsPtr(*e.args[0]))throw Error(loc(e.line,e.col,"read first argument must be i32"));
                    if(!exprIsPtr(*e.args[1]))throw Error(loc(e.line,e.col,"read second argument must be ptr"));
                    if(exprIsPtr(*e.args[2]))throw Error(loc(e.line,e.col,"read third argument must be i32"));
                    return syscallInsn(63,e.args,std::vector<Ty>{Ty::I32,Ty::Ptr,Ty::I32});
                }
                if(e.name=="openat"&&!functionArities.count(e.name)){
                    if(e.args.size()!=4)throw Error(loc(e.line,e.col,"openat expects (fd: i32, path: ptr, flags: i32, mode: i32)"));
                    if(exprIsPtr(*e.args[0]))throw Error(loc(e.line,e.col,"openat first argument must be i32"));
                    if(!exprIsPtr(*e.args[1]))throw Error(loc(e.line,e.col,"openat second argument must be ptr"));
                    if(exprIsPtr(*e.args[2]))throw Error(loc(e.line,e.col,"openat third argument must be i32"));
                    if(exprIsPtr(*e.args[3]))throw Error(loc(e.line,e.col,"openat fourth argument must be i32"));
                    return syscallInsn(56,e.args,std::vector<Ty>{Ty::I32,Ty::Ptr,Ty::I32,Ty::I32});
                }
                if(e.name=="close"&&!functionArities.count(e.name)){
                    if(e.args.size()!=1)throw Error(loc(e.line,e.col,"close expects (fd: i32)"));
                    if(exprIsPtr(*e.args[0]))throw Error(loc(e.line,e.col,"close argument must be i32"));
                    return syscallInsn(57,e.args,std::vector<Ty>{Ty::I32});
                }
                if(e.name=="fstat"&&!functionArities.count(e.name)){
                    if(e.args.size()!=2)throw Error(loc(e.line,e.col,"fstat expects (fd: i32, buf: ptr)"));
                    if(exprIsPtr(*e.args[0]))throw Error(loc(e.line,e.col,"fstat first argument must be i32"));
                    if(!exprIsPtr(*e.args[1]))throw Error(loc(e.line,e.col,"fstat second argument must be ptr"));
                    return syscallInsn(80,e.args,std::vector<Ty>{Ty::I32,Ty::Ptr});
                }
                // v0.23.41-dev: the heap. mmap(2) at 222 answers a bare ptr (the
                // one syscall whose result is an address, so syscallInsn reads
                // it at 64-bit width) and brk(2) at 214 answers the new break
                // as a ptr. AArch64 numbering again: 222/214 are the
                // asm-generic numbers, the same table exit/write/read already
                // pinned. Six arguments is the widest any of these intrinsics
                // carries; the staging discipline above is unchanged — all six
                // destination temporaries are allocated up front and distinct,
                // then loaded, then released top-down.
                if(e.name=="mmap"&&!functionArities.count(e.name)){
                    if(e.args.size()!=6)throw Error(loc(e.line,e.col,"mmap expects (addr: ptr, length: i64, prot: i32, flags: i32, fd: i32, offset: i64)"));
                    if(!exprIsPtr(*e.args[0]))throw Error(loc(e.line,e.col,"mmap first argument must be ptr"));
                    if(exprIsPtr(*e.args[1]))throw Error(loc(e.line,e.col,"mmap second argument must be i64"));
                    if(exprIsPtr(*e.args[2]))throw Error(loc(e.line,e.col,"mmap third argument must be i32"));
                    if(exprIsPtr(*e.args[3]))throw Error(loc(e.line,e.col,"mmap fourth argument must be i32"));
                    if(exprIsPtr(*e.args[4]))throw Error(loc(e.line,e.col,"mmap fifth argument must be i32"));
                    if(exprIsPtr(*e.args[5]))throw Error(loc(e.line,e.col,"mmap sixth argument must be i64"));
                    return syscallInsn(222,e.args,std::vector<Ty>{Ty::Ptr,Ty::I64,Ty::I32,Ty::I32,Ty::I32,Ty::I64},Ty::Ptr);
                }
                if(e.name=="brk"&&!functionArities.count(e.name)){
                    if(e.args.size()!=1)throw Error(loc(e.line,e.col,"brk expects (addr: ptr)"));
                    if(!exprIsPtr(*e.args[0]))throw Error(loc(e.line,e.col,"brk argument must be ptr"));
                    return syscallInsn(214,e.args,std::vector<Ty>{Ty::Ptr},Ty::Ptr);
                }
                auto sig=functionArities.find(e.name);
                if(sig==functionArities.end()){
                    // v0.23.24-dev: the callee is not a function name. It may
                    // still be a ptr variable holding a function's address —
                    // taking one has yielded a ptr since the callback-table
                    // work — and this is the call through it: the same
                    // argument staging as a direct call, but the branch goes
                    // through a register (BLR) instead of a relocated BL.
                    if(!indirectCallee(e.name))
                        throw Error(loc(e.line,e.col,"call to undeclared function: "+e.name));
                    // v0.23.37-dev: a typed fn-pointer stages its arguments by
                    // the signature and answers the signature's return type; a
                    // bare ptr keeps the legacy behaviour (all scalars at 64
                    // bits, an i32 result), because funcSigOf answers null for
                    // it and emitCallSeq falls back to exactly the old rule.
                    const FuncSig* fs=funcSigOf(e.name);
                    const Ty rt=fs?fs->ret:Ty::I32;
                    int d=emitCallSeq(e,fs,0,0,true);
                    // The call answers the signature's return type (i32 for a
                    // bare ptr). A 32-bit (i32) return consumed at 64-bit width
                    // is sign-extended here, exactly as a direct call is —
                    // AAPCS64 leaves the upper half of X0 unspecified after a
                    // W-sized return. u32/u8/u16 and bool need nothing: the MOV
                    // W already zeroed the upper half, which is their 64-bit
                    // value. For a bare ptr rt is i32, so this is the same test
                    // it has always been.
                    if(tyIs64(want)&&rt==Ty::I32)emit(0x93407c00u|(uint32_t(d)<<5)|uint32_t(d));
                    return d;
                }
                if(sig->second!=e.args.size())throw Error(loc(e.line,e.col,"wrong argument count calling "+e.name+": expected "+std::to_string(sig->second)+", got "+std::to_string(e.args.size())));
                static const std::vector<Ty> noArgTypes;
                const auto tm=argTypes.find(e.name);
                const std::vector<Ty>& argT=tm==argTypes.end()?noArgTypes:tm->second;
                for(size_t i=0;i<e.args.size();++i){
                    const Ty actual=exprType(*e.args[i]);
                    const Ty expected=i<argT.size()?argT[i]:Ty::I32;
                    if(expected==Ty::Bool){
                        if(actual!=Ty::Bool&&!isBoolConstant(*e.args[i]))
                            throw Error("argument type mismatch calling "+e.name+" at argument "+std::to_string(i+1)+": expected bool");
                    } else if(expected==Ty::Ptr){
                        // v0.23.26-dev: the null constant is a ptr here too.
                        if(actual!=Ty::Ptr&&!isNullConstant(*e.args[i]))throw Error("argument type mismatch calling "+e.name+" at argument "+std::to_string(i+1)+": expected ptr");
                    } else if(!tyAssignable(expected,actual,*e.args[i])){
                        throw Error("argument type mismatch calling "+e.name+" at argument "+std::to_string(i+1)+": expected "+tyNameFull(expected)+", got "+tyNameFull(actual));
                    }
                }
                // A 32-bit return consumed at 64-bit width is sign-extended
                // here rather than by the consumer: AAPCS64 leaves the upper
                // half of X0 unspecified after a W-sized return, so
                // `let q: i64 = f()` used to pick up whatever the callee left
                // there. u32/u8/u16 and bool need nothing — the MOV W already
                // zeroed the upper half, which is exactly their 64-bit value.
                const Ty rt=returnTypeOf(e.name);
                int d=emitCallSeq(e);
                if(tyIs64(want)&&rt==Ty::I32)emit(0x93407c00u|(uint32_t(d)<<5)|uint32_t(d));
                return d;
            }
            case Expr::Deref:{
                if(!exprIsPtr(*e.a))throw Error("dereference requires a ptr expression");
                int a=gen(*e.a);emit(0xb9400000u|(uint32_t(a)<<5)|uint32_t(a));
                // A 32-bit load read into an i64 context is sign-extended, as
                // for a local, a field and an array element: LDR W zeroes the
                // upper half of X, and a negative pointee would otherwise
                // widen into a huge positive i64.
                if(tyIs64(want))emit(0x93407c00u|(uint32_t(a)<<5)|uint32_t(a));
                return a;
            }
            case Expr::Field:{
                const Ty base=exprType(*e.a);
                const StructField* f=structFieldOf(base,e.name);
                if(!f)throw Error("struct '"+structOf(structBaseId(base,e.name)).name+"' has no field named '"+e.name+"'");
                emitStructAddr(e);
                int d=temp();emit(loadGlobalT(d,f->ty));   // LDR <T>d, [X16]
                // An i32 field read into an i64 context is sign-extended, exactly
                // like an i32 local (see Expr::Var): the 32-bit load zeroes the
                // upper half of X, and a negative field would otherwise widen
                // into a huge positive i64.
                if(tyIs64(want)&&f->ty==Ty::I32)emit(0x93407c00u|(uint32_t(d)<<5)|uint32_t(d));
                return d;
            }
            case Expr::AddrOf:{
                emitStructAddr(*e.a);
                int d=temp();emit(movX(d,kGlobalBase));return d;
            }
            case Expr::StructLit:
                throw Error("a struct literal can only appear as the initializer of a struct variable or field");
            case Expr::Index:{
                // v0.23.31-dev: a subscript on a subscript — `a[i][j]`,
                // `s.xs[i][j]` — or a subscript on a multi-dimensional array
                // that stops at a row — `a[i]` on an `i32[2][3]`. Both are
                // levels of one chain, and the chain's own address
                // computation answers both: a level short of the elements
                // *is* the row's address, and the innermost level reads
                // through it. A one-dimensional array is a single level that
                // always reaches the elements, and it keeps the emission
                // order it has always had, below.
                IndexChain ch;
                if(indexChainOf(e,ch)&&((e.name.empty()&&e.a->k==Expr::Index)||ch.level+1<ch.dims->size())){
                    emitIndexAddr(e);
                    // The value of a row address is the address itself, not a
                    // load through it.
                    if(ch.level+1<ch.dims->size()){
                        int d=temp();emit(movX(d,kGlobalBase));   // MOV Xd, X16
                        return d;
                    }
                    const Ty elem=ch.elem;
                    if(tyIsStruct(elem))
                        throw Error("cannot use a whole struct as a value: '"+chainBaseName(e)+"[...]' (read its fields, or pass &"+chainBaseName(e)+"[i])");
                    int d=temp();emit(loadGlobalT(d,elem));
                    if(tyIs64(want)&&elem==Ty::I32)emit(0x93407c00u|(uint32_t(d)<<5)|uint32_t(d));
                    return d;
                }
                // v0.23.29-dev: a struct array field element (`s.xs[i]`) — the
                // base is a Field and the index lives in `b`. A scalar, bool or
                // ptr element reads at its own width; a struct element has no
                // register form, refused exactly as a struct variable is.
                if(e.a->k==Expr::Field){
                    const StructField* af=arrayFieldOf(exprType(*e.a->a),*e.a);
                    if(af){
                        const Ty elem=af->ty;
                        if(tyIsStruct(elem))
                            throw Error("cannot use a whole struct as a value: '"+e.a->name+"[...]' (read its fields, or pass &"+e.a->name+"[i])");
                        emitElemAddrField(*e.a,*e.b);
                        int d=temp();emit(loadGlobalT(d,elem));
                        if(tyIs64(want)&&elem==Ty::I32)emit(0x93407c00u|(uint32_t(d)<<5)|uint32_t(d));
                        return d;
                    }
                }
                // v0.23.34-dev: `(&arr)[i]` — an Index whose base is an
                // expression, so the base rides in `a` and the subscript in
                // `b`. (A named base keeps `name` and puts the subscript in
                // `a`: that shape reaches emitElemAddr below, which strides at
                // the slot's element type.) Reached for an `&` base and for no
                // other — postfix() lets `[` follow a Field, an Index or an
                // `&` — and naming which shape this is keeps a future one from
                // falling into the named-array path by accident.
                if(e.name.empty()&&e.a->k!=Expr::Index){
                    const Ty at=exprType(*e.a);
                    if(tyIsPtrToElem(at)){
                        const Ty elem=ptrElemType(at);
                        if(tyIsStruct(elem))
                            throw Error("cannot use a whole struct as a value: read its fields, or pass &a[i]");
                        emitPtrElemAddr(*e.a,*e.b,elem);
                        int d=temp();emit(loadGlobalT(d,elem));
                        if(tyIs64(want)&&elem==Ty::I32)emit(0x93407c00u|(uint32_t(d)<<5)|uint32_t(d));
                        return d;
                    }
                }
                if(exprIsPtr(*e.a))throw Error("pointer indexing is not supported yet");
                // v0.23.28-dev: the element type is the array's declared one —
                // a bool, a ptr or a struct no less than an integer — and the
                // address is the shared emitElemAddr. A struct element has no
                // register form, so reading one as a value is refused here
                // exactly as reading a struct variable is.
                const Ty elem=elementTypeOf(e.name);
                if(tyIsStruct(elem))
                    throw Error("cannot use a whole struct as a value: '"+e.name+"[...]' (read its fields, or pass &"+e.name+"[i])");
                emitElemAddr(e.name,*e.a);
                int d=temp();emit(loadGlobalT(d,elem));
                // An i32 element read into an i64 context is sign-extended,
                // like an i32 local and an i32 struct field.
                if(tyIs64(want)&&elem==Ty::I32)emit(0x93407c00u|(uint32_t(d)<<5)|uint32_t(d));
                return d;
            }
            case Expr::Neg:{
                if(exprIsPtr(*e.a))throw Error("pointer arithmetic is not supported yet");
                int a=gen(*e.a,want);
                // SUB Wd, WZR, Wa / SUB Xd, XZR, Xa — the 64-bit form when the
                // result is headed for an i64 slot, so -1 stays -1.
                emit((tyIs64(want)?0xcb0003e0u:0x4b0003e0u)|(uint32_t(a)<<16)|uint32_t(a));
                return a;
            }
            case Expr::Eq:case Expr::Ne:case Expr::Lt:case Expr::Le:case Expr::Gt:case Expr::Ge:
                // Comparisons are ordinary bool expressions now: materialize 0/1
                // (CMP + CSET) so a comparison can be stored, returned, or combined.
                return genBool(e);
            case Expr::And:case Expr::Or:case Expr::Not:
                return genBool(e);
            // ---------------------------------------------------------------
            // v0.23.17-dev (round 1): `%`, shifts, bitwise ops, `?:`.
            // Every encoding below was read off `aarch64-linux-gnu-gcc -O2`
            // output for the equivalent C expression, not derived by hand.
            // ---------------------------------------------------------------
            // `a % b` is SDIV followed by MSUB — `a - (a/b)*b`, which is
            // exactly what a C compiler emits (no remainder instruction exists).
            case Expr::Mod:{
                const Ty ta=exprType(*e.a),tb=exprType(*e.b);
                const bool wide=wideOp(want,ta,tb,*e.a,*e.b);
                const Ty opWant=wide?Ty::I64:want;
                // Each operand widens itself when it is asked for i64 — see
                // the width rules above the emit helpers — so there is
                // deliberately no SXTW here.
                int a=gen(*e.a,opWant),b=gen(*e.b,opWant);
                const bool isUnsigned=tyIsUnsigned(ta)||tyIsUnsigned(tb);
                int q=temp();
                emit(((wide?0x9ac00000u:0x1ac00000u)|(isUnsigned?0x800u:0xc00u))
                     |(uint32_t(b)<<16)|(uint32_t(a)<<5)|uint32_t(q));   // SDIV/UDIV Qq, Wa, Wb
                // MSUB Wa, Qq, Wb, Wa  ==  a - q*b.  Rm<<16, Ra<<10, Rn<<5, Rd.
                emit((wide?0x9b008000u:0x1b008000u)|(uint32_t(b)<<16)|(uint32_t(a)<<10)|(uint32_t(q)<<5)|uint32_t(a));
                releaseTemp(q);releaseTemp(b);
                return a;
            }
            // `>>` is ASR for a signed left operand and LSR for an unsigned one:
            // the arithmetic/logical distinction is a property of the value
            // being shifted, not of the count, so it is decided here.
            case Expr::Shl: case Expr::Shr:{
                const Ty ta=exprType(*e.a);
                const bool wide=tyIs64(want)||tyIs64(ta)||constExceedsI32(*e.a);
                const Ty opWant=wide?Ty::I64:want;
                int a=gen(*e.a,opWant),b=gen(*e.b);
                uint32_t base=wide?0x9ac02000u:0x1ac02000u;               // LSL (register)
                if(e.k==Expr::Shr)base|=(tyIsUnsigned(ta)?0x400u:0x800u); // LSR / ASR
                emit(base|(uint32_t(b)<<16)|(uint32_t(a)<<5)|uint32_t(a));
                releaseTemp(b);
                return a;
            }
            case Expr::BitAnd: case Expr::BitOr: case Expr::BitXor:{
                const Ty ta=exprType(*e.a),tb=exprType(*e.b);
                const bool wide=wideOp(want,ta,tb,*e.a,*e.b);
                const Ty opWant=wide?Ty::I64:want;
                int a=gen(*e.a,opWant),b=gen(*e.b,opWant);
                uint32_t base;
                if(e.k==Expr::BitAnd)     base=wide?0x8a000000u:0x0a000000u;   // AND
                else if(e.k==Expr::BitOr) base=wide?0xaa000000u:0x2a000000u;   // ORR
                else                      base=wide?0xca000000u:0x4a000000u;   // EOR
                emit(base|(uint32_t(b)<<16)|(uint32_t(a)<<5)|uint32_t(a));
                releaseTemp(b);
                return a;
            }
            // `~x` is ORN with the zero register, which is what `mvn` is.
            case Expr::BitNot:{
                const Ty ta=exprType(*e.a);
                const bool wide=tyIs64(want)||tyIs64(ta)||constExceedsI32(*e.a);
                const Ty opWant=wide?Ty::I64:want;
                int a=gen(*e.a,opWant);
                emit((wide?0xaa200000u:0x2a200000u)|(uint32_t(a)<<16)|(31u<<5)|uint32_t(a)); // ORN Wa, WZR, Wa
                return a;
            }
            // `c ? x : y`. One result register is allocated before either arm,
            // so both arms write into it with a MOV and the allocator's LIFO
            // discipline holds across the branch — the same shape genBool uses
            // for && / ||.
            case Expr::Cond:{
                if(!exprIsBool(*e.a))throw Error("the condition of '?:' must be a bool expression");
                // The arms are generated at the width the conditional's *result*
                // is consumed at, not at the type the first arm happens to have:
                // every literal is statically i32, so `let q: i64 = c ? 0 : -5`
                // used to materialize -5 at 32 bits and move it with MOV W,
                // leaving 4294967291 in the i64 slot — and a literal that does
                // not fit in 32 bits was truncated before it ever got there.
                const Ty armTy=tyIs64(want)?Ty::I64:exprType(e);
                const bool wide=tyIs64(armTy);
                int t=temp();
                size_t toElse;const int cond=emitCondition(*e.a,toElse);
                int x=gen(*e.b,armTy);
                emit((wide?0xaa0003e0u:0x2a0003e0u)|(uint32_t(x)<<16)|uint32_t(t)); // MOV Tt, Wx
                releaseTemp(x);
                size_t toEnd=code.size();emit(0);
                patchCond(toElse,cond,code.size());
                int y=gen(*e.args[0],armTy);
                emit((wide?0xaa0003e0u:0x2a0003e0u)|(uint32_t(y)<<16)|uint32_t(t));
                releaseTemp(y);
                patchBranch(toEnd,code.size());
                return t;
            }
            default:{
                const bool ap=exprIsPtr(*e.a),bp=exprIsPtr(*e.b);
                if((e.k==Expr::Add && ap!=bp)||(e.k==Expr::Sub && ap&&!bp)) {
                    int a=gen(*e.a),b=gen(*e.b);
                    // ADD/SUB Xd, Xn, Wm, SXTW: byte offset, sign-extended from i32.
                    // For i32 + ptr, swap operands so the pointer is always Xn.
                    const uint32_t base=e.k==Expr::Sub?0xcb20c000u:0x8b20c000u;
                    if(ap){
                        // p +/- offset: write result over p, then release offset.
                        emit(base|(uint32_t(b)<<16)|(uint32_t(a)<<5)|uint32_t(a));
                        releaseTemp(b);
                        return a;
                    }
                    // offset + p: write result over the lower temporary so LIFO release
                    // remains valid; destination may alias the offset source.
                    emit(base|(uint32_t(a)<<16)|(uint32_t(b)<<5)|uint32_t(a));
                    releaseTemp(b);
                    return a;
                }
                if(ap||bp)throw Error("invalid pointer arithmetic: expected ptr +/- i32 or i32 + ptr");
                const Ty ta=exprType(*e.a),tb=exprType(*e.b);
                const bool wide=wideOp(want,ta,tb,*e.a,*e.b);
                const Ty opWant=wide?Ty::I64:want;
                int a=gen(*e.a,opWant),b=gen(*e.b,opWant);
                // sf (bit 31) selects the 64-bit form of each instruction.
                // Division additionally picks UDIV when either operand is
                // unsigned: bit 10 is what separates UDIV from SDIV, and this
                // is the only place the two differ.
                uint32_t base;
                if(e.k==Expr::Add)      base=wide?0x8b000000u:0x0b000000u;
                else if(e.k==Expr::Sub) base=wide?0xcb000000u:0x4b000000u;
                else if(e.k==Expr::Mul) base=wide?0x9b007c00u:0x1b007c00u;
                else base=(wide?0x9ac00000u:0x1ac00000u)|((tyIsUnsigned(ta)||tyIsUnsigned(tb))?0x800u:0xc00u);
                // The destination aliases the left operand, reducing temporary pressure.
                emit(base|(uint32_t(b)<<16)|(uint32_t(a)<<5)|uint32_t(a));
                releaseTemp(b);
                return a;
            }
        }
    }
    // -----------------------------------------------------------------------
    // Structs (v0.23.5-dev, P3.3)
    //
    // A struct value never sits in a register: it lives in memory and is
    // referred to by address. Every operation is therefore an address
    // computation followed by a load, a store, or a copy — which is also how
    // the AAPCS64 classifies composites, so the same address serves the
    // by-value and by-pointer ABIs below.
    // -----------------------------------------------------------------------
    // Frame bytes the compiler keeps for itself, above the variable slots
    // (0..4000), the temporary spill area (4080..) and the argument scratch
    // area (4160..7992): a slot per nesting level while an aggregate literal
    // is being stored, one register saved across a copy, and the hidden
    // result pointer of a function returning a struct larger than 16 bytes.
    static constexpr uint32_t kDstScratchBase   = 8024;   // 4 levels x 8 bytes
    static constexpr uint32_t kStoreScratchBase = 8064;   // 8 levels x 8 bytes
    static constexpr uint32_t kCopyScratch      = 8152;
    static constexpr uint32_t kSretSlot         = 8160;
    // Where a struct return of at most 16 bytes is staged: it is built in
    // memory (a field at a time, or by a copy) and only then loaded into X0
    // and X1, because building it can clobber both.
    static constexpr uint32_t kRetBuf           = 8168;   // 16 bytes
    // How many eight-byte registers one argument of this type takes under
    // AAPCS64. Aster has no floating-point types, so there is no HFA case, and
    // a composite is classified by size alone: 1..8 bytes is one register,
    // 9..16 is two, and anything larger never travels in registers at all.
    static uint32_t aapcs64Slots(Ty t){ return (tyIsStruct(t)&&tySize(t)>8u)?2u:1u; }
    // A composite too large for two registers: passed as a pointer to a
    // caller-made copy, and returned through the hidden pointer in X8.
    static bool structInMemory(Ty t){ return tyIsStruct(t)&&tySize(t)>16u; }
    // Bytes one argument occupies, in the scratch grid and on the stack: a
    // register pair takes sixteen, and a memory composite only the eight of
    // the address that replaces it.
    static uint32_t argBytes(Ty t){ return structInMemory(t)?8u:aapcs64Slots(t)*8u; }
    // Where every argument lands, under AAPCS64. One definition, shared by the
    // caller that marshals the arguments and the callee that receives them, so
    // the two cannot disagree about which register holds which value.
    //
    // No Aster type is aligned to 16, so a two-register composite is *not*
    // forced to start at an even-numbered register: aarch64-linux-gnu-gcc was
    // checked on `f(i32, struct{3 x i32}, struct{3 x i32})` and takes the two
    // composites at x1/x2 and x3/x4. A composite larger than 16 bytes is
    // replaced by a pointer to a caller-made copy wherever it ends up — even
    // on the stack, where it is an eight-byte slot holding that address.
    struct ArgLayout {
        int reg[32];            // first register, or -1 when the argument is on the stack
        int count[32];          // 1 or 2 registers
        uint32_t stackOff[32];  // byte offset in the incoming stack area
        uint32_t stackBytes;    // the area's size, rounded up to 16
    };
    static ArgLayout layoutArgs(const std::vector<Ty>& ts,size_t n){
        ArgLayout l{};
        for(size_t i=0;i<32;++i){l.reg[i]=-1;l.count[i]=1;}
        int ngrn=0;uint32_t nsaa=0;
        for(size_t i=0;i<n&&i<32;++i){
            const Ty t=i<ts.size()?ts[i]:Ty::I32;
            const int need=structInMemory(t)?1:int(aapcs64Slots(t));
            if(ngrn+need<=8){l.reg[i]=ngrn;l.count[i]=need;ngrn+=need;}
            else {l.stackOff[i]=nsaa;nsaa+=argBytes(t);}
        }
        l.stackBytes=(nsaa+15u)&~uint32_t(15u);
        return l;
    }
    // ADD Xd, Xn, #imm — a plain 12-bit byte offset (sh = 0).
    static uint32_t addImm(int dst,int src,uint32_t imm){
        if(imm>4095)throw Error("internal compiler error: struct offset exceeds the add-immediate range");
        return 0x91000000u|(imm<<10)|(uint32_t(src)<<5)|uint32_t(dst);
    }
    // The same addition for an offset one ADD immediate cannot reach: the
    // argument scratch area and the return buffer both sit above 4095, so the
    // offset is taken in chunks. Anything a pre-existing site used was already
    // in range, and still takes the single instruction it always took.
    void emitAddOff(int dst,int src,uint32_t off){
        if(off<=4095){emit(addImm(dst,src,off));return;}
        emit(addImm(dst,src,4095));
        uint32_t rest=off-4095;
        while(rest>4095){emit(addImm(dst,dst,4095));rest-=4095;}
        emit(addImm(dst,dst,rest));
    }
    // MOV Xd, Xn
    static uint32_t movX(int dst,int src){return 0xaa0003e0u|(uint32_t(src)<<16)|uint32_t(dst);}
    // One value of type `t` at [Xbase + off], where any of the four widths
    // may apply and off is a byte offset inside a struct.
    static uint32_t loadAtT(int reg,int base,uint32_t off,Ty t){
        if(tyIs64(t))return 0xf9400000u|((off/8)<<10)|(uint32_t(base)<<5)|uint32_t(reg);
        if(t==Ty::U8) return 0x39400000u|(off<<10)|(uint32_t(base)<<5)|uint32_t(reg);
        if(t==Ty::U16)return 0x79400000u|((off/2)<<10)|(uint32_t(base)<<5)|uint32_t(reg);
        return 0xb9400000u|((off/4)<<10)|(uint32_t(base)<<5)|uint32_t(reg);
    }
    static uint32_t storeAtT(int reg,int base,uint32_t off,Ty t){
        if(tyIs64(t))return 0xf9000000u|((off/8)<<10)|(uint32_t(base)<<5)|uint32_t(reg);
        if(t==Ty::U8) return 0x39000000u|(off<<10)|(uint32_t(base)<<5)|uint32_t(reg);
        if(t==Ty::U16)return 0x79000000u|((off/2)<<10)|(uint32_t(base)<<5)|uint32_t(reg);
        return 0xb9000000u|((off/4)<<10)|(uint32_t(base)<<5)|uint32_t(reg);
    }
    // X16 += Widx * sizeof(elem) — the element scaling of `a[i]`.
    //
    // A power-of-two element (every scalar, and a struct whose size happens to
    // be one) folds into the shifted add this has always used. A 12-byte
    // struct cannot: no shift reaches it, so the offset is a UMADDL —
    // `X16 = X16 + Wsize * Windex`, which reads both operands as the 32-bit
    // values they are and needs no zero-extending of its own. (The first
    // attempt used MADD with `ADD Xt, XZR, Widx, UXTW #0` to widen the index:
    // in the *extended* add, Rn == 31 is the stack pointer and not XZR, so
    // that instruction added SP instead of zero and every struct array read
    // through this path walked off the frame.)
    void emitElemIndex(int idxReg,Ty elem){
        const int sh=elemShiftOf(elem);
        if(sh>=0){
            emit(0x8b200000u|(uint32_t(idxReg)<<16)|(0b010u<<13)|(uint32_t(sh)<<10)|(uint32_t(kGlobalBase)<<5)|uint32_t(kGlobalBase));
            return;
        }
        const int sz=temp();
        emit(movInt(sz,tySize(elem)));                                                                              // MOVZ Wsz, #sizeof(elem)
        emit(0x9ba00000u|(uint32_t(idxReg)<<16)|(uint32_t(kGlobalBase)<<10)|(uint32_t(sz)<<5)|uint32_t(kGlobalBase)); // UMADDL X16, Wsz, Widx, X16
        releaseTemp(sz);
    }
    // The address of one array element, left in X16 — shared by every path that
    // reaches an element (a read, a store, a field of one, &a[i]) so they
    // cannot disagree about the base, the scale or the bounds check. Three
    // bases: a local T[N] at its frame slot, a fixed-size global by ADRP+ADD,
    // and a ptr local — which since v0.23.34-dev strides at its element's real
    // width (the one-i32 stride for an untyped ptr, sizeof(T) for a ptr<T>).
    void emitElemAddr(const std::string& name,const Expr& index){
        const Ty elem=elementTypeOf(name);
        const int slot=lookup(name);
        if(slot>=0){
            if(localArrayLength.count(slot)){
                checkArrayBounds(name,index);
                const int r=gen(index);
                emitBoundsCheck(name,index,r);
                emit(0x91000000u|(uint32_t(slot*8)<<10)|(31u<<5)|uint32_t(kGlobalBase)); // ADD X16, SP, #slot*8
                emitElemIndex(r,elem);
                releaseTemp(r);
                return;
            }
            if(pointerSlots.count(slot)&&pointerSlots.at(slot)){
                const int r=gen(index);
                // v0.23.36-dev: an array parameter remembers its length, so a single
                // subscript through it is bounds-checked exactly like a local array. A
                // plain pointer (a variable bound to &arr, or a ptr<S>) carries no
                // length and is left unchecked, as before.
                if(paramArrayLength.count(slot)){
                    checkArrayBounds(paramArrayLength.at(slot),index);
                    emitBoundsCheck(paramArrayLength.at(slot),index,r);
                }
                emit(loadVar64(kGlobalBase,slot));                       // LDR X16, [SP, #slot*8]
                // v0.23.34-dev: a typed pointer (an array parameter, or a
                // variable bound to `&arr`) strides at its element's real
                // width; a ptr<S> strides at sizeof(S), which is what `p + 1`
                // means for a pointer to a struct in the C it has to agree
                // with — a 12-byte V3 cannot be reached at four bytes; an
                // untyped one keeps the one-i32 stride it always had.
                const Ty st=slotType(slot);
                Ty pe=Ty::I32;
                if(tyIsPtrToElem(st))pe=ptrElemType(st);
                else if(tyIsPtrToStruct(st))pe=Ty::ofStruct(st.sid);
                emitElemIndex(r,pe);
                releaseTemp(r);
                return;
            }
            throw Error("cannot index non-array variable: "+name);
        }
        if(!globals.count(name))throw Error("unknown array: "+name);
        if(!arrayGlobals.count(name))throw Error("cannot index non-array global: "+name);
        checkArrayBounds(name,index);
        const int r=gen(index);
        emitBoundsCheck(name,index,r);
        emitGlobalAddress(name);
        emitElemIndex(r,elem);
        releaseTemp(r);
    }
    // v0.23.34-dev: the address of one element through a typed pointer, left
    // in X16 — `p[i]`, `(&arr)[i]`, a pointer returned by a call. The base is
    // any pointer expression (a frame slot, an `&arr`, a loaded pointer); its
    // value is the address, and the element stride is added by the same
    // emitElemIndex every named-array path uses, so a typed pointer cannot
    // stride differently from the array it came from. There is no length to
    // check against — a pointer does not know how many elements follow it.
    void emitPtrElemAddr(const Expr& base,const Expr& index,Ty elem){
        int r=gen(index);
        int p=gen(base);                       // the pointer value (64-bit address)
        emit(movX(kGlobalBase,p));releaseTemp(p);
        emitElemIndex(r,elem);                 // X16 += Widx * sizeof(elem)
        releaseTemp(r);
    }
    // v0.23.29-dev: the address of one element of a struct array field
    // (`s.xs[i]`), left in X16. The array field's own address — `structBase +
    // fieldOffset` — is exactly what emitStructAddr yields for the Field, and
    // the element stride is added by the same emitElemIndex the named-array path
    // uses, so a struct array field reads, writes and is addressed through one
    // shared scale. The bounds check uses the field's own length. `fbase` is the
    // Field expression (`s.xs`); `index` is the subscript.
    void emitElemAddrField(const Expr& fbase,const Expr& index){
        const StructField* f=arrayFieldOf(exprType(*fbase.a),fbase);
        const Ty elem=f->ty;
        const uint32_t len=f->len;
        checkArrayBounds(len,index);
        emitStructAddr(fbase);                       // X16 = structBase + fieldOffset
        int r=gen(index);
        emitBoundsCheck(len,index,r);
        emitElemIndex(r,elem);                       // X16 += index * sizeof(elem)
        releaseTemp(r);
    }
    // v0.23.31-dev: X16 += Widx * stride — the scaling of an *outer*
    // subscript, whose stride is the product of the dimensions below it times
    // the element size. The innermost subscript's stride is the element size
    // itself, which is emitElemIndex's own case; an outer one is a product
    // that need not be a power of two (a 2x3 i32 grid strides by 12), so the
    // shifted add is taken only when the product happens to be one and the
    // UMADDL otherwise — the same two shapes emitElemIndex picks between, for
    // the same reason.
    void emitElemStride(int idxReg,uint64_t stride){
        if(stride==0)return;                       // unreachable: every dimension is at least 1
        if(stride>0xffffffffull)
            throw Error("internal compiler error: array row stride exceeds 32 bits");
        if((stride&(stride-1))==0){
            unsigned sh=0;uint64_t bit=1;
            while(bit<stride){bit<<=1;++sh;}
            emit(0x8b200000u|(uint32_t(idxReg)<<16)|(0b010u<<13)|(sh<<10)|(uint32_t(kGlobalBase)<<5)|uint32_t(kGlobalBase));
            return;
        }
        const int sz=temp();
        // MOVZ Wsz, #low / MOVK Wsz, #high, LSL #16 — a row stride is a
        // product of dimensions, which for a large global can pass 16 bits
        // (a 1000000-element i32 global strides by 4000000), so the low half
        // alone is not enough.
        emit(0x52800000u|((uint32_t(stride)&0xffffu)<<5)|uint32_t(sz));
        if(stride>>16)emit(0x72a00000u|(((uint32_t(stride)>>16)&0xffffu)<<5)|uint32_t(sz));
        emit(0x9ba00000u|(uint32_t(idxReg)<<16)|(uint32_t(kGlobalBase)<<10)|(uint32_t(sz)<<5)|uint32_t(kGlobalBase)); // UMADLL X16, Wsz, Widx, X16
        releaseTemp(sz);
    }
    // v0.23.31-dev: the address a multi-dimensional subscript chain denotes,
    // left in X16 — `a[i][j]`, `a[i][j][k]`, `s.xs[i][j]`. The chain walks
    // from its base outward: the base address (a frame slot, a global, or a
    // struct array field), then one scaled subscript per level, outermost
    // last. Level 0's stride is the product of every dimension below it
    // times the element size; the innermost level's is the element size,
    // which is exactly the one-dimensional scale, so the last level of a
    // chain and a one-dimensional `a[i]` reach the same instruction.
    //
    // A one-dimensional subscript never comes here: its own emit paths keep
    // the emission order they have always had, which is what leaves every
    // existing program byte-identical. The chain shape — an Index whose name
    // is empty and whose left side is itself an Index — only exists with two
    // or more subscripts, because the parser builds it only then.
    void emitIndexAddr(const Expr& e){
        // The nodes above the base, root first.
        const Expr* nodes[8];unsigned depth=0;
        const Expr* cur=&e;
        while(cur->k==Expr::Index&&cur->name.empty()&&cur->a->k==Expr::Index){
            if(depth>=8)throw Error("internal compiler error: subscript chain is too deep");
            nodes[depth++]=cur;cur=cur->a.get();
        }
        // The base: a named array or a struct array field.
        const std::vector<uint32_t>* dims=nullptr;
        Ty elem=Ty::I32;
        if(!cur->name.empty()){
            dims=arrayDimsOf(cur->name);
            if(!dims)throw Error("cannot index non-array variable: "+cur->name);
            elem=elementTypeOf(cur->name);
        } else {
            const StructField* f=arrayFieldOf(exprType(*cur->a->a),*cur->a);
            if(!f||f->dims.empty())throw Error("cannot index non-array field: "+cur->a->name);
            dims=&f->dims;elem=f->ty;
        }
        if(dims->size()>8)throw Error("internal compiler error: subscript chain is too deep");
        // The number of subscripts actually written — one per node in the
        // chain — which is at most the number of dimensions: sema has already
        // refused a chain that runs past them. A chain may also stop short
        // (`a[i]` on a two-dimensional array addresses a row), and the stride
        // of the level it does reach still comes from the full list below it.
        const unsigned levels=depth+1;
        // Every subscript first, outermost level 0 to the innermost, each in
        // its own temporary with its own range test — the order the
        // one-dimensional emitElemAddr uses, one level at a time. They come
        // before the base address because evaluating a subscript can
        // materialize a global's address into X16, which is where the base is
        // about to go.
        int regs[8];
        for(unsigned k=0;k<levels;++k){
            // The named base node carries its subscript in `a` (its `b` is
            // empty — the name is what identifies the array); a field base
            // node and every node above the base carry theirs in `b`.
            const Expr& index=(k==0)?(cur->name.empty()?*cur->b:*cur->a):*nodes[depth-k]->b;
            checkArrayBounds((*dims)[k],index);
            regs[k]=gen(index);
            emitBoundsCheck((*dims)[k],index,regs[k]);
        }
        // The base address, then one scaled subscript per level. The scales
        // are applied innermost first so the temporaries release in the order
        // they were taken; the additions commute, so the order the strides
        // are summed in is nobody's business but the register allocator's.
        if(!cur->name.empty()){
            const int slot=lookup(cur->name);
            if(slot>=0)emit(0x91000000u|(uint32_t(slot*8)<<10)|(31u<<5)|uint32_t(kGlobalBase)); // ADD X16, SP, #slot*8
            else emitGlobalAddress(cur->name);
        } else {
            emitStructAddr(*cur->a);                // X16 = structBase + fieldOffset
        }
        // One scaled subscript per level. The scales are applied innermost
        // first so the temporaries release in the order they were taken; the
        // additions commute, so the order the strides are summed in is
        // nobody's business but the register allocator's. The stride of a
        // level is the product of every dimension *below* it times the
        // element size — which for a chain that stops short (`a[i]` on a
        // two-dimensional array) still includes the dimensions the missing
        // subscripts would have walked, because the row it addresses is
        // dims[1] elements wide.
        uint64_t stride=tySize(elem);
        for(size_t k=levels;k<dims->size();++k)stride*=(*dims)[k];
        for(int k=(int)levels-1;k>=0;--k){
            emitElemStride(regs[k],stride);
            releaseTemp(regs[k]);
            if(k>0)stride*=(*dims)[k];
        }
    }
    // The address of a struct lvalue, left in X16: a variable (a frame slot or
    // a global), an array element, a field of one, or a dereferenced pointer.
    // A ptr<S> base contributes its value directly — it already is the address.
    void emitStructAddr(const Expr& e){
        if(e.k==Expr::Index){
            // v0.23.29-dev: a struct array field element — `&s.xs[i]` — is the
            // one address a `&` may take through here: a struct has no register
            // form, so the only thing worth addressing is a whole one. A scalar,
            // bool, or ptr element has no address worth taking either, which is
            // why the non-struct case is refused.
            if(e.a->k==Expr::Field){
                const StructField* af=arrayFieldOf(exprType(*e.a->a),*e.a);
                if(af){
                    // Every element of a struct array field has an address —
                    // that is what a store through `s.xs[i] = v` needs. Taking
                    // `&s.xs[i]` as a typed pointer value remains a struct-only
                    // privilege, but that is enforced by Sema's AddrOf rule
                    // (which requires the inner type to be a struct), not here;
                    // this routine only computes the address into X16.
                    emitElemAddrField(*e.a,*e.b);
                    return;
                }
            }
            // v0.23.31-dev: a subscript chain — `&a[i][j]` — whose innermost
            // subscript addresses a struct element. The address is the chain's
            // own, level by level, and it comes before the named-array check
            // below because a chain's outermost node carries no name.
            if(e.name.empty()&&e.a->k==Expr::Index){
                emitIndexAddr(e);
                return;
            }
            // v0.23.28-dev: an element is a struct only for a named struct
            // array, and a struct has no register form — a whole one is read
            // field by field, or through `&a[i]`, exactly like a struct variable.
            if(!tyIsStruct(elementTypeOf(e.name)))
                throw Error("cannot take the address of this expression");
            emitElemAddr(e.name,*e.a);
            return;
        }
        if(e.k==Expr::Field){
            const Ty base=exprType(*e.a);
            const StructField* f=structFieldOf(base,e.name);
            if(!f)throw Error("struct '"+structOf(structBaseId(base,e.name)).name+"' has no field named '"+e.name+"'");
            if(tyIsPtrToStruct(base)){
                int r=gen(*e.a);                     // p.f : p holds the address
                emit(movX(kGlobalBase,r));
                releaseTemp(r);
            } else {
                emitStructAddr(*e.a);
            }
            if(f->offset)emit(addImm(kGlobalBase,kGlobalBase,f->offset));
            return;
        }
        if(e.k==Expr::Deref){
            int r=gen(*e.a);                         // (*p) : the value is the address
            emit(movX(kGlobalBase,r));
            releaseTemp(r);
            return;
        }
        if(e.k==Expr::Var){
            const int slot=lookup(e.name);
            if(slot>=0){emit(addImm(kGlobalBase,31,(uint32_t)slot*8));return;}
            if(globals.count(e.name)){emitGlobalAddress(e.name);return;}
            throw Error("unknown variable: "+e.name);
        }
        throw Error("cannot take the address of this expression");
    }
    // Copy `size` bytes from [Xsrc] to [Xdst]. Eight bytes at a time and then
    // a single 4-byte move for the tail: a struct's size is a multiple of its
    // alignment, so the tail only appears when the alignment is 4.
    void emitStructCopy(int dst,int src,uint32_t size){
        storeStackOff(15,kCopyScratch+spAdj,Ty::I64);  // x15 carries the bytes
        uint32_t off=0;
        for(;size-off>=8;off+=8){
            emit(0xf9400000u|((off/8)<<10)|(uint32_t(src)<<5)|15);   // LDR X15, [Xsrc, #off]
            emit(0xf9000000u|((off/8)<<10)|(uint32_t(dst)<<5)|15);   // STR X15, [Xdst, #off]
        }
        if(off<size){
            emit(0xb9400000u|((off/4)<<10)|(uint32_t(src)<<5)|15);
            emit(0xb9000000u|((off/4)<<10)|(uint32_t(dst)<<5)|15);
        }
        loadStackOff(15,kCopyScratch+spAdj,Ty::I64);
    }
    // v0.23.24-dev: the address an indirect call branches to, materialized
    // into `reg`. Sema resolved the name to a ptr local or a ptr global;
    // this repeats the resolution, because codegen emits what it verified
    // itself — a check another pass made is a promise, not a fact.
    void emitCalleeAddr(int reg,const std::string& name){
        const int slot=lookup(name);
        if(slot>=0){
            if(localArrayLength.count(slot))
                throw Error("internal error: an indirect callee cannot be an array: "+name);
            if(slotType(slot)!=Ty::Ptr)
                throw Error("internal error: an indirect callee must be a ptr variable: "+name);
            emit(loadVarT(reg,slot,Ty::Ptr));       // LDR Xreg, [SP, #slot*8]
            return;
        }
        if(globals.count(name)&&!arrayGlobals.count(name)&&globalTypeOf(name)==Ty::Ptr){
            emitGlobalAddress(name);                // ADRP/ADD X16 (GOT slot when shared)
            emit(loadGlobalT(reg,Ty::Ptr));         // LDR Xreg, [X16] — the pointer it holds,
                                                    // not the global's own address: a local
                                                    // loads its slot's value, and a global
                                                    // must answer the same value.
            return;
        }
        throw Error("internal error: an indirect callee is not a ptr variable: "+name);
    }
    // One call: marshal the arguments, branch, and pick the result up.
    //
    // The scratch area is laid out per argument — eight bytes for a scalar,
    // sixteen for a composite that takes two registers, eight for the address
    // of one that is passed in memory — and with no composite among them it is
    // exactly the fixed i*8 grid every call has always used, so every
    // pre-existing call emits byte for byte what it emitted before.
    //
    // `sretBytes` is non-zero when the callee returns a composite larger than
    // 16 bytes. The caller then owns a buffer in the outgoing area, hands its
    // address over in X8, and copies the result out afterwards; `dstSlot` is
    // the frame slot holding the destination address meanwhile, because SP
    // moves as soon as the outgoing area opens.
    //
    // `indirect` (v0.23.24-dev) calls through a ptr variable instead of a
    // function name. The argument staging is shared unchanged except for one
    // width rule: there is no signature to say otherwise, so every scalar
    // argument rides at 64-bit width — one width serves both kinds of callee
    // (see `at` below). Only the branch differs: the callee's address is
    // materialized into X9 and the call is a BLR, with no relocation for the
    // linker to fix.
    int emitCallSeq(const Expr& e,const FuncSig* sig=nullptr,uint32_t sretBytes=0,uint32_t dstSlot=0,bool indirect=false){
        static const std::vector<Ty> noArgTypes;
        const auto tm=argTypes.find(e.name);
        const std::vector<Ty>& argT=tm==argTypes.end()?noArgTypes:tm->second;
        const size_t nargs=e.args.size();
        auto at=[&](size_t i)->Ty{
            // v0.23.37-dev: a typed fn-pointer stages each argument at the
            // width its signature declares — the AAPCS64 rule a direct call
            // has always followed, now available to an indirect call too. An
            // i32 argument rides in a W register (its low half), not a padded
            // X register, which is what a callee declaring i32 reads back.
            if(sig&&i<sig->params.size())return sig->params[i];
            // A bare ptr indirect call has no signature — the callee is a ptr,
            // not a function type — so `argT` (keyed by function name, and a
            // *different* function's signature if a function of this name
            // existed) must not be consulted. Every scalar argument rides at
            // 64-bit width instead, which serves both kinds of callee: one
            // declaring i32 reads the low half, exactly the bits a 32-bit
            // stage would have put there, and one declaring i64 reads a
            // properly extended full register instead of an upper half
            // AAPCS64 leaves unspecified. gen() already extends each source
            // type the right way (SXTW for an i32, free zero-extension for
            // the unsigned widths through their load form, the pointer's own
            // eight bytes), so one staging width answers for both — and a
            // literal wider than i32 rides at full width without a special
            // case, the way v0.23.18-dev's rule says it should.
            return indirect?Ty::I64:(i<argT.size()?argT[i]:Ty::I32);
        };
        // v0.23.37-dev: the result width. A typed fn-pointer answers its
        // declared return type; a bare ptr indirect call stays i32; a direct
        // call reads the callee's declared return type.
        const Ty rt=indirect?(sig?sig->ret:Ty::I32):returnTypeOf(e.name);
        if(structInMemory(rt)&&!sretBytes)
            throw Error("cannot use the struct returned by "+e.name+" as a value: "+tyName(rt)+" is larger than 16 bytes");
        std::vector<Ty> ts(nargs);
        for(size_t i=0;i<nargs;++i)ts[i]=at(i);
        const ArgLayout lay=layoutArgs(ts,nargs);
        uint32_t argOff[32]={0},copyOff[32]={0},cur=0,copyArea=0;
        for(size_t i=0;i<nargs;++i){
            argOff[i]=cur;
            // A composite passed in memory normally contributes only the
            // address of the copy the caller makes. A call result has no
            // address yet, so its bytes are staged in the scratch grid and
            // the slot holds the value instead.
            cur+=(structInMemory(at(i))&&!isLValue(*e.args[i]))
                ?((tySize(at(i))+7u)&~uint32_t(7u)):argBytes(at(i));
        }
        if(cur>256)throw Error("the arguments of this call need more scratch space than the frame provides");
        const uint32_t sretArea=(sretBytes+15u)&~uint32_t(15u);
        for(size_t i=0;i<nargs;++i){
            if(!structInMemory(at(i)))continue;
            copyOff[i]=copyArea;copyArea=(copyArea+tySize(at(i))+15u)&~uint32_t(15u);
        }
        const uint32_t stackBytes=lay.stackBytes;
        const uint32_t total=stackBytes+copyArea+sretArea;
        if(total>4095)throw Error("outgoing argument area exceeds immediate limit");
        // Stack arguments start at the stack pointer as the callee sees it —
        // that is where AAPCS64 puts them, and the callee's incoming offsets
        // are computed from there. The copies and the result buffer have no
        // fixed home (their addresses travel in registers), so they sit above.
        // With no composite among the arguments `total` is the stack area
        // alone, exactly as it has always been.
        const uint32_t stackBase=0,copyBase=stackBytes,sretBase=stackBytes+copyArea;
        // Eight-byte argument slots keep pointer and i64 values intact and match AAPCS64
        // stack slots. Limit nesting so all scratch slots remain inside the fixed 8 KiB frame.
        if(callDepth>=14)throw Error("nested function-call arguments exceed compiler limit (14 for pointer ABI)");
        int live=nextTemp;
        for(int r=0;r<live;++r)emit(storeLocal(r,1020+r));
        const int scratchByte=4160+callDepth*256;++callDepth;
        for(size_t i=0;i<nargs;++i){
            const Ty ty=at(i);const uint32_t off=uint32_t(scratchByte+argOff[i]);
            if(structInMemory(ty)){
                if(isLValue(*e.args[i])){
                    emitStructAddr(*e.args[i]);             // the address travels; the copy waits
                    storeStackOff(kGlobalBase,off,Ty::I64);
                } else {
                    // A call result has no address to hand over, so the value
                    // itself is built here and copied out with the others.
                    emitAddOff(kGlobalBase,31,off);
                    emitStructStore(*e.args[i]);
                }
            } else if(tyIsStruct(ty)){
                // A struct fills a whole number of eight-byte registers, so
                // the slot is cleared first: a struct shorter than its slot
                // would otherwise leave whatever the scratch area held in the
                // bytes no field owns.
                for(uint32_t z=0;z<argBytes(ty);z+=8)storeStackOff(31,off+z,Ty::I64);
                emitAddOff(kGlobalBase,31,off);
                emitStructStore(*e.args[i]);                // one or two eight-byte halves
            } else {
                int v=gen(*e.args[i],ty);
                storeStackOff(v,off,ty);
                releaseTemp(v);
            }
        }
        --callDepth;
        // v0.23.38-dev: a call through a *field* reads its callee here, before
        // the arguments move into X0-X7. Reading a field means evaluating its
        // base (`h`, or the expression that names the struct), and that takes a
        // temporary — drawn from the very pool X0-X7 come from, so doing it
        // after the loads would overwrite the first argument with the struct's
        // address. Here the values are still in the scratch area and every
        // register is free; X9 holds the address from now to the branch, and
        // nothing in between (the stack copies use X16/X17) touches it.
        if(indirect&&e.k==Expr::FieldCall){
            emitStructAddr(*e.a);
            emit(loadGlobalT(9,Ty::Ptr));           // LDR X9, [X16]
        }
        // Registers first, while SP still points at the frame: these loads use
        // the offsets every pre-existing call has always used.
        for(size_t i=0;i<std::min<size_t>(8,nargs);++i){
            if(lay.reg[i]<0)continue;                       // on the stack: needs the outgoing area
            if(structInMemory(at(i)))continue;              // likewise: only its address is ready
            const uint32_t off=uint32_t(scratchByte+argOff[i]);
            // A struct always travels eight bytes at a time, whatever its
            // fields are: the register is a byte container, not a value.
            loadStackOff(lay.reg[i],off,tyIsStruct(at(i))?Ty::I64:at(i));
            if(lay.count[i]==2)loadStackOff(lay.reg[i]+1,off+8,Ty::I64);
        }
        // v0.23.24-dev: an indirect call branches through a register, so the
        // callee's address is materialized here — after the arguments are in
        // their registers, while SP still points at the frame (a frame slot
        // is addressed without the outgoing-area compensation), and before SP
        // moves. X9 is the register: X0-X7 hold the arguments, X8 the hidden
        // result pointer when there is one, and X9-X15 hold nothing live —
        // every live temporary is parked in the frame and the staging's own
        // temporaries have been released. The stack copies below touch only
        // X16/X17, so X9 survives to the branch. A field call already has its
        // address (read above, before the arguments took the registers).
        if(indirect&&e.k!=Expr::FieldCall)emitCalleeAddr(9,e.name);
        if(total){emit(0xd10003ffu|(total<<10));spAdj=total;}
        if(sretBytes)emit(addImm(8,31,sretBase));            // X8: the hidden result pointer
        // Every composite too large for two registers travels as the address
        // of a copy the caller makes here, in the outgoing area.
        for(size_t i=0;i<nargs;++i){
            if(!structInMemory(at(i)))continue;
            const uint32_t off=uint32_t(total+scratchByte+argOff[i]);
            if(off>32760)throw Error("argument scratch offset exceeds load range");
            // An lvalue left the address of the value; a staged call result
            // left the value itself, so its address is the slot.
            if(isLValue(*e.args[i]))loadStackOff(kGlobalBase,off,Ty::I64);
            else emitAddOff(kGlobalBase,31,off);
            emit(addImm(17,31,copyBase+copyOff[i]));         // where the copy goes
            emitStructCopy(17,kGlobalBase,tySize(at(i)));
        }
        for(size_t i=0;i<std::min<size_t>(8,nargs);++i){
            if(structInMemory(at(i))&&lay.reg[i]>=0)
                emit(addImm(lay.reg[i],31,copyBase+copyOff[i]));
        }
        for(size_t i=8;i<nargs;++i){
            const uint32_t sourceOffset=total+uint32_t(scratchByte+argOff[i]);
            if(sourceOffset>32760)throw Error("argument scratch offset exceeds load range");
            const Ty ty=at(i);
            const uint32_t dest=uint32_t(stackBase+lay.stackOff[i]);
            if(structInMemory(ty)){
                emit(addImm(kGlobalBase,31,copyBase+copyOff[i]));
                storeStackOff(kGlobalBase,dest,Ty::I64);       // the address of the copy
            } else if(tyIsStruct(ty)){
                emit(addImm(17,31,dest));                          // by value, rounded up to 8
                emitAddOff(kGlobalBase,31,sourceOffset);
                emitStructCopy(17,kGlobalBase,argBytes(ty));
            } else {
                loadStackOff(kGlobalBase,sourceOffset,ty);
                storeStackOff(kGlobalBase,dest,ty);
            }
        }
        if(indirect){
            // BLR X9 — the callee's address, materialized above into the one
            // register the argument sequence leaves alone. No relocation:
            // the address came from memory, not from a symbol.
            emit(0xd63f0000u|(9u<<5));
        } else {
            size_t at2=code.size();emit(0x94000000u);relocations.push_back({uint64_t(at2)*4,e.name,kRelCall26});
        }
        int d=-1;
        if(sretBytes){
            loadStackOff(17,total+dstSlot,Ty::I64);      // the destination, saved before SP moved
            emit(addImm(kGlobalBase,31,sretBase));           // the buffer the callee filled
            emitStructCopy(17,kGlobalBase,sretBytes);
        } else {
            d=temp();
            // A struct result is eight bytes a register even when the struct
            // is narrower, so it moves at full width.
            if(d!=0)emit(((tyIs64(rt)||tyIsStruct(rt))?0xaa0003e0u:0x2a0003e0u)|uint32_t(d));
            if(aapcs64Slots(rt)==2u){
                int d2=temp();                               // X1 carries the second half
                if(d2!=1)emit(movX(d2,1));
            }
        }
        if(total){emit(0x910003ffu|(total<<10));spAdj=0;}
        for(int r=0;r<live;++r)emit(loadLocal(r,1020+r));
        return d;
    }
    // Store the struct value `e` produces into the memory X16 points at. An
    // aggregate literal writes field by field; anything else is a copy from
    // wherever the value already lives.
    void emitStructStore(const Expr& e){
        const Ty t=exprType(e);
        const uint32_t size=tySize(t);
        if(e.k==Expr::StructLit){
            const StructDef& sd=structOf(t.sid);
            if(structHasArrayField(t.sid))
                throw Error("struct '"+sd.name+"' contains an array field and cannot be initialized by a literal; fill its elements at runtime");
            if(structStoreDepth>=8)throw Error("struct literals nested more than 8 levels deep");
            const uint32_t save=kStoreScratchBase+uint32_t(structStoreDepth)*8+spAdj;
            ++structStoreDepth;
            // The destination arrives in X16. It has to survive the whole
            // literal — a nested one, or a copy, uses X16 and X17 freely — so
            // it is parked in the frame and reloaded for every field.
            emit(movX(17,kGlobalBase));
            storeStackOff(17,save,Ty::I64);
            for(size_t i=0;i<sd.fields.size();++i){
                const StructField& f=sd.fields[i];
                loadStackOff(17,save,Ty::I64);
                if(tyIsStruct(f.ty)){
                    emit(addImm(kGlobalBase,17,f.offset));
                    emitStructStore(*e.args[i]);
                } else {
                    int v=(f.ty==Ty::Bool&&exprIsBool(*e.args[i]))?genBool(*e.args[i]):gen(*e.args[i],f.ty);
                    emit(storeAtT(v,17,f.offset,f.ty));
                    releaseTemp(v);
                }
            }
            --structStoreDepth;
            return;
        }
        if(e.k==Expr::Call){
            const Ty rt=returnTypeOf(e.name);
            // The destination lives in X16, which the call itself is free to
            // clobber, so it is parked in the frame for the duration.
            if(structCallDepth>=4)throw Error("struct-returning calls nested more than 4 levels deep");
            const uint32_t dstSlot=kDstScratchBase+uint32_t(structCallDepth)*8+spAdj;
            ++structCallDepth;
            emit(movX(17,kGlobalBase));
            storeStackOff(17,dstSlot,Ty::I64);
            if(structInMemory(rt)){
                // Larger than 16 bytes: X8 points at a buffer in the outgoing
                // area and the result is copied out of it. (A struct-returning
                // callee is a named function — a direct call — so no signature
                // rides along here.)
                emitCallSeq(e,nullptr,size,dstSlot);
            } else {
                // One or two registers. gen() hands back the first one and the
                // next temporary along, which is where X1 was put.
                int d=gen(e);
                loadStackOff(17,dstSlot,Ty::I64);
                emit(storeAtT(d,17,0,Ty::I64));
                if(size>8){emit(storeAtT(d+1,17,8,Ty::I64));releaseTemp(d+1);}
                releaseTemp(d);
            }
            --structCallDepth;
            return;
        }
        emit(movX(17,kGlobalBase));                  // dst in x17, src computed into x16
        emitStructAddr(e);
        emitStructCopy(17,kGlobalBase,size);
    }
    int structStoreDepth=0;
    int structCallDepth=0;
    // Bytes the stack pointer has been moved down for the call in progress.
    // Every frame slot the compiler owns is addressed relative to SP, so once
    // SP drops for an outgoing argument area those offsets have to follow it.
    uint32_t spAdj=0;
    // Materialize a bool expression as 0/1 in a temporary register. && and ||
    // short-circuit: the right operand is evaluated only when the left one does
    // not already decide the result (a false left of &&, a true left of ||).
    int genBool(const Expr& e){
        if(isComparison(e.k)){
            // v0.23.26-dev: == and != accept a ptr operand (against another ptr
            // or against the null constant 0); ordering does not. Sema has
            // already decided which is which — this is the defensive twin.
            if(e.k!=Expr::Eq&&e.k!=Expr::Ne){
                if(exprIsPtr(*e.a)||exprIsPtr(*e.b))throw Error("only == and != are defined for a ptr");
            }
            const Ty ta=exprType(*e.a),tb=exprType(*e.b);
            // A comparison runs at 64 bits when either side is i64 or when a
            // constant side does not fit in 32 bits: C types such a constant
            // as long, so `n == 4294967297` must compare at full width even
            // against an i32 partner. Computing the width from the operands
            // (rather than only from their i64-ness) is also what makes the
            // exemption below sound — the operand is generated at that width.
            const bool wide=tyIs64(ta)||tyIs64(tb)||constExceedsI32(*e.a)||constExceedsI32(*e.b);
            const Ty cmpTy=wide?Ty::I64:promoteInt(ta,tb);   // a literal widens to match its i64/u32 partner
            // Generating each operand at cmpTy is what widens it: a literal
            // materializes at full width, an i32 local sign-extends on load, a
            // nested wide operation already ran at 64 bits. An SXTW after the
            // fact would truncate the last of those — `-9223372036854775807-1`
            // on the right of `==` used to be cut back to 32 bits and compare
            // unequal to the identical expression on the left.
            int a=gen(*e.a,cmpTy),b=gen(*e.b,cmpTy);
            emit((wide?0xeb00001fu:0x6b00001fu)|((uint32_t(b)&0x1f)<<16)|((uint32_t(a)&0x1f)<<5)); // CMP (X or W)
            releaseTemp(b);releaseTemp(a);
            int d=temp();
            emit(csetBool(d,comparisonCond(e.k,tyIsUnsigned(ta)||tyIsUnsigned(tb)))); // CSET Wd, <cond>
            return d;
        }
        if(e.k==Expr::Not){
            if(!exprIsBool(*e.a))throw Error("'!' requires a bool operand");
            int r=genBool(*e.a);
            emit(cmpZero(r));        // CMP wr, #0
            emit(csetBool(r,0));     // CSET wr, eq -> 1 when the operand is false
            return r;
        }
        if(e.k==Expr::And||e.k==Expr::Or){
            if(!exprIsBool(*e.a)||!exprIsBool(*e.b))
                throw Error(std::string("&& and || require bool operands (")+(e.k==Expr::And?"&&":"||")+")");
            const bool isAnd=(e.k==Expr::And);
            int t=temp();
            emit(movInt(t,isAnd?0:1));   // the result when the left operand decides it
            int a=genBool(*e.a);
            emit(cmpZero(a));            // CMP wa, #0
            size_t jump=code.size();emit(0);
            int b=genBool(*e.b);
            emit(0x2a0003e0u|(uint32_t(b)<<16)|uint32_t(t)); // MOV Wt, Wb
            releaseTemp(b);
            patchCond(jump,isAnd?0:1,code.size());  // && : branch on eq (left is false)
            releaseTemp(a);                          // || : branch on ne (left is true)
            return t;
        }
        // A bool value can also be a struct field or a ?: selection. Both
        // already materialize 0/1 at the width they are read at, so generating
        // them at the bool width is the whole implementation. (v0.23.25-dev:
        // without these two, `if (s.b)` and `if (c ? a : b)` died in the
        // fallthrough below even though sema had typed them bool — a bool
        // field could not be a condition, a bool initializer, or an operand.)
        if(e.k==Expr::Field||e.k==Expr::Cond||e.k==Expr::Index){
            // v0.23.28-dev: an element of a `bool[N]`, like a bool field —
            // the slot holds 0/1, so generating it at the bool width is the
            // whole implementation.
            if(exprType(e)!=Ty::Bool)throw Error("expected a bool expression");
            return gen(e,Ty::Bool);
        }
        if(e.k==Expr::Var){
            const int slot=lookup(e.name);
            if(slot>=0){int d=temp();emit(loadVar32(d,slot));return d;}
            if(globals.count(e.name)){emitGlobalAddress(e.name);int d=temp();emit(loadGlobal(d));return d;}
            throw Error("unknown variable: "+e.name);
        }
        // v0.23.25-dev: true/false — a bool is 0/1 in its slot, so the
        // literal materializes as exactly that.
        if(e.k==Expr::Num&&e.boolLit){
            int d=temp();
            emit(movInt(d,e.n?1u:0u));
            return d;
        }
        // A bool-returning function already yields 0/1 in its result register.
        if(e.k==Expr::Call)return gen(e);
        // v0.23.38-dev: likewise a call through a fn-pointer field whose
        // signature returns bool — the signature put 0/1 in the result
        // register, so there is nothing to materialize.
        if(e.k==Expr::FieldCall)return gen(e,Ty::Bool);
        throw Error("expected a bool expression");
    }
    // Emit the test for a condition and leave one placeholder branch that the
    // caller patches to the "false" target; returns the condition to patch with.
    // A comparison keeps the original CMP + conditional-branch shape (so every
    // pre-existing if/while/for compiles byte-identically); a bool expression
    // is materialized and tested against 0; v0.23.25-dev adds the third kind —
    // an integer condition, true when non-zero, tested at its own width (CMP
    // Wn for the 32-bit types, CMP Xn for i64) so a wide value's zero-ness is
    // never decided by its low half alone. All three branch on eq to the
    // false target.
    int emitCondition(const Expr& c,size_t& at){
        if(isComparison(c.k)){
            if(c.k!=Expr::Eq&&c.k!=Expr::Ne){
                if(exprIsPtr(*c.a)||exprIsPtr(*c.b))throw Error("only == and != are defined for a ptr");
            }
            const Ty ta=exprType(*c.a),tb=exprType(*c.b);
            // Same width rule as genBool above: a constant side that does not
            // fit in 32 bits makes the comparison 64-bit, and the operand is
            // generated at that width so the exemption below holds.
            const bool wide=tyIs64(ta)||tyIs64(tb)||constExceedsI32(*c.a)||constExceedsI32(*c.b);
            const Ty cmpTy=wide?Ty::I64:promoteInt(ta,tb);
            int a=gen(*c.a,cmpTy),b=gen(*c.b,cmpTy);
            emit((wide?0xeb00001fu:0x6b00001fu)|((uint32_t(b)&0x1f)<<16)|((uint32_t(a)&0x1f)<<5));releaseTemp(b);releaseTemp(a);
            at=code.size();emit(0);
            return comparisonCond(c.k,tyIsUnsigned(ta)||tyIsUnsigned(tb))^1;    // branch when the comparison is false
        }
        const Ty t=exprType(c);
        if(t==Ty::Bool){
            int r=genBool(c);emit(cmpZero(r));releaseTemp(r);
            at=code.size();emit(0);
            return 0;                            // branch on eq: the bool expression is false
        }
        // v0.23.25-dev: an integer condition. Zero is false, anything else is
        // true — C's rule, and the only coercion the language performs
        // anywhere: it exists at control-flow conditions and nowhere else.
        if(tyIsInteger(t)){
            int r=gen(c,t);
            emit(tyIs64(t)?cmpZeroX(r):cmpZero(r));releaseTemp(r);
            at=code.size();emit(0);
            return 0;                            // branch on eq: the integer is zero
        }
        throw Error("condition must be a comparison, a bool expression, or an integer");
    }
    static uint32_t branchCond(int cond,int from,int to){int32_t delta=to-from;if(delta<-(1<<18)||delta>=(1<<18))throw Error("conditional branch out of range");return 0x54000000u|((uint32_t(delta)&0x7ffffu)<<5)|uint32_t(cond);}
    static uint32_t branch(int from,int to){int32_t delta=to-from;if(delta<-(1<<25)||delta>=(1<<25))throw Error("branch out of range");return 0x14000000u|(uint32_t(delta)&0x03ffffffu);}
    void patchCond(size_t at,int cond,size_t target){code[at]=branchCond(cond,(int)at,(int)target);}
    void patchBranch(size_t at,size_t target){code[at]=branch((int)at,(int)target);}
    std::vector<size_t> epilogueAdds;
    void ret(const Expr& e){
        // A local array's storage lives in the frame: returning its address
        // hands the caller a dangling pointer, so reject it at compile time.
        if(e.k==Expr::Var){
            const int slot=lookup(e.name);
            if(slot>=0&&localArrayLength.count(slot))
                throw Error("cannot return a local array (its frame storage does not outlive the call): "+e.name);
        }
        const Ty retTy=currentReturnBool?Ty::Bool:(currentReturnPtr?Ty::Ptr:currentReturnType);
        if(tyIsStruct(retTy)){
            // A struct is built in memory and only then loaded into X0 (and
            // X1), because building it — a literal, a copy, or a call — can
            // clobber both registers on the way.
            const Ty actual=exprType(e);
            if(!(actual==retTy))
                throw Error("return type mismatch in function "+functionName+": expected "+
                            tyNameFull(retTy)+", got "+tyNameFull(actual));
            if(structInMemory(retTy)){
                // Larger than 16 bytes: the caller handed its buffer over in
                // X8, which the prologue saved, so the value goes straight
                // through it and the pointer comes back in X0 either way.
                loadStackOff(kGlobalBase,kSretSlot,Ty::I64);
                emitStructStore(e);
                loadStackOff(0,kSretSlot,Ty::I64);       // a nested call may have taken X8
            } else {
                emitAddOff(kGlobalBase,31,kRetBuf);
                emitStructStore(e);
                loadStackOff(0,kRetBuf,Ty::I64);
                if(tySize(retTy)>8)loadStackOff(1,kRetBuf+8,Ty::I64);
            }
        } else {
        const bool isPtr=exprIsPtr(e),isBool=exprIsBool(e);
        if(currentReturnBool){
            if(!isBool&&!isBoolConstant(e))
                throw Error("return type mismatch in function "+functionName+": expected bool");
        } else if(isPtr!=currentReturnPtr&&!(currentReturnPtr&&isNullConstant(e))){
            throw Error("return type mismatch in function "+functionName);
        } else if(isBool){
            throw Error("return type mismatch in function "+functionName+": expected i32, got bool");
        }
        int v=(currentReturnBool&&isBool)?genBool(e):gen(e,retTy);
        emit((tyIs64(retTy)||currentReturnPtr?0xaa0003e0u:0x2a0003e0u)|(uint32_t(v)<<16));releaseTemp(v);
        }
        if(isMain){emit(0xd2800000u|(93u<<5)|8u);emit(0xd4000001u);}
        else {emit(0xf94003feu|(uint32_t(1023)<<10)); // LDR X30, [SP, #8184]
            epilogueAdds.push_back(code.size());emit(0);emit(0xd65f03c0u);}
    }
    bool definitelyReturns(const std::vector<Stmt>& ss) const {
        for(const auto& s:ss){
            if(s.k==Stmt::Return)return true;
            if(s.k==Stmt::If&&definitelyReturns(s.thenBody)&&definitelyReturns(s.elseBody))return true;
        }
        return false;
    }
    void execStmt(const Stmt& s){
        // One row per statement: the instruction it begins at, and the line the
        // parser recorded for it. Nested bodies go through execStmt too, so a
        // row exists for every statement at every depth.
        if(emitLineInfo&&s.line!=0)lineRows.push_back({(uint32_t)code.size(),s.line});
        if(s.k==Stmt::Let){
                if(scopes.empty())scopes.emplace_back();
                if(scopes.back().count(s.name))throw Error(loc(s.line,s.col,"duplicate variable in scope: "+s.name));
                if(tyIsStruct(s.ty)&&!s.isArray){
                    // A struct local reserves ceil(size/8) eight-byte frame
                    // slots. Its name binds to the base slot and every use of
                    // it goes through emitStructAddr, which turns the name
                    // into an address — a struct has no register form.
                    const uint32_t size=tySize(s.ty);
                    const int slots=(int)((size+7u)/8u);
                    if(nextSlot+slots>kMaxLocals)
                        throw Error("too many local declarations (limit 500, including parameters)");
                    const int slot=nextSlot;nextSlot+=slots;
                    emit(addImm(kGlobalBase,31,(uint32_t)slot*8));
                    // v0.23.29-dev: a struct local without an initializer is
                    // zero-filled (the frame slots hold XZR), which is the
                    // shape a struct containing an array field takes — its
                    // array fields cannot be set by a literal. A struct literal
                    // initializer is folded as before.
                    if(s.expr)emitStructStore(*s.expr);
                    else for(int i=0;i<slots;++i)emit(0xf90003e0u|31u|((uint32_t(slot+i))<<10)); // STR XZR, [SP, #(slot+i)*8] — Rt must be XZR (31), not x0: a struct local is zeroed from the zero register, never from whatever x0 happens to hold
                    slotTypes[slot]=s.ty;pointerSlots[slot]=false;boolSlots[slot]=false;
                    scopes.back()[s.name]=slot;
                    // v0.23.32-dev: a struct local is one variable at its base slot.
                    if(emitLineInfo)debugVars.push_back({s.name,s.ty,slot,false,false,{},s.line});
                } else if(s.isArray){
                    // A local T[N] reserves ceil(N*sizeof(T)/8) frame slots, with the
                    // elements packed at their natural width: element i sits at byte
                    // offset slot*8 + i*sizeof(T). The element type is recorded in
                    // slotElemTypes so that every later c[i] read and write uses T's
                    // width. That record used to be missing entirely — elementTypeOf
                    // fell back to I32 for every local array, so `let c: i64[2]` and
                    // `let c: u32[2]` were laid out and addressed as i32 arrays. An
                    // i64 element lost its high word on the way to memory and an
                    // unsigned one was read back sign-extended; the tests that covered
                    // it only compared against constants that had been truncated the
                    // same way, so both sides were wrong together and the suite stayed
                    // green. One constant store per element initializes it at the
                    // declaration point (a let inside a loop re-runs each pass).
                    //
                    // v0.23.28-dev: T is any type now. A bool element is the
                    // 4-byte 0/1 slot a bool scalar has always been; a ptr
                    // element is 8 bytes and takes the null constant or any
                    // other address; a struct element is a copy of the
                    // initializer per element, at slot*8 + i*sizeof(T).
                    const Ty elem=s.ty;
                    const uint32_t esz=tySize(elem);
                    const uint32_t slots=(uint32_t)(((uint64_t)s.count*esz+7u)/8u);
                    if(nextSlot+(int)slots>kMaxLocals)
                        throw Error("local array '"+s.name+"' is too large: length "+std::to_string(s.count)+" exceeds the frame limit (1000 elements)");
                    const int slot=nextSlot;nextSlot+=(int)slots;
                    if(tyIsStruct(elem)){
                        // Every element receives a copy of the same aggregate —
                        // the fill an integer array has always done, at the
                        // element's own size instead of a register width.
                        for(uint32_t i=0;i<s.count;++i){
                            emitAddOff(kGlobalBase,31,uint32_t(slot*8)+i*esz);
                            emitStructStore(*s.expr);
                        }
                        pointerSlots[slot]=true;localArrayLength[slot]=s.dims[0];slotDims[slot]=s.dims;slotElemTypes[slot]=elem;scopes.back()[s.name]=slot;
                    // v0.23.32-dev: a local array is one variable whose type is an
                    // array of `elem`; its base slot is the address the name decays to.
                    if(emitLineInfo)debugVars.push_back({s.name,elem,slot,false,true,s.dims,s.line});
                        return;
                    }
                    int64_t value=0;
                    // A ptr element may be filled with an address, which no
                    // constant folder can produce; that path stores the
                    // register the address arrives in, one store per element.
                    const bool addrFill=(elem.k==Ty::Ptr)&&!constantInteger(*s.expr,value)&&exprIsPtr(*s.expr);
                    if(!addrFill){
                        if(!boolArrayValue(*s.expr,value))
                            throw Error("array initializer must be a constant expression: "+s.name);
                        // A bool literal fills a bool element and only a bool
                        // element — sema's rule, mirrored.
                        if(elem!=Ty::Bool&&exprIsBool(*s.expr))
                            throw Error("array initializer type mismatch: expected "+tyNameFull(elem)+", got bool: "+s.name);
                        // v0.23.27-dev: the range check sema applies to the same
                        // declaration, kept here as its defensive twin. (The
                        // masking below still truncates the value to the element
                        // width — that is the ordinary store path, and it now
                        // only ever sees a constant that fits.)
                        if(!initializerFits(elem,*s.expr,value))
                            throw Error("local array initializer does not fit in "+tyNameFull(elem)+": "+s.name+" ("+std::to_string(value)+")");
                    }
                    // The initializer is truncated to the element's width, exactly as a
                    // later c[i] = <literal> would be, and an i64 initializer is
                    // materialized at full width rather than folded to 32 bits.
                    const uint64_t init=(uint64_t)value&(esz>=8?~0ull:((1ull<<(esz*8u))-1ull));
                    // STR's imm12 is scaled by the access size, so the byte offset is
                    // divided by the element size; slot*8 is a multiple of 8 and
                    // i*esz of esz, so the division is always exact.
                    const uint32_t strBase=esz==1?0x39000000u:esz==2?0x79000000u:esz==8?0xf9000000u:0xb9000000u;
                    if(addrFill){
                        for(uint32_t i=0;i<s.count;++i){
                            const int v=gen(*s.expr,Ty::Ptr);   // the address first: X16 is the base
                            emitAddOff(kGlobalBase,31,uint32_t(slot*8)+i*esz);
                            emit(storeGlobalT(v,Ty::Ptr));      // STR Xv, [X16]
                            releaseTemp(v);
                        }
                        pointerSlots[slot]=true;localArrayLength[slot]=s.dims[0];slotDims[slot]=s.dims;slotElemTypes[slot]=elem;scopes.back()[s.name]=slot;
                    // v0.23.32-dev: a local array is one variable whose type is an
                    // array of `elem`; its base slot is the address the name decays to.
                    if(emitLineInfo)debugVars.push_back({s.name,elem,slot,false,true,s.dims,s.line});
                        return;
                    }
                    for(uint32_t i=0;i<s.count;++i){
                        const uint32_t imm=(uint32_t(slot*8)+i*esz)/esz;
                        if(init==0){emit(strBase|(imm<<10)|0x3e0u|31u);continue;} // STR[W|H|B] WZR / STR XZR
                        int d=temp();
                        if(esz==8){
                            emitMov64(d,init);
                        } else {
                            emit(0x52800000u|(((uint32_t)init&0xffffu)<<5)|uint32_t(d)); // MOVZ Wd, #low
                            if((uint32_t)init>>16)emit(0x72a00000u|((((uint32_t)init>>16)&0xffffu)<<5)|uint32_t(d)); // MOVK Wd, #high, LSL #16
                        }
                        emit(strBase|(imm<<10)|0x3e0u|uint32_t(d));
                        releaseTemp(d);
                    }
                    // The base slot carries the array length; the name decays to a ptr
                    // (its frame address) wherever a value is expected.
                    pointerSlots[slot]=true;localArrayLength[slot]=s.dims[0];slotDims[slot]=s.dims;slotElemTypes[slot]=elem;scopes.back()[s.name]=slot;
                    // v0.23.32-dev: a local array is one variable whose type is an
                    // array of `elem`; its base slot is the address the name decays to.
                    if(emitLineInfo)debugVars.push_back({s.name,elem,slot,false,true,s.dims,s.line});
                } else {
                    if(nextSlot>=kMaxLocals)throw Error("too many local declarations (limit 500)");
                    const bool actualPtr=exprIsPtr(*s.expr),actualBool=exprIsBool(*s.expr);
                    if(s.isBool){
                        if(!actualBool&&!isBoolConstant(*s.expr))
                            throw Error("type mismatch initializing '"+s.name+"': expected bool");
                    } else if(s.isPtr){
                        // v0.23.26-dev: `let p: ptr = 0;` — the null constant.
                        if(!actualPtr&&!isNullConstant(*s.expr))throw Error("type mismatch initializing '"+s.name+"': expected ptr");
                    } else {
                        if(actualPtr)throw Error("type mismatch initializing '"+s.name+"': expected i32, got ptr");
                        if(actualBool)throw Error("type mismatch initializing '"+s.name+"': expected i32, got bool");
                        // v0.23.27-dev: sema's range check, mirrored.
                        int64_t cv=0;
                        if(constantInteger(*s.expr,cv)&&!initializerFits(s.ty,*s.expr,cv))
                            throw Error("local initializer does not fit in "+tyNameFull(s.ty)+": "+s.name+" ("+std::to_string(cv)+")");
                    }
                    int slot=nextSlot++;
                    // A bool-initialized slot is materialized as 0/1 (genBool); a
                    // plain 0/1 constant goes through the ordinary i32 path.
                    int v=(s.isBool&&actualBool)?genBool(*s.expr):gen(*s.expr,s.ty);
                    emit(storeVarT(v,slot,s.ty));releaseTemp(v);
                    pointerSlots[slot]=s.isPtr;boolSlots[slot]=s.isBool;slotTypes[slot]=s.ty;scopes.back()[s.name]=slot;
                    // v0.23.37-dev: a fn-pointer local keeps its signature,
                    // keyed by frame slot, for an indirect call to consult.
                    if(s.isFunc){slotFuncSig[slot]=s.funcSig;slotIsFunc[slot]=true;}
                    // v0.23.34-dev: a `ptr<T>` local keeps the stride its
                    // declared element type names, so `p[i]` through the
                    // variable scales as `&arr` did at the point it was bound.
                    if(tyIsPtrToElem(s.ty))slotElemTypes[slot]=ptrElemType(s.ty);
                    // v0.23.32-dev: a scalar local, named and typed for the debugger.
                    if(emitLineInfo)debugVars.push_back({s.name,s.ty,slot,false,false,{},s.line});
                }
            } else if(s.k==Stmt::Assign){
                int slot=lookup(s.name);
                if(slot>=0){
                    if(localArrayLength.count(slot))throw Error("cannot assign to an array as a whole: "+s.name);
                    if(tyIsStruct(slotType(slot))){
                        emit(addImm(kGlobalBase,31,(uint32_t)slot*8));
                        emitStructStore(*s.expr);
                    } else {
                        const bool isPtr=pointerSlots.count(slot)&&pointerSlots.at(slot);
                        const bool isBool=boolSlots.count(slot)&&boolSlots.at(slot);
                        const bool actualPtr=exprIsPtr(*s.expr),actualBool=exprIsBool(*s.expr);
                        if(isBool){
                            if(!actualBool&&!isBoolConstant(*s.expr))throw Error("type mismatch assigning variable: "+s.name+" (expected bool)");
                        } else if(isPtr){
                            // v0.23.26-dev: `p = 0;` clears a pointer.
                            if(!actualPtr&&!isNullConstant(*s.expr))throw Error("type mismatch assigning variable: "+s.name);
                        } else {
                            if(actualPtr||actualBool)throw Error("type mismatch assigning variable: "+s.name);
                        }
                        int v=(isBool&&actualBool)?genBool(*s.expr):gen(*s.expr,slotType(slot));
                        emit(storeVarT(v,slot,slotType(slot)));releaseTemp(v);
                    }
                }
                else if(globals.count(s.name)){
                    if(arrayGlobals.count(s.name))throw Error(loc(s.line,s.col,"cannot assign to an array as a whole: "+s.name));
                    if(tyIsStruct(globalTypeOf(s.name))){
                        emitGlobalAddress(s.name);
                        emitStructStore(*s.expr);
                    } else {
                        const bool isBool=boolGlobals.count(s.name)!=0;
                        const bool actualBool=exprIsBool(*s.expr);
                        if(isBool&&!actualBool&&!isBoolConstant(*s.expr))throw Error("type mismatch assigning variable: "+s.name+" (expected bool)");
                        if(!isBool&&actualBool)throw Error("type mismatch assigning variable: "+s.name+" (expected i32)");
                        int v=(isBool&&actualBool)?genBool(*s.expr):gen(*s.expr,globalTypeOf(s.name));
                        emitGlobalAddress(s.name);emit(storeGlobalT(v,globalTypeOf(s.name)));releaseTemp(v);
                    }
                }
                else throw Error(loc(s.line,s.col,"assignment to unknown variable: "+s.name));
            } else if(s.k==Stmt::FieldAssign){
                // p.f = v : compute the value first (it may clobber x16), then
                // the field's address, then store through it. A struct-typed
                // field is a whole-struct copy through the same address.
                const Ty field=exprType(*s.idx);
                if(tyIsStruct(field)){
                    emitStructAddr(*s.idx);
                    emitStructStore(*s.expr);
                } else {
                    int v=(field==Ty::Bool&&exprIsBool(*s.expr))?genBool(*s.expr):gen(*s.expr,field);
                    emitStructAddr(*s.idx);
                    emit(storeGlobalT(v,field));
                    releaseTemp(v);
                }
            } else if(s.k==Stmt::IndexAssign){
                // v0.23.34-dev: `p[i] = v` where p is a typed pointer (an array
                // parameter, or a variable bound to `&arr`) is the localPtr
                // path below: the base slot holds the address, elementTypeOf
                // now answers the element's real type from slotElemTypes, and
                // emitElemIndex strides at that width — no separate branch.
                //
                // buf[i] = v : evaluate the index and the value first (either may clobber x16),
                // then materialize the base, add the scaled index, and store.
                const int slot=lookup(s.name);
                const bool localArray=slot>=0&&localArrayLength.count(slot)!=0;
                const bool localPtr=slot>=0&&!localArray&&pointerSlots.count(slot)&&pointerSlots.at(slot);
                if(slot>=0&&!localArray&&!localPtr)throw Error("cannot index non-array variable: "+s.name);
                if(!localArray&&!localPtr){
                    if(!globals.count(s.name))throw Error("assignment to unknown array: "+s.name);
                    if(!arrayGlobals.count(s.name))throw Error("cannot index non-array global: "+s.name);
                }
                checkArrayBounds(s.name,*s.idx);
                if(exprIsPtr(*s.idx))throw Error("pointer indexing is not supported yet");
                const Ty elem=elementTypeOf(s.name);
                // v0.23.28-dev: the value is checked against the element type
                // instead of being refused whenever it is an address. A ptr
                // stores into a `ptr[N]` (which is the point of one), and a
                // bool no longer lands in an i32 element as the integer 1.
                if(exprIsPtr(*s.expr)&&elem.k!=Ty::Ptr)
                    throw Error("type mismatch assigning array element of '"+s.name+"': expected "+tyNameFull(elem)+", got ptr");
                // v0.23.31-dev: two or more subscripts — the target is the
                // chain's own address, computed level by level, and the store
                // goes through it exactly as a one-dimensional element's does.
                if(s.idx->k==Expr::Index&&s.idx->name.empty()){
                    emitIndexAddr(*s.idx);
                    if(tyIsStruct(elem)){emitStructStore(*s.expr);return;}
                    int v=gen(*s.expr,elem);
                    emit(storeGlobalT(v,elem)); // STR <T>v, [X16]
                    releaseTemp(v);
                    return;
                }
                int r=gen(*s.idx);
                emitBoundsCheck(s.name,*s.idx,r);
                // v0.23.36-dev: an array parameter remembers its length — mirror the
                // check emitElemAddr does for reads. arrayLengthOf still returns 0 for
                // a parameter (so AddrOf typing is untouched), hence the explicit
                // paramArrayLength lookup here. The earlier emitBoundsCheck is a no-op
                // for parameters and the second one does the real work.
                if(!s.name.empty()){int aslot=lookup(s.name);
                    if(aslot>=0&&paramArrayLength.count(aslot)){
                        checkArrayBounds(paramArrayLength[aslot],*s.idx);
                        emitBoundsCheck(paramArrayLength[aslot],*s.idx,r);
                    }
                }
                // A struct element is a copy through its address — the same
                // store a struct variable takes — not a value in a register.
                if(tyIsStruct(elem)){
                    if(localPtr)emit(loadVar64(kGlobalBase,slot)); // LDR X16, [SP, #slot*8]
                    else if(localArray)emit(0x91000000u|(uint32_t(slot*8)<<10)|(31u<<5)|uint32_t(kGlobalBase)); // ADD X16, SP, #slot*8 (sh = 0)
                    else emitGlobalAddress(s.name);
                    emitElemIndex(r,elem);
                    releaseTemp(r);
                    emitStructStore(*s.expr);
                    return;
                }
                int v=gen(*s.expr,elem);
                if(localPtr)emit(loadVar64(kGlobalBase,slot)); // LDR X16, [SP, #slot*8]
                else if(localArray)emit(0x91000000u|(uint32_t(slot*8)<<10)|(31u<<5)|uint32_t(kGlobalBase)); // ADD X16, SP, #slot*8 (sh = 0)
                else emitGlobalAddress(s.name);
                emitElemIndex(r,elem);
                emit(storeGlobalT(v,elem)); // STR <T>v, [X16]
                releaseTemp(v);releaseTemp(r);
            } else if(s.k==Stmt::DerefAssign){
                if(!exprIsPtr(*s.idx))throw Error("dereference assignment requires a ptr expression");
                int address=gen(*s.idx);int value=gen(*s.expr);
                if(exprIsPtr(*s.expr))emit(0xf9000000u|(uint32_t(address)<<5)|uint32_t(value)); // STR Xt, [Xn] (ptr store)
                else emit(0xb9000000u|(uint32_t(address)<<5)|uint32_t(value)); // STR Wt, [Xn] (i32 store)
                releaseTemp(value);releaseTemp(address);
            } else if(s.k==Stmt::Expr){
                // v0.23.39-dev: a discarded call. Compute it (the callee's side
                // effects run) but drop the result — the register gen() returns
                // is the top of the temp pool, so it is released here the same
                // way an assignment releases the value it just stored.
                int d=gen(*s.expr);releaseTemp(d);
            } else if(s.k==Stmt::Return){ret(*s.expr);}
            else if(s.k==Stmt::If){
                size_t toElse;const int cond=emitCondition(*s.expr,toElse);
                block(s.thenBody,true);size_t toEnd=code.size();emit(0);patchCond(toElse,cond,(int)code.size());block(s.elseBody,true);patchBranch(toEnd,code.size());
            } else if(s.k==Stmt::Break){
                if(loops.empty()) throw Error("break used outside a loop");
                loops.back().breaks.push_back(code.size()); emit(0);
            } else if(s.k==Stmt::Continue){
                if(loops.empty()) throw Error("continue used outside a loop");
                loops.back().continues.push_back(code.size()); emit(0);
            } else if(s.k==Stmt::While){
                size_t loopStart=code.size();size_t toEnd;const int cond=emitCondition(*s.expr,toEnd);
                loops.push_back({loopStart,{},{}});block(s.thenBody,true);size_t back=code.size();emit(branch((int)back,(int)loopStart));size_t loopEnd=code.size();patchCond(toEnd,cond,(int)loopEnd);for(size_t at:loops.back().breaks)patchBranch(at,loopEnd);for(size_t at:loops.back().continues)patchBranch(at,loopStart);loops.pop_back();
            } else if(s.k==Stmt::For){
                // for (init; cond; step) body — observable semantics of
                // { init; while (cond) { body; step; } }: the initializer runs
                // once inside the loop's own scope (a let there is not visible
                // after the loop), the step sits between the body and the
                // back-edge, and continue branches to the step.
                scopes.emplace_back();
                for(const auto& init:s.forInit)execStmt(init);
                size_t loopStart=code.size();size_t toEnd;const int cond=emitCondition(*s.expr,toEnd);
                loops.push_back({loopStart,{},{}});block(s.thenBody,true);
                size_t stepAt=code.size();
                for(size_t at:loops.back().continues)patchBranch(at,stepAt);
                for(const auto& step:s.forStep)execStmt(step);
                size_t back=code.size();emit(branch((int)back,(int)loopStart));size_t loopEnd=code.size();
                patchCond(toEnd,cond,(int)loopEnd);   // same cond as while: branch out when the test is false
                for(size_t at:loops.back().breaks)patchBranch(at,loopEnd);
                loops.pop_back();
                scopes.pop_back();
            }
    }
    void block(const std::vector<Stmt>& ss, bool newScope=false){
        if(newScope)scopes.emplace_back();
        for(const auto&s:ss)execStmt(s);
        if(newScope)scopes.pop_back();
    }
    std::vector<uint32_t> run(const Function& f){
        if(!definitelyReturns(f.body))throw Error(functionName+" may fall through without returning "+(f.returnPtr?"ptr":f.returnBool?"bool":"i32")+"; add a return or make both if/else branches return");
        // The prologue belongs to the declaration, not to the first statement.
        if(emitLineInfo&&f.line!=0)lineRows.push_back({0u,f.line});
        scopes.emplace_back();
        currentReturnPtr=f.returnPtr;currentReturnBool=f.returnBool;currentReturnType=f.retType;
        // One frame slot per parameter, except a struct, which takes one per
        // eight bytes of its layout. Every parameter used to take exactly one,
        // and still does when it is not a struct, so the numbering of every
        // pre-existing function is unchanged.
        const ArgLayout lay=layoutArgs(f.paramTypes,f.params.size());
        int slot=0;
        for(size_t i=0;i<f.params.size();++i){
            const Ty pt=f.paramTypes[i];
            const int width=tyIsStruct(pt)?(int)((tySize(pt)+7u)/8u):1;
            if(slot+width>kMaxLocals)throw Error("too many parameters (limit 500, counted in eight-byte slots)");
            scopes.back()[f.params[i]]=slot;
            // v0.23.32-dev: a parameter is a variable at its own slot; a struct
            // one is named at its first slot, which is its address.
            if(emitLineInfo)debugVars.push_back({f.params[i],pt,slot,true,false,{},f.line});
            pointerSlots[slot]=f.paramPtr[i];boolSlots[slot]=i<f.paramBool.size()&&f.paramBool[i];slotTypes[slot]=pt;
            // v0.23.37-dev: a fn-pointer parameter keeps its signature, keyed
            // by frame slot, for an indirect call through it to consult.
            if(i<f.paramIsFunc.size()&&f.paramIsFunc[i]){slotFuncSig[slot]=f.paramFuncSig[i];slotIsFunc[slot]=true;}
            // v0.23.34-dev: an array parameter (`fn f(a: i32[4])`) is a slot
            // holding the array's address, typed to stride at the element's
            // real width. Recording the element type here is what makes
            // `a[i]` inside the body stride by sizeof(i32) rather than a
            // hard-coded 4 — and by 8 for an i64 parameter, 1 for a u8 one.
            if(tyIsPtrToElem(pt)){pointerSlots[slot]=true;slotElemTypes[slot]=ptrElemType(pt);
                // v0.23.36-dev: an array parameter remembers its dimensions, so a
                // subscript through it can be bounds-checked. slotDims feeds the
                // multi-dimensional chain (emitIndexAddr); paramArrayLength feeds the
                // single-dimensional read path (emitElemAddr's pointer branch) and the
                // write path (gen(Stmt::Assign)).
                if(i<f.paramDims.size()&&!f.paramDims[i].empty()){
                    slotDims[slot]=f.paramDims[i];
                    paramArrayLength[slot]=(uint32_t)dimsProduct(f.paramDims[i]);
                }
            }
            slot+=width;
        }
        nextSlot=slot;
        emit(0); // fixed 8 KiB frame: locals, caller-save spills, and nested call argument scratch
        if(!isMain) emit(0xf90003feu|(uint32_t(1023)<<10)); // STR X30, [SP, #8184]: preserve return address
        // A struct larger than 16 bytes is returned through the buffer the
        // caller handed over in X8. Every return writes through it, and X8 is
        // a scratch register a nested call is free to take, so it is saved.
        if(!isMain&&structInMemory(f.retType))storeStackOff(8,kSretSlot,Ty::I64);
        for(size_t i=0;i<f.params.size();++i){
            const Ty pt=f.paramTypes[i];
            const int pslot=scopes.back()[f.params[i]];
            const uint32_t pbase=uint32_t(pslot)*8u;
            if(tyIsStruct(pt)){
                // A struct parameter always arrives as memory the caller owns:
                // in registers it is one or two eight-byte halves to spill, and
                // on the stack or behind a pointer it is a copy to make.
                emit(addImm(17,31,pbase));
                if(lay.reg[i]>=0&&!structInMemory(pt)){
                    emit(storeVar64(lay.reg[i],pslot));
                    if(tySize(pt)>8)emit(storeVar64(lay.reg[i]+1,pslot+1));
                } else if(lay.reg[i]>=0){
                    emit(movX(kGlobalBase,lay.reg[i]));         // X16: the caller's copy
                    emitStructCopy(17,kGlobalBase,tySize(pt));
                } else if(structInMemory(pt)){
                    emit(0x91400bf0u);                          // ADD X16, SP, #8192
                    emit(loadIncomingArgT(lay.stackOff[i],Ty::I64));
                    emitStructCopy(17,kGlobalBase,tySize(pt));
                } else {
                    emit(0x91400bf0u);                          // ADD X16, SP, #8192
                    emit(addImm(kGlobalBase,kGlobalBase,lay.stackOff[i]));
                    emitStructCopy(17,kGlobalBase,argBytes(pt));
                }
                continue;
            }
            if(lay.reg[i]>=0)emit(storeVarT(lay.reg[i],pslot,pt));
            else {
                emit(0x91400bf0u); // ADD X16, SP, #8192: address incoming caller stack area
                const uint32_t incomingOffset=lay.stackOff[i];
                if(incomingOffset>16380)throw Error("incoming argument offset exceeds load range");
                emit(loadIncomingArgT(incomingOffset,pt));
                emit(storeVarT(16,pslot,pt));
            }
        }
        if(injectInit&&isMain){size_t at=code.size();emit(0x94000000u);relocations.push_back({uint64_t(at)*4,initSymbol,kRelCall26});}
        block(f.body);
        if(nextTemp!=0)throw Error("internal compiler error: temporary register leak");
        if(nextSlot>kMaxLocals)throw Error("too many local declarations (limit 500, including parameters)");
        code[0]=0xd1400bffu; // SUB SP, SP, #8192
        for(size_t at:epilogueAdds)code[at]=0x91400bffu; // ADD SP, SP, #8192
        return code;
    }

};
#pragma pack(push,1)
struct Ehdr{unsigned char ident[16];uint16_t type,machine;uint32_t version;uint64_t entry,phoff,shoff;uint32_t flags;uint16_t ehsize,phentsize,phnum,shentsize,shnum,shstrndx;};
struct Phdr{uint32_t type,flags;uint64_t offset,vaddr,paddr,filesz,memsz,align;};
struct Shdr{uint32_t name,type;uint64_t flags,addr,offset,size;uint32_t link,info;uint64_t addralign,entsize;};
struct Sym{uint32_t name;uint8_t info,other;uint16_t shndx;uint64_t value,size;};
#pragma pack(pop)
void initIdent(Ehdr& h,uint16_t type){std::memcpy(h.ident,"\x7f""ELF",4);h.ident[4]=2;h.ident[5]=1;h.ident[6]=1;h.type=type;h.machine=183;h.version=1;h.ehsize=sizeof(Ehdr);}
std::vector<uint8_t> instructionBytes(const std::vector<uint32_t>& ins){
    std::vector<uint8_t> bytes; bytes.reserve(ins.size()*4);
    for(uint32_t w:ins){bytes.push_back(uint8_t(w));bytes.push_back(uint8_t(w>>8));bytes.push_back(uint8_t(w>>16));bytes.push_back(uint8_t(w>>24));}
    return bytes;
}
std::string elfNameOf(const std::string& n){return n=="main"?std::string("_start"):n;}
// One source-level symbol destined for a final image. kind selects the owning section:
// 0 = .text (STT_FUNC), 1 = .data (STT_OBJECT), 2 = .bss (STT_OBJECT). off is the offset inside
// that section and size becomes st_size (4 for an i32 scalar, 4*length for an i32[length] array).
struct OutSym { std::string name; int kind; uint64_t off; uint64_t size; };
struct SymTable { std::vector<Sym> syms; std::string strtab; };
SymTable buildSymbolTable(const std::vector<OutSym>& in,uint64_t textVaddr,uint64_t dataVaddr,uint64_t bssVaddr,
                          uint16_t idxText,uint16_t idxData,uint16_t idxBss,uint64_t rodataVaddr=0,uint16_t idxRodata=0){
    SymTable t; t.strtab.assign(1,'\0');
    std::map<std::string,uint32_t> seen;
    auto addName=[&](const std::string& n)->uint32_t{auto it=seen.find(n);if(it!=seen.end())return it->second;
        uint32_t o=(uint32_t)t.strtab.size();t.strtab+=n;t.strtab.push_back('\0');seen[n]=o;return o;};
    t.syms.resize(1+in.size());
    for(size_t i=0;i<in.size();++i){const OutSym& s=in[i];Sym& y=t.syms[i+1];
        y.name=addName(s.name);y.info=uint8_t(s.kind==0?0x12:0x11);y.other=0;
        if(s.kind==0){y.shndx=idxText;y.value=textVaddr+s.off;}
        else if(s.kind==1){y.shndx=idxData;y.value=dataVaddr+s.off;}
        else if(s.kind==3){y.shndx=idxRodata;y.value=rodataVaddr+s.off;}
        else{y.shndx=idxBss;y.value=bssVaddr+s.off;}
        y.size=s.size;}
    return t;
}
// Fixed-address ET_EXEC: segment 0 is R+X and holds the ELF header, program headers and .text at
// 0x401000. When the program has data, segment 1 is R+W and starts on the next page boundary; a
// zero-filesz PT_LOAD carries .bss when only zero-initialized globals exist.
//
// A source-level .symtab/.strtab pair and the section header table that describes the image are
// appended after the last loaded byte. Nothing that the loader reads moves: the program headers,
// the entry point, every segment's FileSiz/MemSiz/VirtAddr/Flags/Align and all text/data bytes are
// exactly what v0.16.0 produced. Only the previously zero e_shoff/e_shentsize/e_shnum/e_shstrndx
// header fields change, which is what makes the section table reachable.
// v0.23.33-dev: the two encodings .eh_frame is made of — a ULEB128 and a
// little-endian 32-bit field. Defined here, ahead of every ELF writer, because
// an .eh_frame_header is written by the same writers that carry the table.
static void ehUleb(std::vector<uint8_t>& o,uint64_t v){do{uint8_t b=uint8_t(v&0x7fu);v>>=7;if(v)b|=0x80u;o.push_back(b);}while(v);}
static void ehPut32(std::vector<uint8_t>& o,uint32_t v){for(int i=0;i<4;++i)o.push_back(uint8_t(v>>(8*i)));}
void writeElfBytes(const std::string& path,const std::vector<uint8_t>& text,uint64_t entryOffset,
                   const std::vector<uint8_t>& data,uint64_t bssSize,uint64_t base=0x400000,uint16_t etype=2,
                   const std::vector<OutSym>& symbols={},uint64_t dataAlign=4,uint64_t bssAlign=4,
                   const std::vector<uint8_t>& rodata={},uint64_t rodataAlign=1,
                   const std::vector<uint8_t>& debugLine={},
                   const std::vector<uint8_t>& debugInfo={},const std::vector<uint8_t>& debugAbbrev={},
                   const std::vector<uint8_t>& ehFrame={},
                   const std::vector<std::pair<uint64_t,uint64_t>>& ehFramePatches={},
                   const std::vector<std::pair<uint64_t,uint64_t>>& ehFrameFdes={}){
    constexpr uint64_t off=0x1000;
    if(text.empty()||entryOffset>=text.size()||(entryOffset%4)!=0)throw Error("invalid entry offset for executable");
    if(base%0x1000)throw Error("internal error: executable base must be page aligned");
    const uint64_t textFileEnd=off+text.size();
    const bool hasRodataSection=!rodata.empty();
    const uint64_t rodataFileOff=hasRodataSection?alignUp(textFileEnd,0x1000):0;
    const uint64_t rodataVaddr=hasRodataSection?base+rodataFileOff:0;
    const uint64_t afterRodata=hasRodataSection?rodataFileOff+rodata.size():textFileEnd;
    const bool hasData=!data.empty()||bssSize>0;
    const bool hasDataSection=!data.empty();
    const bool hasBssSection=bssSize>0;
    uint64_t dataFileOff=0,dataVaddr=0;
    if(hasData){dataFileOff=alignUp(afterRodata,0x1000);dataVaddr=base+dataFileOff;}
    // v0.23.32-dev: .debug_info and .debug_abbrev, numbered after .debug_line.
    const bool hasDebugLine=!debugLine.empty();
    const bool hasDebugInfo=!debugInfo.empty();
    uint16_t next=2,idxRodata=0,idxData=0,idxBss=0,idxDebugLine=0,idxDebugAbbrev=0,idxDebugInfo=0;
    if(hasRodataSection)idxRodata=next++;
    if(hasDataSection)idxData=next++;
    if(hasBssSection)idxBss=next++;
    if(hasDebugLine)idxDebugLine=next++;
    if(hasDebugInfo){idxDebugAbbrev=next++;idxDebugInfo=next++;}
    // v0.23.33-dev: .eh_frame and its header, numbered after the debug sections.
    const bool hasEhFrame=!ehFrame.empty();
    uint16_t idxEhFrame=0,idxEhFrameHdr=0;
    if(hasEhFrame){idxEhFrame=next++;idxEhFrameHdr=next++;}
    const uint16_t idxText=1,idxSym=next++,idxStr=next++,idxShstr=next++,shnum=next;
    const SymTable st=buildSymbolTable(symbols,base+off,dataVaddr,dataVaddr+data.size(),idxText,idxData,idxBss,rodataVaddr,idxRodata);
    const std::string shstr(std::string("\0.text",6)+(hasRodataSection?std::string("\0.rodata",8):std::string())
        +(hasDataSection?std::string("\0.data",6):std::string())+(hasBssSection?std::string("\0.bss",5):std::string())+std::string("\0.symtab",8)
        +std::string("\0.strtab",8)+std::string("\0.shstrtab",10)+(hasDebugLine?std::string("\0.debug_line",12):std::string())
        +(hasDebugInfo?std::string("\0.debug_abbrev",15)+std::string("\0.debug_info",13):std::string())
        +(hasEhFrame?std::string("\0.eh_frame",10)+std::string("\0.eh_frame_hdr",15):std::string())+std::string("\0",1));
    auto nameAt=[&](const char* want)->uint32_t{size_t i=0;while(i<shstr.size()){std::string cur=shstr.c_str()+i;if(cur==want)return (uint32_t)i;i+=cur.size()+1;}throw Error("internal ELF layout error: missing section name");};
    const uint64_t tailStart=hasData?dataFileOff+data.size():(hasRodataSection?rodataFileOff+rodata.size():textFileEnd);
    const uint64_t debugLineOff=hasDebugLine?alignUp(tailStart,8):0;
    const uint64_t afterDebugLine=hasDebugLine?debugLineOff+debugLine.size():tailStart;
    const uint64_t debugAbbrevOff=hasDebugInfo?alignUp(afterDebugLine,8):0;
    const uint64_t debugInfoOff=hasDebugInfo?alignUp(debugAbbrevOff+debugAbbrev.size(),8):0;
    const uint64_t afterDebugInfo=hasDebugInfo?debugInfoOff+debugInfo.size():afterDebugLine;
    // The unwind table has to be readable at run time, so it rides in a PT_LOAD
    // of its own — a PT_GNU_EH_FRAME that pointed outside every loadable
    // segment would be invisible to an unwinder that maps the image.
    const uint64_t ehFrameOff=hasEhFrame?alignUp(afterDebugInfo,0x1000):0,ehFrameVaddr=hasEhFrame?base+ehFrameOff:0;
    const uint64_t ehFrameHdrOff=hasEhFrame?alignUp(ehFrameOff+ehFrame.size(),8):0,ehFrameHdrVaddr=hasEhFrame?base+ehFrameHdrOff:0;
    // An FDE says where its function is with a displacement from the field that
    // says it, so the table has to be at its final address before a single one
    // of them can be filled in. That is the whole reason the patches travel
    // with the bytes: only this function knows where the section lands.
    std::vector<uint8_t> ehFrameOut=ehFrame;
    for(const auto& p:ehFramePatches){
        if(p.first+4>ehFrameOut.size())throw Error("internal error: .eh_frame address patch is out of bounds");
        const int64_t disp=(int64_t)p.second-(int64_t)(ehFrameVaddr+p.first);
        if(disp<-2147483648ll||disp>2147483647ll)throw Error("internal error: .eh_frame displacement does not fit in 32 bits");
        for(int i=0;i<4;++i)ehFrameOut[(size_t)p.first+(size_t)i]=uint8_t((uint32_t)disp>>(8*i));
    }
    std::vector<uint8_t> ehFrameHdr;
    if(hasEhFrame){
        ehFrameHdr.push_back(1);                       // version
        ehFrameHdr.push_back(0x1b);                    // eh_frame_ptr: pcrel sdata4
        ehFrameHdr.push_back(0x03);                    // fde_count: udata4
        ehFrameHdr.push_back(0x3b);                    // table: datarel sdata4
        // Every displacement is from the field that holds it, or from the start
        // of this header for the table, which is what "datarel" means here.
        ehPut32(ehFrameHdr,(uint32_t)((int64_t)ehFrameVaddr-(int64_t)(ehFrameHdrVaddr+4)));
        ehPut32(ehFrameHdr,(uint32_t)ehFrameFdes.size());
        std::vector<std::pair<uint64_t,uint64_t>> sorted=ehFrameFdes;
        std::sort(sorted.begin(),sorted.end());
        for(const auto& e:sorted){
            ehPut32(ehFrameHdr,(uint32_t)((int64_t)e.first-(int64_t)ehFrameHdrVaddr));
            ehPut32(ehFrameHdr,(uint32_t)((int64_t)(ehFrameVaddr+e.second)-(int64_t)ehFrameHdrVaddr));
        }
    }
    const uint64_t ehFrameEnd=hasEhFrame?ehFrameHdrOff+ehFrameHdr.size():afterDebugInfo;
    const uint64_t symOff=alignUp(ehFrameEnd,8),symSize=uint64_t(st.syms.size())*sizeof(Sym);
    const uint64_t strOff=symOff+symSize,shstrOff=strOff+st.strtab.size();
    const uint64_t shoff=alignUp(shstrOff+shstr.size(),8);
    Ehdr h{};initIdent(h,etype);h.entry=base+off+entryOffset;h.phoff=sizeof(Ehdr);h.phentsize=sizeof(Phdr);h.phnum=(uint16_t)(1+(hasRodataSection?1:0)+(hasData?1:0)+(hasEhFrame?2:0));
    h.shoff=shoff;h.shentsize=sizeof(Shdr);h.shnum=shnum;h.shstrndx=idxShstr;
    Phdr p{};p.type=1;p.flags=5;p.offset=0;p.vaddr=base;p.paddr=base;p.filesz=textFileEnd;p.memsz=textFileEnd;p.align=0x1000;
    Phdr r{};if(hasRodataSection){r.type=1;r.flags=4;r.offset=rodataFileOff;r.vaddr=rodataVaddr;r.paddr=rodataVaddr;r.filesz=rodata.size();r.memsz=rodata.size();r.align=0x1000;}
    Phdr d{};if(hasData){d.type=1;d.flags=6;d.offset=dataFileOff;d.vaddr=dataVaddr;d.paddr=dataVaddr;d.filesz=data.size();d.memsz=data.size()+bssSize;d.align=0x1000;}
    // PT_LOAD covering both unwind sections, and PT_GNU_EH_FRAME naming the
    // header inside it — the pair an unwinder looks for.
    Phdr ef{};if(hasEhFrame){ef.type=1;ef.flags=4;ef.offset=ehFrameOff;ef.vaddr=ehFrameVaddr;ef.paddr=ehFrameVaddr;ef.filesz=ehFrameEnd-ehFrameOff;ef.memsz=ehFrameEnd-ehFrameOff;ef.align=0x1000;}
    Phdr efh{};if(hasEhFrame){efh.type=0x6474e550u;efh.flags=4;efh.offset=ehFrameHdrOff;efh.vaddr=ehFrameHdrVaddr;efh.paddr=ehFrameHdrVaddr;efh.filesz=ehFrameHdr.size();efh.memsz=ehFrameHdr.size();efh.align=4;}
    std::vector<Shdr> sh(shnum);
    sh[idxText].name=nameAt(".text");sh[idxText].type=1;sh[idxText].flags=0x6;sh[idxText].addr=base+off;sh[idxText].offset=off;sh[idxText].size=text.size();sh[idxText].addralign=4;
    if(hasRodataSection){Shdr& e=sh[idxRodata];e.name=nameAt(".rodata");e.type=1;e.flags=0x2;e.addr=rodataVaddr;e.offset=rodataFileOff;e.size=rodata.size();e.addralign=rodataAlign;}
    if(hasDataSection){Shdr& e=sh[idxData];e.name=nameAt(".data");e.type=1;e.flags=0x3;e.addr=dataVaddr;e.offset=dataFileOff;e.size=data.size();e.addralign=dataAlign;}
    if(hasBssSection){Shdr& e=sh[idxBss];e.name=nameAt(".bss");e.type=8;e.flags=0x3;e.addr=dataVaddr+data.size();e.offset=tailStart;e.size=bssSize;e.addralign=bssAlign;}
    {Shdr& e=sh[idxSym];e.name=nameAt(".symtab");e.type=2;e.offset=symOff;e.size=symSize;e.link=idxStr;e.info=st.syms.size()>1?1u:0u;e.addralign=8;e.entsize=sizeof(Sym);}
    {Shdr& e=sh[idxStr];e.name=nameAt(".strtab");e.type=3;e.offset=strOff;e.size=st.strtab.size();e.addralign=1;}
    {Shdr& e=sh[idxShstr];e.name=nameAt(".shstrtab");e.type=3;e.offset=shstrOff;e.size=shstr.size();e.addralign=1;}
    if(hasDebugLine){Shdr& e=sh[idxDebugLine];e.name=nameAt(".debug_line");e.type=1;e.offset=debugLineOff;e.size=debugLine.size();e.addralign=1;}
    if(hasDebugInfo){
        {Shdr& e=sh[idxDebugAbbrev];e.name=nameAt(".debug_abbrev");e.type=1;e.offset=debugAbbrevOff;e.size=debugAbbrev.size();e.addralign=1;}
        {Shdr& e=sh[idxDebugInfo];e.name=nameAt(".debug_info");e.type=1;e.offset=debugInfoOff;e.size=debugInfo.size();e.addralign=1;}
    }
    if(hasEhFrame){
        {Shdr& e=sh[idxEhFrame];e.name=nameAt(".eh_frame");e.type=1;e.flags=0x2;e.addr=ehFrameVaddr;e.offset=ehFrameOff;e.size=ehFrame.size();e.addralign=4;}
        {Shdr& e=sh[idxEhFrameHdr];e.name=nameAt(".eh_frame_hdr");e.type=1;e.flags=0x2;e.addr=ehFrameHdrVaddr;e.offset=ehFrameHdrOff;e.size=ehFrameHdr.size();e.addralign=4;}
    }
    std::ofstream o(path,std::ios::binary);if(!o)throw Error("cannot create output: "+path);
    auto pad=[&](uint64_t target){auto pos=(uint64_t)o.tellp();if(pos>target)throw Error("internal ELF layout error");std::vector<char> z((size_t)(target-pos),0);if(!z.empty())o.write(z.data(),z.size());};
    o.write((char*)&h,sizeof h);o.write((char*)&p,sizeof p);if(hasRodataSection)o.write((char*)&r,sizeof r);if(hasData)o.write((char*)&d,sizeof d);
    if(hasEhFrame){o.write((char*)&ef,sizeof ef);o.write((char*)&efh,sizeof efh);}
    pad(off);
    o.write((const char*)text.data(),text.size());
    if(hasRodataSection){pad(rodataFileOff);o.write((const char*)rodata.data(),rodata.size());}
    if(hasData){pad(dataFileOff);if(!data.empty())o.write((const char*)data.data(),data.size());}
    if(hasDebugLine){pad(debugLineOff);o.write((const char*)debugLine.data(),debugLine.size());}
    if(hasDebugInfo){pad(debugAbbrevOff);o.write((const char*)debugAbbrev.data(),debugAbbrev.size());
        pad(debugInfoOff);o.write((const char*)debugInfo.data(),debugInfo.size());}
    if(hasEhFrame){pad(ehFrameOff);o.write((const char*)ehFrameOut.data(),ehFrameOut.size());
        pad(ehFrameHdrOff);o.write((const char*)ehFrameHdr.data(),ehFrameHdr.size());}
    pad(symOff);o.write((const char*)st.syms.data(),(std::streamsize)symSize);
    o.write(st.strtab.data(),(std::streamsize)st.strtab.size());o.write(shstr.data(),(std::streamsize)shstr.size());
    pad(shoff);o.write((const char*)sh.data(),(std::streamsize)(shnum*sizeof(Shdr)));
    if(!o)throw Error("failed writing ELF executable");
    o.close();
    if(!o)throw Error("failed closing ELF executable: "+path);
    if(::chmod(path.c_str(),0755)!=0)throw Error("cannot mark ELF executable as executable: "+path+": "+std::strerror(errno));
}
#pragma pack(push,1)
struct Rela { uint64_t offset,info; int64_t addend; };
#pragma pack(pop)
// debugVars (v0.23.32-dev): the function's parameters and locals, for .debug_info.
struct CompiledFunction { std::string name; std::vector<uint32_t> code; std::vector<Codegen::Reloc> relocs; std::vector<Codegen::LineRow> lineRows; std::vector<DebugVar> debugVars;
    // v0.23.33-dev: this body's prologue stored X30 at the top of its frame, so
    // an .eh_frame FDE may say where the return address lives. main does not
    // (it exits instead of returning), and neither does a body generated for a
    // shared object, where main is an ordinary function that does return.
    bool preservesRa=false; };
// The internal global-initializer symbol that _start calls, and the symbol each object's
// initializer uses to chain to the next object's initializer in link order (resolution is done
// by linkObjects; a trailing RET is synthesized as __aster_init_end).
constexpr const char* kInitSymbol="__aster_init";
constexpr const char* kInitNextSymbol="__aster_init_next";
// Conservative "does this expression produce a ptr?" test used for global
// runtime initializers: globals are i32/i32[] storage, so a pointer-typed
// initializer would silently keep only the low 32 bits of an address.
static bool exprYieldsPtr(const Expr& e,const std::set<std::string>& ptrReturnFns,const std::set<std::string>& arrayNames){
    switch(e.k){
        case Expr::String:return true;
        case Expr::Embed:return true;
        case Expr::Deref:return true;
        case Expr::Var:return arrayNames.count(e.name)!=0;
        case Expr::Call:return ptrReturnFns.count(e.name)!=0;
        case Expr::Add:case Expr::Sub:return exprYieldsPtr(*e.a,ptrReturnFns,arrayNames)||exprYieldsPtr(*e.b,ptrReturnFns,arrayNames);
        case Expr::SizeOf: case Expr::Len: return false;   // v0.23.35-dev: a folded i32 constant
        default:return false;
    }
}
// ===========================================================================
// Semantic pass (v0.23.0-dev, P3.1)
//
// Type checking used to live inside Codegen, interleaved with instruction
// selection: "what type is this expression?" was answered by walking the very
// maps codegen fills in as it emits, so a rejected program might already have
// produced half a function. This pass decides the question first — over the
// whole AST, with its own scope stack, before a single byte is emitted.
//
// The rules and the diagnostic texts are deliberately identical to the ones
// codegen applied. Codegen keeps its own checks as a defensive backstop, so a
// rule can be duplicated but never silently dropped: every pre-existing
// program still compiles to exactly the same bytes, and every pre-existing
// rejection still reports the same message.
// ===========================================================================
// `Ty` is declared above the AST (see "Value types"): the parser, this pass and
// codegen all read the same enumeration.
struct Sema {
    // A local binding. `len > 0` marks a local T[len]: its name is a value of
    // type ptr (the frame address) wherever an expression uses it, exactly as
    // codegen treats the array's base slot. v0.23.28-dev carries the element
    // type alongside, because `a[i]` is a value of *that* type — answering
    // i32 for every subscript (which is what this pass used to do) is what
    // made `let x: i32 = i64arr[0]` look like a widening and `pts[0].f` look
    // like a field read off an i32.
    struct Binding { Ty ty=Ty::I32; uint32_t len=0; Ty elem=Ty::I32; std::vector<uint32_t> dims;
        // v0.23.37-dev: a fn-pointer binding carries its signature beside the
        // storage type Ty::Ptr, so an indirect call can check arity/argument
        // types and pick the right staging width and return width.
        FuncSig funcSig; bool isFunc=false; };
    const std::map<std::string,size_t>& arities;
    const std::set<std::string>& globalNames;
    const std::set<std::string>& externFunctions;
    const std::set<std::string>& arrayGlobals;
    const std::set<std::string>& boolGlobals;
    const std::set<std::string>& pointerReturnFunctions;
    const std::set<std::string>& boolReturnFunctions;
    const std::map<std::string,std::vector<bool>>& paramPointers;
    const std::map<std::string,std::vector<bool>>& paramBools;
    const std::map<std::string,uint32_t>& arrayLengths;
    // v0.23.31-dev: every file-scope array's full dimension list, outermost
    // first. `arrayLengths` answers only the outer length, which is all a
    // one-dimensional array ever needed; a subscript on a subscript needs the
    // inner ones too.
    const std::map<std::string,std::vector<uint32_t>>& arrayDims;
    // v0.23.5-dev (P3.3): the declared type of every global, parameter and
    // return value. The bool flags above answer "is it a pointer?" and "is it a
    // bool?", which a struct type answers too — but they cannot say *which*
    // struct, so the checks that need that read it from here.
    const std::map<std::string,Ty>& globalTypes;
    const std::map<std::string,std::vector<Ty>>& paramTypes;
    const std::map<std::string,Ty>& returnTypes;
    // v0.23.37-dev: the signature of every fn-pointer global. A local or
    // parameter carries its own (in Binding.funcSig); a global's is looked up
    // here, because find() only walks the local/parameter scopes.
    const std::map<std::string,FuncSig>& globalFuncSig;
    // v0.23.38-dev: the signature a *function* hands back when its return type
    // is `fn(...)` (by name), and the signature each of its parameters asks
    // for (by name and position). Both parallel returnTypes / paramTypes: only
    // entries that spell a function type are present, so a missing entry means
    // "a bare ptr, nothing to check".
    const std::map<std::string,FuncSig>& returnFuncSig;
    const std::map<std::string,std::vector<ParamSig>>& paramFuncSig;
    std::string fn; bool retPtr=false,retBool=false; Ty retType=Ty::I32;
    bool retIsFunc=false; FuncSig retFuncSig;
    std::vector<std::map<std::string,Binding>> scopes;
    int loopDepth=0;

    Sema(const std::map<std::string,size_t>& ar,const std::set<std::string>& gn,const std::set<std::string>& ef,
         const std::set<std::string>& ag,const std::set<std::string>& bg,
         const std::set<std::string>& prf,const std::set<std::string>& brf,
         const std::map<std::string,std::vector<bool>>& pp,const std::map<std::string,std::vector<bool>>& pb,
         const std::map<std::string,uint32_t>& al,
         const std::map<std::string,std::vector<uint32_t>>& ad,
         const std::map<std::string,Ty>& gt,const std::map<std::string,std::vector<Ty>>& pt,
         const std::map<std::string,Ty>& rt,const std::map<std::string,FuncSig>& gfs,
         const std::map<std::string,FuncSig>& rfs,
         const std::map<std::string,std::vector<ParamSig>>& pfs)
      : arities(ar),globalNames(gn),externFunctions(ef),arrayGlobals(ag),boolGlobals(bg),
        pointerReturnFunctions(prf),boolReturnFunctions(brf),paramPointers(pp),paramBools(pb),arrayLengths(al),
        arrayDims(ad),
        globalTypes(gt),paramTypes(pt),returnTypes(rt),globalFuncSig(gfs),returnFuncSig(rfs),paramFuncSig(pfs){}

    const Binding* find(const std::string& n) const {
        for(auto it=scopes.rbegin();it!=scopes.rend();++it){
            auto f=it->find(n);
            if(f!=it->end())return &f->second;
        }
        return nullptr;
    }
    // v0.23.37-dev: the signature of a fn-pointer name, or null when it is a
    // bare ptr (which keeps the legacy untyped indirect-call behaviour). A
    // local or parameter carries its own signature in its Binding; a global's
    // lives in globalFuncSig, since find() walks only the local scopes.
    const FuncSig* funcSigOf(const std::string& n) const {
        if(const Binding* b=find(n)){ if(b->isFunc) return &b->funcSig; }
        auto it=globalFuncSig.find(n);
        if(it!=globalFuncSig.end())return &it->second;
        return nullptr;
    }
    // v0.23.38-dev: the signature a *value* carries, wherever it came from.
    // Three sources, in the order they are tried:
    //   - a declared fn-pointer: a local/parameter Binding, a global, or
    //     (new here) a struct field — each carries the signature it was
    //     declared with;
    //   - a function's own name in a value position: the signature is its
    //     parameter list and return type, which is what makes `h.onClick =
    //     inc` checkable and not merely "both sides are ptr";
    //   - a call to a function whose return type is `fn(...)`.
    // Anything else (a bare ptr, a literal, an arithmetic result) answers
    // null, and null means unchecked — the v0.23.37-dev rule for a value no
    // signature is known for.
    bool funcSigOfExpr(const Expr& e,FuncSig& out){
        switch(e.k){
            case Expr::Var: {
                if(const FuncSig* fs=funcSigOf(e.name)){out=*fs;return true;}
                // A function's name is its address, and its declaration is its
                // signature. An extern one has no address Aster may hand out
                // (typeOf refuses it), so it has no signature here either.
                if(!arities.count(e.name)||externFunctions.count(e.name))return false;
                auto pt=paramTypes.find(e.name);
                if(pt==paramTypes.end())return false;
                auto rt=returnTypes.find(e.name);
                out.params=pt->second;
                out.ret=rt==returnTypes.end()?Ty::I32:rt->second;
                return true;
            }
            case Expr::Field: {
                const Ty base=typeOf(*e.a);
                const int sid=structBaseId(base,e.name);
                if(const StructField* f=structOf(sid).find(e.name))
                    if(f->isFunc){out=f->funcSig;return true;}
                return false;
            }
            case Expr::Call: {
                auto it=returnFuncSig.find(e.name);
                if(it!=returnFuncSig.end()){out=it->second;return true;}
                return false;
            }
            default: return false;
        }
    }
    // Two signatures are compatible when they are the same signature: the
    // parameter types one for one, and the return type. A fn-pointer is a bare
    // address at run time, so a mismatch the language waved through would be
    // a call staged the wrong way with no diagnostic anywhere.
    static bool sigEqual(const FuncSig& a,const FuncSig& b){
        if(!(a.ret==b.ret))return false;
        if(a.params.size()!=b.params.size())return false;
        for(size_t i=0;i<a.params.size();++i)if(!(a.params[i]==b.params[i]))return false;
        return true;
    }
    static std::string sigName(const FuncSig& s){
        std::string r="fn(";
        for(size_t i=0;i<s.params.size();++i){
            if(i)r+=", ";
            r+=tyNameFull(s.params[i]);
        }
        return r+") -> "+tyNameFull(s.ret);
    }
    // May a value carrying `e`'s signature be stored where `toSig` is asked
    // for? A slot with no signature takes anything (a bare ptr keeps the
    // v0.23.37-dev behaviour), and a value with no known signature is
    // unchecked — which is what keeps an ordinary ptr assignment working.
    void checkPtrSig(const FuncSig* toSig,const Expr& e,const std::string& what){
        if(!toSig)return;
        FuncSig from;
        if(!funcSigOfExpr(e,from))return;
        if(!sigEqual(*toSig,from))
            throw Error(loc(e.line,e.col,what+": expected "+sigName(*toSig)+", got "+sigName(from)));
    }
    // The only bool literals are 0 and 1; there are no true/false keywords.
    static bool isBoolConstant(const Expr& e){
        int64_t v=0;return constantInteger(e,v)&&(v==0||v==1);
    }
    // A struct value has no arithmetic, no ordering and no truthiness: it is
    // read and written field by field, and moved around as a whole.
    static void rejectStruct(Ty t,const char* what){
        if(tyIsStruct(t))throw Error(std::string("cannot use a struct value (")+tyName(t)+") in "+what);
    }
    // v0.23.17-dev: `%`, the shifts and the bitwise operators are not defined
    // on a pointer. Bit-masking an address is the classic way to smuggle
    // pointer arithmetic into a language that forbids it, and Aster forbids it
    // deliberately — so the refusal says which operator, as the struct one does.
    static void rejectPtr(Ty t,const char* what){
        if(t==Ty::Ptr)throw Error(std::string("cannot use a pointer in ")+what);
    }
    // v0.23.25-dev: arithmetic and bitwise operators take integer operands.
    // While bool had no literal of its own this was unreachable by spelling —
    // only a comparison result could produce a bool value, and `(a < b) + 1`
    // slipped through as an accident nobody had a reason to write. true/false
    // make the question real, and the answer is no: bool is not an integer,
    // and `1 + true` computing 2 would be exactly the silent trap the
    // bool/i32 separation exists to prevent.
    static void rejectBool(Ty t,const char* what){
        if(t==Ty::Bool)throw Error(std::string("cannot use a bool value in ")+what);
    }
    // A ptr<S> slot accepts a ptr<S> to the same struct, or an untyped ptr:
    // the ABI is one 64-bit address either way, and a C function handing Aster
    // a void* is the common case. A pointer to a *different* struct is
    // rejected — it carries a layout, and it is the wrong one.
    // v0.23.26-dev: `from` may also be the null pointer constant (the literal
    // `0`), which is assignable to any ptr. The expression is needed to tell
    // that literal apart from any other integer — and from `false`, whose value
    // is 0 too.
    static bool ptrToAssignable(Ty to,Ty from,const Expr& e){
        if(from!=Ty::Ptr)return isNullConstant(e);
        // v0.23.34-dev: a strided pointer must not land in a slot that cannot
        // carry its stride. The mis-scaling the 4-byte gate used to refuse at
        // the `&` itself is now refused where it would happen: at the store.
        // A ptr<S> slot strides at sizeof(S), so a pointer to S elements lands
        // in one unchanged whatever S's size; an untyped ptr strides at four
        // bytes, so only a four-byte element survives it. A strided slot has
        // to name the same element, or `p[i]` would disagree with the array
        // the pointer came from.
        if(tyIsPtrToElem(from)){
            if(tyIsPtrToElem(to))
                return ptrElemType(to).k==ptrElemType(from).k&&ptrElemType(to).sid==ptrElemType(from).sid;
            if(tyIsPtrToStruct(to))return ptrElemWidth(from)==tySize(Ty::ofStruct(to.sid));
            return ptrElemWidth(from)==4u;
        }
        if(!tyIsPtrToStruct(to)||!tyIsPtrToStruct(from))return true;
        return to.sid==from.sid;
    }
    // S { v1, v2 } : one value per field, in declaration order, each checked
    // against that field's declared type.
    Ty checkStructLit(const Expr& e){
        auto it=g_structIndex.find(e.name);
        if(it==g_structIndex.end())throw Error(loc(e.line,e.col,"unknown struct: "+e.name));
        const StructDef& sd=structOf(it->second);
        if(e.args.size()!=sd.fields.size())
            throw Error(loc(e.line,e.col,"struct literal for '"+sd.name+"' has "+std::to_string(e.args.size())+" values but the struct has "+std::to_string(sd.fields.size())+" fields"));
        for(size_t i=0;i<sd.fields.size();++i){
            const StructField& f=sd.fields[i];
            const Ty actual=typeOf(*e.args[i]);
            const std::string what="type mismatch in struct literal for '"+sd.name+"' field '"+f.name+"': expected ";
            if(tyIsStruct(f.ty)){
                if(!tyIsStruct(actual)||actual.sid!=f.ty.sid)
                    throw Error(loc(e.args[i]->line,e.args[i]->col,what+tyNameFull(f.ty)+", got "+tyNameFull(actual)));
            } else if(f.ty==Ty::Bool){
                if(actual!=Ty::Bool&&!isBoolConstant(*e.args[i]))
                    throw Error(loc(e.args[i]->line,e.args[i]->col,what+"bool, got "+tyNameFull(actual)));
            } else if(f.ty==Ty::Ptr){
                if(!ptrToAssignable(f.ty,actual,*e.args[i]))throw Error(loc(e.args[i]->line,e.args[i]->col,what+tyNameFull(f.ty)+", got "+tyNameFull(actual)));
                // v0.23.38-dev: a fn-pointer field is checked by signature,
                // not merely by "both sides are eight bytes of address" —
                // `Handlers { double_fn, 0 }` where the field wants
                // `fn(i32) -> i32` is the mistake the field's type exists to
                // catch, and it is caught where the literal is written.
                if(f.isFunc)checkPtrSig(&f.funcSig,*e.args[i],
                    "type mismatch in struct literal for '"+sd.name+"' field '"+f.name+"'");
            } else {
                if(tyIsStruct(actual)||actual==Ty::Bool||!tyAssignable(f.ty,actual,*e.args[i]))
                    throw Error(loc(e.args[i]->line,e.args[i]->col,what+tyNameFull(f.ty)+", got "+tyNameFull(actual)));
            }
        }
        return Ty::ofStruct(it->second);
    }
    // One argument against one declared parameter type. `wantSig` (v0.23.38-dev)
    // is the parameter's function type, when it declares one.
    void checkArgument(const std::string& callee,size_t pos,Ty want,const Expr& e,Ty actual,const FuncSig* wantSig=nullptr){
        const std::string at="argument type mismatch calling "+callee+" at argument "+std::to_string(pos)+": expected ";
        // v0.23.38-dev: an argument handed to a fn-pointer parameter is
        // checked by signature, so `apply(double_fn)` — where apply asked for
        // `fn(i32) -> i32` — is refused at the call and not at the later
        // indirect call through the wrong pointer. `ap` is `at` without its
        // trailing "expected", because checkPtrSig supplies its own.
        const std::string ap="argument type mismatch calling "+callee+" at argument "+std::to_string(pos);
        if(want==Ty::Bool){
            if(actual!=Ty::Bool&&!isBoolConstant(e))throw Error(loc(e.line,e.col,at+"bool"));
            return;
        }
        if(want==Ty::Ptr){
            if(!ptrToAssignable(want,actual,e))throw Error(loc(e.line,e.col,at+tyNameFull(want)));
            checkPtrSig(wantSig,e,ap);
            return;
        }
        if(tyIsStruct(want)||tyIsStruct(actual)){
                if(!tyIsStruct(want)||!tyIsStruct(actual)||actual.sid!=want.sid)
                    throw Error(loc(e.line,e.col,at+tyNameFull(want)+", got "+tyNameFull(actual)));
            return;
        }
        if(actual==Ty::Ptr||actual==Ty::Bool)throw Error(loc(e.line,e.col,at+"i32"));
    }
    // May a value of type `actual` (the expression `e`) be stored in a slot of
    // type `want`? Structs match by identity; everything else keeps the rules
    // the scalar lattice already had.
    void checkValue(Ty want,const Expr& e,Ty actual,const std::string& what){
        if(tyIsStruct(want)||tyIsStruct(actual)){
            if(!tyIsStruct(want)||!tyIsStruct(actual)||actual.sid!=want.sid)
                throw Error(loc(e.line,e.col,what+": expected "+tyNameFull(want)+", got "+tyNameFull(actual)));
            return;
        }
        if(want==Ty::Bool){
            if(actual!=Ty::Bool&&!isBoolConstant(e))throw Error(loc(e.line,e.col,what+" (expected bool)"));
            return;
        }
        if(want==Ty::Ptr){
            if(!ptrToAssignable(want,actual,e))throw Error(loc(e.line,e.col,what+": expected "+tyNameFull(want)+", got "+tyNameFull(actual)));
            return;
        }
        if(actual==Ty::Ptr||actual==Ty::Bool)throw Error(loc(e.line,e.col,what+": expected "+tyNameFull(want)+", got "+tyNameFull(actual)));
    }
    // The element type of an indexable name: a local T[N], or a fixed-size
    // global whose declared type is the element type. v0.23.28-dev: this is
    // what `a[i]` types as. A ptr local without a length indexes as one i32
    // stride, which is the behaviour that predates arrays of a declared type.
    Ty arrayElemTypeOf(const std::string& n) const {
        if(const Binding* b=find(n))return b->elem;
        auto it=globalTypes.find(n);
        return it==globalTypes.end()?Ty::I32:it->second;
    }
    uint32_t arrayLengthOf(const std::string& n) const {
        if(const Binding* b=find(n))return b->len;
        auto it=arrayLengths.find(n);
        return it==arrayLengths.end()?0:it->second;
    }
    // v0.23.30-dev: is `e` the name of a fixed-length array — a local `T[N]`, a
    // global `T[N]`, or a struct's array field? If it is, hand back the element
    // type and the length. A bare `typeOf` cannot answer the question: a local
    // array's `Binding.ty` is already the decayed address (`Ty::Ptr`) and so is
    // a global array's, which is what makes `a` usable as a pointer value — so
    // "is this an array?" is a question about the *length*, not the type.
    bool arrayOperandOf(const Expr& e,Ty& elem,uint32_t& len){
        if(e.k==Expr::Var){
            if(const Binding* b=find(e.name)){
                if(!b->len)return false;                    // a scalar local, or a ptr
                elem=b->elem; len=b->len; return true;
            }
            if(arrayGlobals.count(e.name)){                 // a file-scope T[N]
                elem=arrayElemTypeOf(e.name); len=arrayLengthOf(e.name); return true;
            }
            return false;
        }
        if(e.k==Expr::Field){                               // a struct's array field
            const StructField* f=arrayFieldOf(typeOf(*e.a),e);
            if(!f||!f->len)return false;
            elem=f->ty; len=f->len; return true;
        }
        return false;
    }
    // v0.23.35-dev: the total element count of an array *expression* operand of
    // sizeof / len, plus its element type. Unlike arrayOperandOf (which reports
    // only the outermost dimension's length for bounds-checking), this returns
    // the product of every dimension, because `len(a)` of a 2-D parameter is
    // the grand total, not the row count.
    bool arrayElemCountOf(const Expr& operand,Ty& elem,uint64_t& count) {
        if(operand.k==Expr::Var){
            if(const Binding* b=find(operand.name)){
                if(b->dims.empty())return false;             // a scalar local, or a ptr
                elem=b->elem; count=dimsProduct(b->dims); return true;
            }
            if(arrayGlobals.count(operand.name)){            // a file-scope T[N]
                elem=arrayElemTypeOf(operand.name);
                auto it=arrayDims.find(operand.name);
                if(it!=arrayDims.end()&&!it->second.empty())count=dimsProduct(it->second);
                else count=arrayLengthOf(operand.name);
                return true;
            }
            return false;
        }
        if(operand.k==Expr::Field){                          // a struct's array field
            const StructField* f=arrayFieldOf(typeOf(*operand.a),operand);
            if(!f||!f->len)return false;
            elem=f->ty; count=f->len; return true;           // f->len is already the grand total
        }
        return false;
    }
    // v0.23.35-dev: compute the i32 constant for an *expression-form* sizeof /
    // len. The type-form was folded at parse time; this is only reached for the
    // expression-form, which needs the binding's dimensions. `e.n` is set by the
    // caller (Sema::typeOf) once this returns.
    uint64_t foldSizeOfExpr(const Expr& e) {
        const bool isLen=(e.k==Expr::Len);
        Ty elem=Ty::I32; uint64_t count=0;
        if(arrayElemCountOf(*e.a,elem,count))
            return isLen?count:(uint64_t)tySize(elem)*count;  // array: bytes or element count
        // Not an array: a scalar, a struct, or a pointer. len() refuses these
        // honestly (you cannot count the elements of something with none);
        // sizeof() reports the storage size — 8 for any pointer, as in C.
        if(isLen)throw Error(loc(e.line,e.col,"len() requires an array, not a scalar or pointer"));
        return (uint64_t)tySize(typeOf(*e.a));
    }
    void checkArrayBounds(uint32_t length,const Expr& index){
        if(!length)return;
        int64_t value=0;if(!constantInteger(index,value))return;
        if(value<0||static_cast<uint64_t>(value)>=length)
            throw Error(loc(index.line,index.col,"array index out of bounds: index "+std::to_string(value)+", length "+std::to_string(length)));
    }
    // v0.23.31-dev: what a subscript chain says about the array it starts
    // from. `a[i][j]` parses as an Index whose left side is itself an Index
    // (the array's name rides on the innermost node), so "which dimension
    // does this subscript address?" is a question about how many subscripts
    // sit *below* the node being typed: the base's own subscript is level 0,
    // and `dims[level]` is the length it is checked against. `what` is the
    // name the diagnostics spell — `'a'` or `field 'xs'`.
    struct IndexChain {
        const std::vector<uint32_t>* dims=nullptr;
        Ty elem=Ty::I32;
        uint32_t level=0;
        std::string what;
    };
    // Resolve a subscript chain, or answer false when it does not start at a
    // fixed-length array — a ptr local, a scalar, an unknown name — which is
    // every shape the callers already refuse with their own message.
    bool indexChainOf(const Expr& e,IndexChain& out){
        const Expr* n=&e;
        uint32_t level=0;
        while(n->k==Expr::Index&&n->name.empty()&&n->a->k==Expr::Index){n=n->a.get();++level;}
        if(n->k!=Expr::Index)return false;
        if(!n->name.empty()){                              // a[i][j]: the name is on the base node
            if(const Binding* b=find(n->name)){
                if(!b->len||b->dims.empty())return false;  // a scalar local or a ptr
                out.dims=&b->dims;out.elem=b->elem;out.level=level;out.what="'"+n->name+"'";return true;
            }
            if(!arrayGlobals.count(n->name))return false;
            auto it=arrayDims.find(n->name);
            if(it==arrayDims.end())return false;
            out.dims=&it->second;out.elem=arrayElemTypeOf(n->name);out.level=level;out.what="'"+n->name+"'";return true;
        }
        if(n->a->k!=Expr::Field)return false;              // s.xs[i][j]: the base's left side is a field
        const StructField* f=arrayFieldOf(typeOf(*n->a->a),*n->a);
        if(!f||f->dims.empty())return false;
        out.dims=&f->dims;out.elem=f->ty;out.level=level;out.what="field '"+n->a->name+"'";return true;
    }
    // True when a subscript chain stops short of the elements — `a[i]` on a
    // two-dimensional array, which addresses a whole row. Such an expression
    // is a ptr, and a store to it is as meaningless as a store to the array
    // itself, so the two assignment forms ask before they check the value.
    // `what` (when given) comes back as the chain's own name — `'a'` or
    // `field 'xs'` — for the diagnostic.
    bool indexChainIsRow(const Expr& e,std::string* what=nullptr){
        IndexChain ch;
        if(!indexChainOf(e,ch)||ch.level+1>=ch.dims->size())return false;
        if(what)*what=ch.what;
        return true;
    }
    // v0.23.31-dev: the dimensions of a named array, or nullptr when the name
    // is not one — a scalar, a ptr, an unknown. A single subscript arrives from
    // the parser as itself rather than as a chain node, so the row question for
    // `a[i] = v` on a two-dimensional `a` is asked of the dimensions directly:
    // one subscript on two or more dimensions names a row, not an element.
    const std::vector<uint32_t>* arrayDimsOfName(const std::string& name){
        if(const Binding* b=find(name)){
            if(b->dims.empty())return nullptr;
            return &b->dims;
        }
        auto it=arrayDims.find(name);
        if(it==arrayDims.end())return nullptr;
        return &it->second;
    }
    void checkArrayBounds(const std::string& name,const Expr& index){
        const uint32_t length=arrayLengthOf(name);
        if(!length)return;
        int64_t value=0;if(!constantInteger(index,value))return;
        if(value<0||static_cast<uint64_t>(value)>=length)
            throw Error(loc(index.line,index.col,"array index out of bounds for '"+name+"': index "+std::to_string(value)+", length "+std::to_string(length)));
    }
    Ty typeOf(const Expr& e){
        switch(e.k){
            case Expr::Num: return e.boolLit?Ty::Bool:Ty::I32;   // v0.23.25-dev: true/false type as bool; every other literal takes on the type its context asks for
            case Expr::String: return Ty::Ptr;   // a string literal is its rodata address
            case Expr::Embed: return Ty::Ptr;    // @embed: the address of the embedded bytes
            case Expr::SizeOf: case Expr::Len:
                // v0.23.35-dev: the type-form folded at parse time; the
                // expression-form folds now (sema has the binding's dims).
                if(e.a) const_cast<Expr&>(e).n = foldSizeOfExpr(e);
                return Ty::I32;
            case Expr::Var: {
                if(const Binding* b=find(e.name))return b->ty;
                if(arrayGlobals.count(e.name))return Ty::Ptr;      // array name decays to its address
                auto gt=globalTypes.find(e.name);                  // declared type: bool, struct, any width
                if(gt!=globalTypes.end())return gt->second;
                if(globalNames.count(e.name))return Ty::I32;
                // A non-extern function name in a value position is its address.
                if(arities.count(e.name)&&!externFunctions.count(e.name))return Ty::Ptr;
                // An extern function has no address Aster can hand out: its
                // location is another object's business (a C object the static
                // linker has not seen, or a PLT slot a shared object resolves
                // at load time). A pointer *to* one arrives as a value — a
                // parameter, a load_ptr out of memory — never as a name.
                if(arities.count(e.name))
                    throw Error(loc(e.line,e.col,"cannot take the address of extern function '"+e.name+"': its location is another object's business"));
                throw Error(loc(e.line,e.col,"unknown variable: "+e.name));
            }
            case Expr::Call: return checkCall(e);
            // v0.23.38-dev: `h.onClick(x)` — the call through a fn-pointer
            // field. A separate case rather than a flag on Call, precisely so
            // a field named like a function cannot be rerouted to it.
            case Expr::FieldCall: return checkFieldCall(e);
            case Expr::Field: {
                const Ty base=typeOf(*e.a);
                const int sid=structBaseId(base,e.name);
                const StructField* f=structOf(sid).find(e.name);
                if(!f)throw Error(loc(e.line,e.col,"struct '"+structOf(sid).name+"' has no field named '"+e.name+"'"));
                return f->ty;
            }
            case Expr::AddrOf: {
                if(!isLValue(*e.a))
                    throw Error(loc(e.line,e.col,"'&' requires a variable, a field, or a dereferenced ptr<S>"));
                // v0.23.34-dev: an array has an address too — the address of its
                // first element, typed to stride at the element's real width.
                // The pointer now carries the element type, so `&arr` works for
                // any element width (i64/u8/u16/ptr/S) and `p[i]` on the result
                // scales correctly instead of silently mis-striding.
                Ty aelem; uint32_t alen=0;
                if(arrayOperandOf(*e.a,aelem,alen)){
                    return tyPtrToElem(aelem);
                }
                const Ty inner=typeOf(*e.a);
                if(!tyIsStruct(inner))
                    throw Error(loc(e.line,e.col,"'&' is only defined for a struct lvalue, not "+tyNameFull(inner)));
                return Ty::ptrTo(inner.sid);
            }
            case Expr::StructLit: return checkStructLit(e);
            case Expr::Index: {
                // v0.23.31-dev: `a[i][j]` is `a[i]` subscripted again, and
                // `a[i]` is a row address — not an element. Every subscript
                // in a chain therefore answers the same question one
                // dimension in: walk to the array the chain starts from,
                // find which dimension this subscript addresses, and answer
                // a row address (a ptr) unless this is the innermost
                // subscript. A one-dimensional array has only an innermost
                // subscript, so it keeps answering its element type exactly
                // as it did before, byte for byte.
                IndexChain ch;
                if(indexChainOf(e,ch)){
                    if(ch.level>=ch.dims->size())
                        throw Error(loc(e.line,e.col,"too many subscripts for "+ch.what+": it has "
                                        +std::to_string(ch.dims->size())+" dimension"+(ch.dims->size()==1?"":"s")));
                    // Every subscript in the chain answers for its own
                    // dimension — this node's here, the inner ones by walking
                    // down to them. The named base node carries its subscript
                    // in `a` (its `b` is empty); every node above it carries it
                    // in `b`. Checking only the outermost node would leave
                    // `a[true][0]`'s inner `true` unexamined, and a bool
                    // literal is not an element number.
                    const Expr* n=&e;
                    for(uint32_t l=ch.level+1;l-->0;){
                        const Expr& index=(l==0&&!n->name.empty())?*n->a:*n->b;
                        const Ty idxTy=typeOf(index);
                        if(idxTy==Ty::Ptr)throw Error(loc(e.line,e.col,"pointer indexing is not supported yet"));
                        // v0.23.25-dev: an index is an integer. A bool literal
                        // would otherwise compile as the element number 0 or 1.
                        rejectBool(idxTy,"an array index");
                        // A one-dimensional array answers exactly as it always
                        // has: the named overload reads the length back from the
                        // name and names the array in the diagnostic, which is
                        // the message the one-dimensional suites pin. An inner
                        // level has no name to read — its length is a dimension
                        // of the same array — and neither has a field chain, so
                        // both answer with the length alone.
                        if(l==0&&!n->name.empty())checkArrayBounds(n->name,index);
                        else checkArrayBounds((*ch.dims)[l],index);
                        if(l>0)n=n->a.get();
                    }
                    return ch.level+1<ch.dims->size()?Ty::Ptr:ch.elem;
                }
                // v0.23.29-dev: a struct array field element (`s.xs[i]`) types as
                // the field's element type, and its index is the expression in
                // `b`. A `[` after a non-array field is rejected here.
                if(e.a->k==Expr::Field){
                    const StructField* af=arrayFieldOf(typeOf(*e.a->a),*e.a);
                    if(!af)throw Error(loc(e.line,e.col,"cannot index non-array field: "+e.a->name));
                    checkArrayBounds(af->len,*e.b);
                    rejectBool(typeOf(*e.b),"an array index");
                    return af->ty;
                }
                // v0.23.34-dev: an index through a pointer expression —
                // `(&arr)[i]` — whose base rides in `a` and whose subscript in
                // `b`. (A named base keeps `name` and puts the subscript in
                // `a`; that shape is answered by the array rules below.)
                //
                // Reached only for an `&` base: postfix() lets `[` follow a
                // Field, an Index or an AddrOf and nothing else, and a Field
                // base is answered above. The guard is here because the two
                // shapes are easy to confuse, and it costs one comparison to
                // say which this is rather than to let a future shape fall
                // through into the named-array rules by accident.
                if(e.name.empty()){
                    const Ty baseType=typeOf(*e.a);
                    if(tyIsPtrToElem(baseType)){
                        const Ty elem=ptrElemType(baseType);
                        rejectBool(typeOf(*e.b),"an array index");
                        return elem;
                    }
                }
                const Ty idxTy=typeOf(*e.a);
                if(idxTy==Ty::Ptr)throw Error(loc(e.line,e.col,"pointer indexing is not supported yet"));
                // v0.23.25-dev: an index is an integer. A bool literal would
                // otherwise compile as the element number 0 or 1.
                rejectBool(idxTy,"an array index");
                // v0.23.31-dev: an empty name here is a chain whose base was a
                // ptr — the only base whose single subscript types as a value
                // instead of an error (a scalar or an unknown name has already
                // been refused inside `typeOf(*e.a)` above). `p[0]` is
                // `*(p+0)`, a loaded value; subscripting that value a second
                // time has no stride Aster could apply, so the second level is
                // refused by name rather than reported as an unknown array
                // under the chain's empty base name.
                if(e.name.empty())
                    throw Error(loc(e.line,e.col,"pointer indexing is not supported yet"));
                const Binding* b=find(e.name);
                if(b){
                    if(b->len)checkArrayBounds(e.name,*e.a);            // local T[N]
                    else if(b->ty!=Ty::Ptr)throw Error(loc(e.line,e.col,"cannot index non-array variable: "+e.name));
                    // v0.23.34-dev: a pointer variable indexes at the width its
                    // own type names — a ptr<S> at sizeof(S), a strided
                    // pointer at the element it carries — which is the stride
                    // emitElemAddr applies. Answering i32 here would let the
                    // two passes disagree: sema would type-check `a[i]` on an
                    // i64 array parameter as an i32 while codegen loaded
                    // eight bytes at the same spot.
                    else if(tyIsPtrToStruct(b->ty))return Ty::ofStruct(b->ty.sid);
                    else if(tyIsPtrToElem(b->ty))return ptrElemType(b->ty);
                } else {
                    if(!globalNames.count(e.name))throw Error(loc(e.line,e.col,"unknown array: "+e.name));
                    if(!arrayGlobals.count(e.name))throw Error(loc(e.line,e.col,"cannot index non-array global: "+e.name));
                    checkArrayBounds(e.name,*e.a);
                }
                // v0.23.28-dev: the element type the declaration wrote, not a
                // hard-coded i32. Codegen has always loaded at the element's
                // width; this pass is what disagreed with it.
                return arrayElemTypeOf(e.name);
            }
            case Expr::Deref: {
                const Ty inner=typeOf(*e.a);
                if(inner!=Ty::Ptr)throw Error(loc(e.line,e.col,"dereference requires a ptr expression"));
                // *p on a ptr<S> is the struct itself, as in C — which is what
                // makes `(*p).f` and `p.f` the same read.
                return tyIsPtrToStruct(inner)?Ty::ofStruct(inner.sid):Ty::I32;
            }
            case Expr::Neg:
                if(typeOf(*e.a)==Ty::Ptr)throw Error(loc(e.line,e.col,"pointer arithmetic is not supported yet"));
                rejectStruct(typeOf(*e.a),"-");
                rejectBool(typeOf(*e.a),"-");
                return Ty::I32;
            case Expr::Add: {
                const Ty a=typeOf(*e.a),b=typeOf(*e.b);
                if(a==Ty::Ptr&&b==Ty::Ptr)throw Error(loc(e.line,e.col,"invalid pointer arithmetic: ptr + ptr is not supported"));
                if(a==Ty::Ptr||b==Ty::Ptr)return Ty::Ptr;                // ptr +/- i32 stays ptr
                rejectStruct(a,"+");rejectStruct(b,"+");
                rejectBool(a,"+");rejectBool(b,"+");
                return Ty::I32;
            }
            case Expr::Sub: {
                const Ty a=typeOf(*e.a),b=typeOf(*e.b);
                if(a==Ty::Ptr&&b!=Ty::Ptr)return Ty::Ptr;
                if(a==Ty::Ptr||b==Ty::Ptr)throw Error(loc(e.line,e.col,"invalid pointer arithmetic: expected ptr - i32"));
                rejectStruct(a,"-");rejectStruct(b,"-");
                rejectBool(a,"-");rejectBool(b,"-");
                return Ty::I32;
            }
            case Expr::Mul: case Expr::Div: {
                const char* op=e.k==Expr::Mul?"*":"/";
                rejectBool(typeOf(*e.a),op);rejectBool(typeOf(*e.b),op);
                return Ty::I32;
            }
            // v0.23.17-dev (round 1): `%`, the shifts, the bitwise operators
            // and `?:`. None of them is defined on a pointer or a struct —
            // `p & 0xff` is not a way to inspect an address in a language that
            // will not let you print one. A shift's result takes the left
            // operand's type (as in C, the right operand is just a count), and
            // a conditional takes the type its two arms agree on.
            case Expr::Mod: {
                const Ty a=typeOf(*e.a),b=typeOf(*e.b);
                rejectPtr(a,"%");rejectPtr(b,"%");rejectStruct(a,"%");rejectStruct(b,"%");
                rejectBool(a,"%");rejectBool(b,"%");
                return Ty::I32;
            }
            case Expr::Shl: case Expr::Shr: {
                const char* op=e.k==Expr::Shl?"<<":">>";
                const Ty a=typeOf(*e.a),b=typeOf(*e.b);
                rejectPtr(a,op);rejectStruct(a,op);
                rejectBool(a,op);rejectBool(b,op);
                return a;
            }
            case Expr::BitAnd: case Expr::BitOr: case Expr::BitXor: {
                const char* op=e.k==Expr::BitAnd?"&":e.k==Expr::BitOr?"|":"^";
                const Ty a=typeOf(*e.a),b=typeOf(*e.b);
                rejectPtr(a,op);rejectPtr(b,op);rejectStruct(a,op);rejectStruct(b,op);
                rejectBool(a,op);rejectBool(b,op);
                return Ty::I32;
            }
            case Expr::BitNot: {
                const Ty a=typeOf(*e.a);
                rejectPtr(a,"~");rejectStruct(a,"~");
                rejectBool(a,"~");
                return a;
            }
            case Expr::Cond: {
                const Ty c=typeOf(*e.a);
                if(c!=Ty::Bool)throw Error(loc(e.line,e.col,"the condition of '?:' must be a bool expression"));
                const Ty x=typeOf(*e.b),y=typeOf(*e.args[0]);
                if(x!=y)throw Error(loc(e.line,e.col,"both arms of '?:' must have the same type (got "+tyNameFull(x)+" and "+tyNameFull(y)+")"));
                rejectPtr(x,"?:");rejectStruct(x,"?:");
                return x;
            }
            case Expr::Eq: case Expr::Ne: case Expr::Lt: case Expr::Le: case Expr::Gt: case Expr::Ge: {
                const Ty a=typeOf(*e.a),b=typeOf(*e.b);
                // v0.23.26-dev: a ptr answers == and != — against another ptr,
                // or against the null constant. Ordering two addresses answers
                // a question Aster has no business answering here (which of two
                // unrelated objects came first), so it stays rejected.
                if(a==Ty::Ptr||b==Ty::Ptr){
                    if(e.k!=Expr::Eq&&e.k!=Expr::Ne)
                        throw Error(loc(e.line,e.col,"only == and != are defined for a ptr"));
                    if(a==Ty::Ptr&&b==Ty::Ptr){
                        // ok: two addresses compared for identity
                    } else if(a==Ty::Ptr){
                        if(!isNullConstant(*e.b))
                            throw Error(loc(e.line,e.col,"a ptr may only be compared with another ptr, or with the literal 0"));
                    } else if(!isNullConstant(*e.a)){
                        throw Error(loc(e.line,e.col,"a ptr may only be compared with another ptr, or with the literal 0"));
                    }
                }
                rejectStruct(a,"a comparison");rejectStruct(b,"a comparison");
                return Ty::Bool;
            }
            case Expr::And: case Expr::Or: {
                const Ty a=typeOf(*e.a),b=typeOf(*e.b);
                if(a!=Ty::Bool||b!=Ty::Bool)
                    throw Error(loc(e.line,e.col,std::string("&& and || require bool operands (")+(e.k==Expr::And?"&&":"||")+")"));
                return Ty::Bool;
            }
            case Expr::Not:
                if(typeOf(*e.a)!=Ty::Bool)throw Error(loc(e.line,e.col,"'!' requires a bool operand"));
                return Ty::Bool;
        }
        throw Error(loc(e.line,e.col,"unsupported expression"));
    }
    Ty checkCall(const Expr& e){
        // User-defined functions shadow the intrinsics (v0.23.21-dev: the
        // `write` intrinsic collided with a helper of that name in
        // tests/runtime-bounds-checks.sh). A definition wins; the intrinsic
        // answers only for names the program has not taken.
        if(e.name=="load_ptr"&&!arities.count(e.name)){
            if(e.args.size()!=1)throw Error(loc(e.line,e.col,"load_ptr expects exactly one ptr argument"));;
            if(typeOf(*e.args[0])!=Ty::Ptr)throw Error(loc(e.line,e.col,"load_ptr expects a ptr argument"));
            return Ty::Ptr;
        }
        if(e.name=="load_u8"&&!arities.count(e.name)){
            if(e.args.size()!=1)throw Error(loc(e.line,e.col,"load_u8 expects exactly one ptr argument"));
            if(typeOf(*e.args[0])!=Ty::Ptr)throw Error(loc(e.line,e.col,"load_u8 expects a ptr argument"));
            return Ty::I32;
        }
        if(e.name=="store_u8"&&!arities.count(e.name)){
            if(e.args.size()!=2)throw Error(loc(e.line,e.col,"store_u8 expects (ptr, i32)"));
            if(typeOf(*e.args[0])!=Ty::Ptr)throw Error(loc(e.line,e.col,"store_u8 first argument must be ptr"));
            if(typeOf(*e.args[1])==Ty::Ptr)throw Error(loc(e.line,e.col,"store_u8 second argument must be i32"));
            return Ty::I32;
        }
        // v0.23.23-dev: the halfword and quadword pairs. load_u16 answers i32
        // (zero-extended, like load_u8); load_i64 answers i64; store_u16 takes
        // the byte store's i32 contract; store_i64 takes i32 or i64 — an i32
        // widens by sign-extension, exactly as storing it into an i64 local
        // does — and rejects bool, which no i64 slot accepts either.
        if(e.name=="load_u16"&&!arities.count(e.name)){
            if(e.args.size()!=1)throw Error(loc(e.line,e.col,"load_u16 expects exactly one ptr argument"));
            if(typeOf(*e.args[0])!=Ty::Ptr)throw Error(loc(e.line,e.col,"load_u16 expects a ptr argument"));
            return Ty::I32;
        }
        if(e.name=="load_i64"&&!arities.count(e.name)){
            if(e.args.size()!=1)throw Error(loc(e.line,e.col,"load_i64 expects exactly one ptr argument"));
            if(typeOf(*e.args[0])!=Ty::Ptr)throw Error(loc(e.line,e.col,"load_i64 expects a ptr argument"));
            return Ty::I64;
        }
        if(e.name=="store_u16"&&!arities.count(e.name)){
            if(e.args.size()!=2)throw Error(loc(e.line,e.col,"store_u16 expects (ptr, i32)"));
            if(typeOf(*e.args[0])!=Ty::Ptr)throw Error(loc(e.line,e.col,"store_u16 first argument must be ptr"));
            if(typeOf(*e.args[1])==Ty::Ptr)throw Error(loc(e.line,e.col,"store_u16 second argument must be i32"));
            return Ty::I32;
        }
        if(e.name=="store_i64"&&!arities.count(e.name)){
            if(e.args.size()!=2)throw Error(loc(e.line,e.col,"store_i64 expects (ptr, i64)"));
            if(typeOf(*e.args[0])!=Ty::Ptr)throw Error(loc(e.line,e.col,"store_i64 first argument must be ptr"));
            if(typeOf(*e.args[1])==Ty::Ptr)throw Error(loc(e.line,e.col,"store_i64 second argument must be i64"));
            if(typeOf(*e.args[1])==Ty::Bool)throw Error(loc(e.line,e.col,"store_i64 second argument must be i64"));
            return Ty::I64;
        }
        if(e.name=="write"&&!arities.count(e.name)){
            if(e.args.size()!=3)throw Error(loc(e.line,e.col,"write expects (fd: i32, buf: ptr, len: i32)"));
            if(typeOf(*e.args[0])==Ty::Ptr)throw Error(loc(e.line,e.col,"write first argument must be i32"));
            if(typeOf(*e.args[1])!=Ty::Ptr)throw Error(loc(e.line,e.col,"write second argument must be ptr"));
            if(typeOf(*e.args[2])==Ty::Ptr)throw Error(loc(e.line,e.col,"write third argument must be i32"));
            return Ty::I32;
        }
        // v0.23.40-dev: raw system-call intrinsics, the argument/result typing the
        // codegen side at syscallInsn must agree with. AArch64 numbering: 56 is
        // openat (there is no plain open), fstat is 80. Read the layout note there.
        if(e.name=="read"&&!arities.count(e.name)){
            if(e.args.size()!=3)throw Error(loc(e.line,e.col,"read expects (fd: i32, buf: ptr, len: i32)"));
            if(typeOf(*e.args[0])==Ty::Ptr)throw Error(loc(e.line,e.col,"read first argument must be i32"));
            if(typeOf(*e.args[1])!=Ty::Ptr)throw Error(loc(e.line,e.col,"read second argument must be ptr"));
            if(typeOf(*e.args[2])==Ty::Ptr)throw Error(loc(e.line,e.col,"read third argument must be i32"));
            return Ty::I32;
        }
        if(e.name=="openat"&&!arities.count(e.name)){
            if(e.args.size()!=4)throw Error(loc(e.line,e.col,"openat expects (fd: i32, path: ptr, flags: i32, mode: i32)"));
            if(typeOf(*e.args[0])==Ty::Ptr)throw Error(loc(e.line,e.col,"openat first argument must be i32"));
            if(typeOf(*e.args[1])!=Ty::Ptr)throw Error(loc(e.line,e.col,"openat second argument must be ptr"));
            if(typeOf(*e.args[2])==Ty::Ptr)throw Error(loc(e.line,e.col,"openat third argument must be i32"));
            if(typeOf(*e.args[3])==Ty::Ptr)throw Error(loc(e.line,e.col,"openat fourth argument must be i32"));
            return Ty::I32;
        }
        if(e.name=="close"&&!arities.count(e.name)){
            if(e.args.size()!=1)throw Error(loc(e.line,e.col,"close expects (fd: i32)"));
            if(typeOf(*e.args[0])==Ty::Ptr)throw Error(loc(e.line,e.col,"close argument must be i32"));
            return Ty::I32;
        }
        if(e.name=="fstat"&&!arities.count(e.name)){
            if(e.args.size()!=2)throw Error(loc(e.line,e.col,"fstat expects (fd: i32, buf: ptr)"));
            if(typeOf(*e.args[0])==Ty::Ptr)throw Error(loc(e.line,e.col,"fstat first argument must be i32"));
            if(typeOf(*e.args[1])!=Ty::Ptr)throw Error(loc(e.line,e.col,"fstat second argument must be ptr"));
            return Ty::I32;
        }
        // v0.23.41-dev: the heap, typed the way the codegen side at syscallInsn
        // must agree with. Both answer a ptr — the only intrinsics that do —
        // and mmap's second and sixth arguments are i64 at full width. A
        // literal length like 1048576 is an i32 that widens, exactly as
        // store_i64's value argument does; a ptr or a bool in either i64
        // position is refused.
        if(e.name=="mmap"&&!arities.count(e.name)){
            if(e.args.size()!=6)throw Error(loc(e.line,e.col,"mmap expects (addr: ptr, length: i64, prot: i32, flags: i32, fd: i32, offset: i64)"));
            if(typeOf(*e.args[0])!=Ty::Ptr)throw Error(loc(e.line,e.col,"mmap first argument must be ptr"));
            if(typeOf(*e.args[1])==Ty::Ptr||typeOf(*e.args[1])==Ty::Bool)throw Error(loc(e.line,e.col,"mmap second argument must be i64"));
            if(typeOf(*e.args[2])==Ty::Ptr)throw Error(loc(e.line,e.col,"mmap third argument must be i32"));
            if(typeOf(*e.args[3])==Ty::Ptr)throw Error(loc(e.line,e.col,"mmap fourth argument must be i32"));
            if(typeOf(*e.args[4])==Ty::Ptr)throw Error(loc(e.line,e.col,"mmap fifth argument must be i32"));
            if(typeOf(*e.args[5])==Ty::Ptr||typeOf(*e.args[5])==Ty::Bool)throw Error(loc(e.line,e.col,"mmap sixth argument must be i64"));
            return Ty::Ptr;
        }
        if(e.name=="brk"&&!arities.count(e.name)){
            if(e.args.size()!=1)throw Error(loc(e.line,e.col,"brk expects (addr: ptr)"));
            if(typeOf(*e.args[0])!=Ty::Ptr)throw Error(loc(e.line,e.col,"brk argument must be ptr"));
            return Ty::Ptr;
        }
        auto sig=arities.find(e.name);
        if(sig==arities.end()){
            // v0.23.24-dev: an indirect call. The callee is a ptr variable —
            // taking a function's address has produced a ptr since the
            // callback-table work, and this is the call through one. There is
            // no signature to check against (the variable's type is ptr, not
            // a function type), so each argument is checked only for being a
            // value the ABI can carry, and the call answers i32.
            if(const Binding* b=find(e.name)){
                if(b->len)
                    throw Error(loc(e.line,e.col,"cannot call through '"+e.name+"': it is an array"));
                if(b->ty!=Ty::Ptr)
                    throw Error(loc(e.line,e.col,"cannot call through '"+e.name+"': expected a function pointer (ptr), got "+tyNameFull(b->ty)));
            } else if(globalNames.count(e.name)){
                if(arrayGlobals.count(e.name))
                    throw Error(loc(e.line,e.col,"cannot call through '"+e.name+"': it is an array"));
                const Ty gt=globalTypes.count(e.name)?globalTypes.at(e.name):Ty::I32;
                if(gt!=Ty::Ptr)
                    throw Error(loc(e.line,e.col,"cannot call through '"+e.name+"': expected a function pointer (ptr), got "+tyNameFull(gt)));
            } else {
                throw Error(loc(e.line,e.col,"call to undeclared function: "+e.name));
            }
            // v0.23.37-dev: when the callee carries a function type, check the
            // call against that signature — argument count and each argument's
            // type, reusing the same check a direct call uses — and answer the
            // signature's return type. A struct-by-value argument is legal here:
            // the signature names the struct, so codegen's layout pipeline can
            // marshal it. A bare ptr keeps the legacy behaviour below.
            if(const FuncSig* fs=funcSigOf(e.name)){
                if(e.args.size()!=fs->params.size())
                    throw Error(loc(e.line,e.col,"wrong argument count calling "+e.name+": expected "+std::to_string(fs->params.size())+", got "+std::to_string(e.args.size())));
                for(size_t i=0;i<e.args.size();++i)
                    checkArgument(e.name,i+1,fs->params[i],*e.args[i],typeOf(*e.args[i]));
                return fs->ret;
            }
            // A struct argument needs a signature to lay out — register class,
            // copy area, hidden result pointer — and a ptr variable has none,
            // so a composite is refused rather than silently mis-marshalled.
            for(size_t i=0;i<e.args.size();++i){
                if(tyIsStruct(typeOf(*e.args[i])))
                    throw Error(loc(e.line,e.col,"an indirect call cannot take a struct argument: no signature is known to lay one out"));
            }
            return Ty::I32;
        }
        if(sig->second!=e.args.size())throw Error(loc(e.line,e.col,"wrong argument count calling "+e.name+": expected "+std::to_string(sig->second)+", got "+std::to_string(e.args.size())));
        static const std::vector<Ty> noTypes;
        const auto tp=paramTypes.find(e.name);
        const std::vector<Ty>& at=tp==paramTypes.end()?noTypes:tp->second;
        // v0.23.38-dev: the declared function type of each parameter, so an
        // argument that is itself a fn-pointer is checked against the
        // signature the callee asked for and not merely for being a ptr.
        static const std::vector<ParamSig> noSigs;
        const auto sp=paramFuncSig.find(e.name);
        const std::vector<ParamSig>& ps=sp==paramFuncSig.end()?noSigs:sp->second;
        for(size_t i=0;i<e.args.size();++i){
            const Ty actual=typeOf(*e.args[i]);
            const FuncSig* wantSig=(i<ps.size()&&ps[i].isFunc)?&ps[i].sig:nullptr;
            checkArgument(e.name,i+1,i<at.size()?at[i]:Ty::I32,*e.args[i],actual,wantSig);
        }
        auto rt=returnTypes.find(e.name);
        return rt==returnTypes.end()?Ty::I32:rt->second;
    }
    // v0.23.38-dev: `h.onClick(x)`. The field's declared function type is the
    // whole signature — the argument count, each argument's type, and the type
    // the call answers. Nothing here is looked up by name, which is exactly
    // what keeps a `fn onClick` in scope from capturing the call.
    Ty checkFieldCall(const Expr& e){
        const Expr& field=*e.a;
        const Ty base=typeOf(*field.a);
        const int sid=structBaseId(base,field.name);
        const StructField* f=structOf(sid).find(field.name);
        if(!f)throw Error(loc(field.line,field.col,"struct '"+structOf(sid).name+"' has no field named '"+field.name+"'"));
        if(!f->isFunc)
            throw Error(loc(e.line,e.col,"cannot call field '"+field.name+"': its type is "
                            +tyNameFull(f->ty)+", not a function type"));
        if(e.args.size()!=f->funcSig.params.size())
            throw Error(loc(e.line,e.col,"wrong argument count calling field '"+field.name+"': expected "
                            +std::to_string(f->funcSig.params.size())+", got "+std::to_string(e.args.size())));
        for(size_t i=0;i<e.args.size();++i)
            checkArgument("field '"+field.name+"'",i+1,f->funcSig.params[i],*e.args[i],typeOf(*e.args[i]));
        return f->funcSig.ret;
    }
    // if / while / for conditions: a comparison, any bool expression (the
    // true/false literals included), or any integer — v0.23.25-dev added the
    // last kind, whose truth is zero vs non-zero. A pointer or a struct is
    // neither, and stays refused.
    void checkCondition(const Expr& e){
        const Ty t=typeOf(e);   // also rejects pointer comparisons and &&/! misuse
        if(!isComparison(e.k)&&t!=Ty::Bool&&!tyIsInteger(t))
            throw Error(loc(e.line,e.col,"condition must be a comparison, a bool expression, or an integer"));
    }
    void checkStmt(const Stmt& s){
        switch(s.k){
            case Stmt::Let: {
                if(scopes.empty())scopes.emplace_back();
                if(scopes.back().count(s.name))throw Error(loc(s.line,s.col,"duplicate variable in scope: "+s.name));
                if(s.isArray){
                    // v0.23.28-dev: the initializer fills every element, so
                    // what has to hold is "one value of the element type".
                    // A struct element takes a copy of that struct (a struct
                    // has no register form, so there is no constant to fold);
                    // a bool element takes true/false or the 0/1 constant; a
                    // ptr element takes the null constant or another address.
                    // Everything else is the constant-integer path, range
                    // checked exactly as a global array initializer is.
                    if(tyIsStruct(s.ty)){
                        const Ty actual=typeOf(*s.expr);
                        checkValue(s.ty,*s.expr,actual,"array initializer type mismatch");
                    } else if(s.ty==Ty::Ptr){
                        const Ty actual=typeOf(*s.expr);
                        if(actual.k!=Ty::Ptr&&!isNullConstant(*s.expr))
                            throw Error(loc(s.line,s.col,"array initializer type mismatch: expected ptr, got "+tyNameFull(actual)+": "+s.name));
                    } else if(s.ty==Ty::Bool){
                        // `true`/`false`, or the 0/1 integer constant a bool
                        // slot has always accepted. constantInteger folds the
                        // second and refuses the first, so the value is read
                        // from whichever spelling is there and the range check
                        // is the same one a global bool initializer has.
                        const Ty actual=typeOf(*s.expr);
                        if(actual.k==Ty::Ptr||tyIsStruct(actual))
                            throw Error(loc(s.line,s.col,"array initializer type mismatch: expected bool, got "+tyNameFull(actual)+": "+s.name));
                        int64_t v=0;
                        if(!boolArrayValue(*s.expr,v))
                            throw Error(loc(s.line,s.col,"array initializer must be a constant expression: "+s.name));
                        if(!initializerFits(s.ty,*s.expr,v))
                            throw Error(loc(s.line,s.col,"local array initializer does not fit in "+tyNameFull(s.ty)+": "+s.name+" ("+std::to_string(v)+")"));
                    } else {
                        const Ty actual=typeOf(*s.expr);
                        if(actual==Ty::Bool)
                            throw Error(loc(s.line,s.col,"array initializer type mismatch: expected "+tyNameFull(s.ty)+", got bool: "+s.name));
                        if(actual.k==Ty::Ptr)
                            throw Error(loc(s.line,s.col,"array initializer type mismatch: expected "+tyNameFull(s.ty)+", got ptr: "+s.name));
                        int64_t v=0;
                        if(!constantInteger(*s.expr,v))
                            throw Error(loc(s.line,s.col,"array initializer must be a constant expression: "+s.name));
                        // v0.23.27-dev: the check a global array initializer has
                        // always had. A local array used to accept any constant
                        // and store its low bytes, so `let a: u8[4] = 300;` filled
                        // the array with 44 while the same line at file scope was
                        // an error. Both now agree, and neither truncates.
                        if(!initializerFits(s.ty,*s.expr,v))
                            throw Error(loc(s.line,s.col,"local array initializer does not fit in "+tyNameFull(s.ty)+": "+s.name+" ("+std::to_string(v)+")"));
                    }
                    scopes.back()[s.name]=Binding{Ty::Ptr,s.dims[0],s.ty,s.dims,{},false};   // name decays to the frame address
                } else {
                    // v0.23.29-dev: a struct local declared without an
                    // initializer — the only shape a struct that contains an
                    // array field can take, since an array field cannot be set
                    // by a literal — is zero-filled in its frame slots, so
                    // there is no expression to type-check. Register the
                    // binding and move on. (Only a struct local may omit `=`;
                    // every other kind is required to have one by the parser.)
                    if(!s.expr){scopes.back()[s.name]=Binding{s.ty,0,Ty::I32,{},FuncSig(),false};return;}
                    const Ty actual=typeOf(*s.expr);
                    if(tyIsStruct(s.ty)||tyIsStruct(actual))
                        checkValue(s.ty,*s.expr,actual,"type mismatch initializing '"+s.name+"'");
                    else if(s.isBool){
                        if(actual!=Ty::Bool&&!isBoolConstant(*s.expr))
                            throw Error(loc(s.line,s.col,"type mismatch initializing '"+s.name+"': expected bool"));
                    } else if(s.isPtr){
                        // v0.23.26-dev: `let p: ptr = 0;` — the null constant.
                        if(actual!=Ty::Ptr&&!isNullConstant(*s.expr))
                            throw Error(loc(s.line,s.col,"type mismatch initializing '"+s.name+"': expected ptr"));
                        // v0.23.34-dev: the diagnostic for the stride rule
                        // ptrToAssignable enforces. `let p: ptr = &w;` on an
                        // i64[2] would index at four bytes; `ptr<i64>` (or an
                        // array parameter) keeps the stride, so say which.
                        if(tyIsPtrToElem(actual)&&!ptrToAssignable(s.ty,actual,*s.expr)){
                            // The stride the slot would apply: its own element
                            // width, a ptr<S>'s sizeof(S), or an untyped ptr's
                            // four bytes. Naming the real number is the point —
                            // "would index it at 4 bytes" is only true of one
                            // of the three.
                            const uint32_t slotStride=tyIsPtrToElem(s.ty)?ptrElemWidth(s.ty)
                                                    :tyIsPtrToStruct(s.ty)?tySize(Ty::ofStruct(s.ty.sid))
                                                    :4u;
                            throw Error(loc(s.line,s.col,"cannot store a pointer to "+tyNameFull(ptrElemType(actual))
                                            +" elements in "+tyNameFull(s.ty)+": '"+s.name+"' would index it at "
                                            +std::to_string(slotStride)
                                            +" bytes — declare it ptr<"+tyNameFull(ptrElemType(actual))+">, or take the array as a parameter"));
                        }
                        // v0.23.38-dev: `let f: fn(i32) -> i32 = inc;` — the
                        // slot named a signature, so the value has to match
                        // it. This is what a function type is *for*: without
                        // it, the wrong callback is a pointer that fits.
                        if(s.isFunc)checkPtrSig(&s.funcSig,*s.expr,
                            "type mismatch initializing '"+s.name+"'");
                    } else {
                        if(actual==Ty::Ptr)throw Error(loc(s.line,s.col,"type mismatch initializing '"+s.name+"': expected i32, got ptr"));
                        if(actual==Ty::Bool)throw Error(loc(s.line,s.col,"type mismatch initializing '"+s.name+"': expected i32, got bool"));
                        // v0.23.27-dev: the same range check a global applies.
                        // `let b: u8 = 300;` inside a function used to store 44
                        // in silence, while at file scope it was
                        // "global initializer does not fit in u8". Narrowing a
                        // *value* (an i64 in an i32 slot) is still allowed —
                        // both scopes have always allowed that, and changing
                        // it would be a different decision — but a constant
                        // that does not fit the type it is written for is now
                        // an error in both places.
                        int64_t v=0;
                        if(constantInteger(*s.expr,v)&&!initializerFits(s.ty,*s.expr,v))
                            throw Error(loc(s.line,s.col,"local initializer does not fit in "+tyNameFull(s.ty)+": "+s.name+" ("+std::to_string(v)+")"));
                    }
                    // v0.23.34-dev: a `ptr<T>` local keeps the element type the
                    // declared stride names, so Sema's `p[i]` and codegen's
                    // answer the same type (a u8 element compares unsigned in
                    // both passes, not signed in one and unsigned in the other).
                    scopes.back()[s.name]=Binding{s.ty,0,tyIsPtrToElem(s.ty)?ptrElemType(s.ty):Ty::I32,{},s.funcSig,s.isFunc};
                }
                return;
            }
            case Stmt::Assign: {
                const Ty actual=typeOf(*s.expr);
                if(const Binding* b=find(s.name)){
                    if(b->len)throw Error(loc(s.line,s.col,"cannot assign to an array as a whole: "+s.name));
                    if(tyIsStruct(b->ty)||tyIsStruct(actual))
                        checkValue(b->ty,*s.expr,actual,"type mismatch assigning variable: "+s.name);
                    else if(b->ty==Ty::Bool){
                        if(actual!=Ty::Bool&&!isBoolConstant(*s.expr))
                            throw Error(loc(s.line,s.col,"type mismatch assigning variable: "+s.name+" (expected bool)"));
                    } else if(b->ty==Ty::Ptr){
                        // v0.23.26-dev: `p = 0;` clears a pointer.
                        if(actual!=Ty::Ptr&&!isNullConstant(*s.expr))throw Error(loc(s.line,s.col,"type mismatch assigning variable: "+s.name));
                    } else if(actual==Ty::Ptr||actual==Ty::Bool){
                        throw Error(loc(s.line,s.col,"type mismatch assigning variable: "+s.name));
                    }
                } else if(globalNames.count(s.name)){
                    if(arrayGlobals.count(s.name))throw Error(loc(s.line,s.col,"cannot assign to an array as a whole: "+s.name));
                    const Ty want=globalTypes.count(s.name)?globalTypes.at(s.name):Ty::I32;
                    if(tyIsStruct(want)||tyIsStruct(actual))
                        checkValue(want,*s.expr,actual,"type mismatch assigning variable: "+s.name);
                    else if(want==Ty::Bool){
                        if(actual!=Ty::Bool&&!isBoolConstant(*s.expr))
                            throw Error(loc(s.line,s.col,"type mismatch assigning variable: "+s.name+" (expected bool)"));
                    } else if(actual==Ty::Bool){
                        throw Error(loc(s.line,s.col,"type mismatch assigning variable: "+s.name+" (expected i32)"));
                    }
                } else throw Error(loc(s.line,s.col,"assignment to unknown variable: "+s.name));
                return;
            }
            case Stmt::IndexAssign: {
                // v0.23.31-dev: a chain that stops short of the elements
                // (`a[i]` on a two-dimensional array) addresses a row — a ptr
                // — and a store to one is as meaningless as a store to the
                // array itself. Typing the chain proves it first.
                std::string rowWhat;
                if(indexChainIsRow(*s.idx,&rowWhat))
                    throw Error(loc(s.line,s.col,"cannot assign to "+rowWhat+"[i]: it addresses a row, not an element"));
                // v0.23.31-dev: one subscript written on a multi-dimensional
                // array names the same row. The chain form proves it above; a
                // single subscript arrives as itself, so the dimension count
                // answers for it here. A one-dimensional array — one subscript,
                // one dimension — falls through untouched, and a full chain
                // (two or more subscripts) is `indexChainIsRow`'s business:
                // only it can see that the chain stopped short of the
                // elements, which is what `a[i]` on a 2-D array and `a[i][j]`
                // on a 3-D one both do.
                if(rowWhat.empty()&&s.subs<2){
                    const std::vector<uint32_t>* d=arrayDimsOfName(s.name);
                    if(d&&d->size()>1)
                        throw Error(loc(s.line,s.col,"cannot assign to '"+s.name+"'[i]: it addresses a row, not an element"));
                }
                // v0.23.28-dev: the subscript may not be a pointer (an address
                // is not an element number), but the *value* is checked against
                // the element type like any other store. It used to be refused
                // outright whenever it was a ptr, which is what kept `a[0] = p`
                // out of a `ptr[N]` — and what left `i32arr[0] = true` accepted.
                if(typeOf(*s.idx)==Ty::Ptr)throw Error(loc(s.line,s.col,"pointer indexing is not supported yet"));
                const Binding* b=find(s.name);
                if(b){
                    if(b->len)checkArrayBounds(s.name,*s.idx);
                    else if(b->ty!=Ty::Ptr)throw Error(loc(s.line,s.col,"cannot index non-array variable: "+s.name));
                } else {
                    if(!globalNames.count(s.name))throw Error(loc(s.line,s.col,"assignment to unknown array: "+s.name));
                    if(!arrayGlobals.count(s.name))throw Error(loc(s.line,s.col,"cannot index non-array global: "+s.name));
                    checkArrayBounds(s.name,*s.idx);
                }
                const Ty elem=arrayElemTypeOf(s.name);
                const Ty actual=typeOf(*s.expr);
                checkValue(elem,*s.expr,actual,"type mismatch assigning array element of '"+s.name+"'");
                return;
            }
            case Stmt::FieldAssign: {
                // v0.23.31-dev: the same row rule an IndexAssign gets — a
                // multi-dimensional array field subscripted once is a row
                // address, not an element to store through.
                std::string rowWhat;
                if(indexChainIsRow(*s.idx,&rowWhat))
                    throw Error(loc(s.line,s.col,"cannot assign to "+rowWhat+"[i]: it addresses a row, not an element"));
                // The target is a Field expression: typeOf both proves the base
                // is a struct or ptr<S> and yields the field's declared type.
                const Ty field=typeOf(*s.idx);
                const Ty actual=typeOf(*s.expr);
                checkValue(field,*s.expr,actual,"type mismatch assigning field '"+s.idx->name+"'");
                // v0.23.38-dev: `h.onClick = inc;` — a fn-pointer field is
                // stored by signature, which is the difference between a
                // callback table and eight bytes that happen to be an address.
                if(field==Ty::Ptr&&s.idx->k==Expr::Field){
                    const Ty base=typeOf(*s.idx->a);
                    const int sid=structBaseId(base,s.idx->name);
                    if(const StructField* f=structOf(sid).find(s.idx->name))
                        if(f->isFunc)
                            checkPtrSig(&f->funcSig,*s.expr,"type mismatch assigning field '"+s.idx->name+"'");
                }
                return;
            }
            case Stmt::DerefAssign: {
                if(typeOf(*s.idx)!=Ty::Ptr)throw Error(loc(s.line,s.col,"dereference assignment requires a ptr expression"));
                typeOf(*s.expr);   // a ptr value is legal here (64-bit store)
                return;
            }
            case Stmt::Return: {
                if(s.expr->k==Expr::Var){
                    const Binding* b=find(s.expr->name);
                    if(b&&b->len)
                        throw Error(loc(s.line,s.col,"cannot return a local array (its frame storage does not outlive the call): "+s.expr->name));
                }
                const Ty actual=typeOf(*s.expr);
                if(tyIsStruct(retType)||tyIsStruct(actual))
                    checkValue(retType,*s.expr,actual,"return type mismatch in function "+fn);
                else if(retBool){
                    if(actual!=Ty::Bool&&!isBoolConstant(*s.expr))
                        throw Error(loc(s.line,s.col,"return type mismatch in function "+fn+": expected bool"));
                } else if((actual==Ty::Ptr)!=retPtr){
                    // v0.23.26-dev: a `-> ptr` function may return the null
                    // constant; that is the ordinary "found nothing" answer.
                    if(!(retPtr&&isNullConstant(*s.expr)))
                        throw Error(loc(s.line,s.col,"return type mismatch in function "+fn));
                } else if(actual==Ty::Bool){
                    throw Error(loc(s.line,s.col,"return type mismatch in function "+fn+": expected i32, got bool"));
                }
                // v0.23.38-dev: `fn get() -> fn(i32) -> i32 { return inc; }` —
                // the function promised a signature, so what it returns has to
                // carry that one. This is the return-slot side of the same
                // check a fn-pointer variable gets at its initializer.
                if(retIsFunc&&actual==Ty::Ptr)
                    checkPtrSig(&retFuncSig,*s.expr,"return type mismatch in function "+fn);
                return;
            }
            case Stmt::Expr: {
                // v0.23.39-dev: a discarded call — type-check it exactly as a
                // value expression would (argument count, signature, width),
                // then throw the result away. Only a Call or FieldCall reaches
                // here; the parser guarantees it.
                typeOf(*s.expr);
                return;
            }
            case Stmt::If:
                checkCondition(*s.expr);
                checkBlock(s.thenBody,true);
                checkBlock(s.elseBody,true);
                return;
            case Stmt::While:
                checkCondition(*s.expr);
                ++loopDepth;checkBlock(s.thenBody,true);--loopDepth;
                return;
            case Stmt::For:
                scopes.emplace_back();
                for(const auto& init:s.forInit)checkStmt(init);
                checkCondition(*s.expr);
                ++loopDepth;checkBlock(s.thenBody,true);--loopDepth;
                for(const auto& step:s.forStep)checkStmt(step);
                scopes.pop_back();
                return;
            case Stmt::Break:
                if(loopDepth==0)throw Error(loc(s.line,s.col,"break used outside a loop"));
                return;
            case Stmt::Continue:
                if(loopDepth==0)throw Error(loc(s.line,s.col,"continue used outside a loop"));
                return;
        }
        throw Error(loc(s.line,s.col,"unsupported statement"));
    }
    void checkBlock(const std::vector<Stmt>& ss,bool newScope){
        if(newScope)scopes.emplace_back();
        for(const auto& s:ss)checkStmt(s);
        if(newScope)scopes.pop_back();
    }
    // Check one function body. Called once per emitted function, before its
    // Codegen instance is created.
    void check(const Function& f){
        fn=f.name;retPtr=f.returnPtr;retBool=f.returnBool;retType=f.retType;
        // v0.23.38-dev: the function type the body has to return, when it
        // declares one — the return slot's signature, checked at every
        // `return` exactly as a variable's is checked at its initializer.
        retIsFunc=f.returnIsFunc;retFuncSig=f.returnFuncSig;
        scopes.clear();loopDepth=0;
        scopes.emplace_back();
        for(size_t i=0;i<f.params.size();++i){
            // v0.23.34-dev: an array parameter (`fn f(a: i64[4])`) is a strided
            // pointer, so the binding carries the element type it strides over.
            // Without it Sema would type `a[i]` as i32 while codegen loads an
            // i64 — the two passes disagreeing about one expression, which is
            // what makes a u8 element compare unsigned in one and signed in
            // the other.
            const Ty pty=i<f.paramTypes.size()?f.paramTypes[i]:Ty::I32;
            // v0.23.35-dev: an array parameter now remembers its extent. The
            // binding carries the per-dimension lengths so sizeof/len can read
            // them; `len` is the total element count (product of the dims).
            static const std::vector<uint32_t> kEmptyDims;
            const std::vector<uint32_t>& pd = i<f.paramDims.size()?f.paramDims[i]:kEmptyDims;
            const uint32_t plen = pd.empty()?0:(uint32_t)dimsProduct(pd);
            scopes.back()[f.params[i]]=Binding{pty, plen, tyIsPtrToElem(pty)?ptrElemType(pty):Ty::I32, pd,
                i<f.paramFuncSig.size()?f.paramFuncSig[i]:FuncSig(), i<f.paramIsFunc.size()&&f.paramIsFunc[i]};
        }
        for(const auto& s:f.body)checkStmt(s);
    }
};

std::vector<CompiledFunction> compileProgram(const std::vector<Function>& functions,std::vector<Global>& globals,bool sharedObject=false,bool chainTail=true,bool boundsCheck=false,bool debugLine=false){
    std::map<std::string,size_t> arities;for(const auto& f:functions)arities[f.name]=f.params.size();
    std::set<std::string> globalNames,externGlobals,externFunctions,arrayGlobals,pointerFunctions,pointerReturnFunctions;
    std::set<std::string> boolGlobals,boolReturnFunctions;
    std::map<std::string,std::vector<bool>> functionParamPointers,functionParamBools;
    std::map<std::string,uint32_t> arrayLengths;
    std::map<std::string,std::vector<uint32_t>> arrayDims;
    for(const auto& f:functions){functionParamPointers[f.name]=f.paramPtr;functionParamBools[f.name]=f.paramBool;if(f.returnPtr||std::find(f.paramPtr.begin(),f.paramPtr.end(),true)!=f.paramPtr.end())pointerFunctions.insert(f.name);if(f.returnPtr)pointerReturnFunctions.insert(f.name);if(f.returnBool)boolReturnFunctions.insert(f.name);}
    // v0.23.21-dev: `load_ptr` yields a ptr, and the intrinsic check lives in
    // exprYieldsPtr's Call case — a free function that cannot see the function
    // table. Registering the name here instead makes the shadow work for free:
    // a program that defines its own `load_ptr` (which shadows the intrinsic
    // everywhere else — see the Call cases in checkCall and gen) simply does
    // not get the name inserted, and the special case disappears with it.
    if(!arities.count("load_ptr"))pointerReturnFunctions.insert("load_ptr");
    for(const auto& g:globals){globalNames.insert(g.name);if(g.external)externGlobals.insert(g.name);if(g.isBool)boolGlobals.insert(g.name);if(g.isArray){arrayGlobals.insert(g.name);arrayLengths[g.name]=g.dims[0];arrayDims[g.name]=g.dims;}}
    // v0.23.2-dev (P3.2): the type facts the code generator needs to pick load/store
    // widths and comparison condition codes. They come straight from the parsed
    // declarations, so every consumer (slot, global, parameter, return) agrees.
    std::map<std::string,Ty> globalTypeMap,returnTypeMap;
    std::map<std::string,std::vector<Ty>> argTypeMap;
    for(const auto& g:globals)globalTypeMap[g.name]=g.ty;
    for(const auto& f:functions){returnTypeMap[f.name]=f.retType;argTypeMap[f.name]=f.paramTypes;}
    // v0.23.37-dev: the signature of every fn-pointer global, collected once
    // and shared by Sema and every Codegen instance.
    std::map<std::string,FuncSig> globalFuncSigMap;
    for(const auto& g:globals)if(g.isFunc)globalFuncSigMap[g.name]=g.funcSig;
    // v0.23.38-dev: the function type each function returns (by name), and the
    // one each of its parameters asks for (by name and position). Collected
    // once here, beside the maps they parallel, and shared by every check.
    std::map<std::string,FuncSig> returnFuncSigMap;
    std::map<std::string,std::vector<ParamSig>> paramFuncSigMap;
    for(const auto& f:functions){
        if(f.returnIsFunc)returnFuncSigMap[f.name]=f.returnFuncSig;
        std::vector<ParamSig> ps(f.params.size());
        for(size_t i=0;i<f.params.size();++i)
            if(i<f.paramIsFunc.size()&&f.paramIsFunc[i]){
                ps[i].isFunc=true;
                ps[i].sig=i<f.paramFuncSig.size()?f.paramFuncSig[i]:FuncSig();
            }
        paramFuncSigMap[f.name]=std::move(ps);
    }
    for(const auto& f:functions)if(f.external)externFunctions.insert(f.name);
    bool needInit=false;for(const auto& g:globals)if(!g.external&&g.runtimeInit)needInit=true;
    if(needInit&&chainTail)arities[kInitNextSymbol]=0;
    std::vector<const Function*> order;
    if(sharedObject){for(const auto& f:functions)if(!f.external)order.push_back(&f);}
    else{for(const auto& f:functions)if(!f.external&&f.name=="main")order.push_back(&f);for(const auto& f:functions)if(!f.external&&f.name!="main")order.push_back(&f);}
    // P3.1: type-check every emitted function first, in its own pass. Codegen
    // still carries its own checks, so this pass can only report a type error
    // earlier — never accept something codegen would have rejected.
    Sema sema{arities,globalNames,externFunctions,arrayGlobals,boolGlobals,pointerReturnFunctions,boolReturnFunctions,
              functionParamPointers,functionParamBools,arrayLengths,arrayDims,globalTypeMap,argTypeMap,returnTypeMap,globalFuncSigMap,
              returnFuncSigMap,paramFuncSigMap};
    std::vector<CompiledFunction> out;out.reserve(order.size()+1);
    for(const Function* f:order){
        sema.check(*f);
        Codegen cg(f->name,arities,globalNames,externGlobals,externFunctions,arrayGlobals,pointerFunctions,pointerReturnFunctions,functionParamPointers,boolGlobals,boolReturnFunctions,functionParamBools,arrayLengths,arrayDims,sharedObject,needInit&&f->name=="main",kInitSymbol,boundsCheck,debugLine);
        cg.globalTypes=globalTypeMap;cg.argTypes=argTypeMap;cg.returnTypes=returnTypeMap;cg.globalFuncSig=globalFuncSigMap;
        CompiledFunction cf;cf.name=f->name;cf.code=cg.run(*f);cf.relocs=std::move(cg.relocations);cf.lineRows=std::move(cg.lineRows);cf.debugVars=std::move(cg.debugVars);
        cf.preservesRa=!cg.isMain;out.push_back(std::move(cf));}
    if(needInit){
        // Synthetic initializer: assignments in source declaration order, followed by a chained
        // call to the next object's initializer (link order) or a plain return for shared objects.
        Function init;init.name=kInitSymbol;init.external=false;
        for(auto& g:globals)if(!g.external&&g.runtimeInit){
            // A ptr global may be initialized with a pointer: the synthetic
            // initializer stores one exactly as any other function would. The
            // check is here for the other widths, where an address would be
            // silently truncated to its low 32 bits — and for a ptr global it
            // used to also fire, which is why `let g: ptr = "text";` was
            // rejected while the same statement inside a function worked.
            if(g.ty!=Ty::Ptr&&g.initExpr&&exprYieldsPtr(*g.initExpr,pointerReturnFunctions,arrayGlobals))
                throw Error("type mismatch initializing global '"+g.name+"': expected "+tyNameFull(g.ty)+", got ptr");
            Stmt st(Stmt::Assign);st.name=g.name;st.expr=std::move(g.initExpr);init.body.push_back(std::move(st));g.runtimeInit=false;}
        Stmt r(Stmt::Return);
        if(chainTail){E c(new Expr(Expr::Call));c->name=kInitNextSymbol;r.expr=std::move(c);}
        else r.expr=E(new Expr(Expr::Num,0));
        init.body.push_back(std::move(r));
        sema.check(init);   // the synthetic initializer is type-checked too
        Codegen cg(init.name,arities,globalNames,externGlobals,externFunctions,arrayGlobals,pointerFunctions,pointerReturnFunctions,functionParamPointers,boolGlobals,boolReturnFunctions,functionParamBools,arrayLengths,arrayDims,sharedObject,false,kInitSymbol,boundsCheck,debugLine);
        cg.globalTypes=globalTypeMap;cg.argTypes=argTypeMap;cg.returnTypes=returnTypeMap;cg.globalFuncSig=globalFuncSigMap;
        CompiledFunction cf;cf.name=init.name;cf.code=cg.run(init);cf.relocs=std::move(cg.relocations);cf.lineRows=std::move(cg.lineRows);cf.debugVars=std::move(cg.debugVars);
        cf.preservesRa=!cg.isMain;
        out.push_back(std::move(cf));
    }
    return out;
}
struct ObjectLayout {
    std::vector<uint32_t> ins;
    std::map<std::string,std::pair<uint64_t,uint64_t>> functions; // name -> (text offset, size)
    std::vector<uint8_t> data;
    std::vector<uint8_t> rodata;
    uint64_t bssSize=0;
    struct GlobalDef { std::string name; int kind; uint64_t offset; uint64_t size; }; // kind 1 = .data, 2 = .bss, 3 = .rodata
    std::vector<GlobalDef> globals;
    // -g: (text byte offset, source line) pairs in ascending address order —
    // one per statement boundary, plus one per function prologue. Empty unless
    // the build asked for line info, in which case nothing below reads it.
    std::vector<std::pair<uint64_t,uint32_t>> lineRows;
};
ObjectLayout layoutObject(const std::vector<CompiledFunction>& funcs,const std::vector<Global>& globals){
    ObjectLayout L;
    for(const auto& f:funcs){uint64_t off=L.ins.size()*4;L.functions[f.name]={off,uint64_t(f.code.size())*4};
        // A row whose instruction index is past the end of the function would
        // point into the next one, so it is dropped rather than mis-attributed.
        for(const auto& r:f.lineRows)if(r.ins<f.code.size())L.lineRows.push_back({off+uint64_t(r.ins)*4u,r.line});
        L.ins.insert(L.ins.end(),f.code.begin(),f.code.end());}
    for(const auto& g:globals){
        if(g.external)continue;
        // A global is aligned to at least its own storage width: an i64 sits on
        // an 8-byte boundary. For i32/bool/u8/u16 the width is <= the previous
        // floor of 4, so every pre-existing layout is unchanged.
        const uint64_t a=g.isString?1:std::max<uint64_t>(g.align<4?4:g.align,tySize(g.ty));
        if(g.isString){L.rodata.resize((size_t)alignUp(L.rodata.size(),a),0);uint64_t off=L.rodata.size();L.globals.push_back({g.name,3,off,g.rawData.size()});L.rodata.insert(L.rodata.end(),g.rawData.begin(),g.rawData.end());continue;}
        const uint64_t esz=tySize(g.ty);                       // bytes per element
        const uint64_t sz=g.isArray?uint64_t(g.count)*esz:esz;
        // Every global object is laid out as a 4-byte-sized slot so the object
        // linker's `s.size%4==0` and `s.value%4==0` invariants hold. i32/i64
        // slots are already multiples of 4, so only u8/u16 (and their arrays)
        // gain trailing zero padding; the meaningful esz bytes stay at the slot
        // start and the narrow load/store forms address them directly.
        const uint64_t slot=alignUp(sz,4);
        // A struct global carries the bytes its constant initializer was
        // folded into; nothing else about it differs — it is one aligned
        // object, in .data when the bytes are not all zero and in .bss when
        // they are. v0.23.28-dev: `let pts : Point [ 4 ] = Point { … }` is
        // the same object N times over, so the aggregate's bytes are repeated
        // once per element — the in-memory image of "every element is a copy".
        if(tyIsStruct(g.ty)){
            const uint64_t n=g.isArray?g.count:1;
            if(g.init==0){L.bssSize=alignUp(L.bssSize,a);L.globals.push_back({g.name,2,L.bssSize,slot});L.bssSize+=slot;continue;}
            L.data.resize((size_t)alignUp(L.data.size(),a),0);
            const uint64_t off=L.data.size();
            L.globals.push_back({g.name,1,off,slot});
            for(uint64_t i=0;i<n;++i)L.data.insert(L.data.end(),g.rawData.begin(),g.rawData.end());
            L.data.resize((size_t)(off+slot),0);
            continue;
        }
        if(tyIs64(g.ty)?g.wideInit==0:g.init==0){L.bssSize=alignUp(L.bssSize,a);L.globals.push_back({g.name,2,L.bssSize,slot});L.bssSize+=slot;}
        else{L.data.resize((size_t)alignUp(L.data.size(),a),0);uint64_t off=L.data.size();L.globals.push_back({g.name,1,off,slot});
            const uint64_t v=tyIs64(g.ty)?g.wideInit:(uint64_t)(uint32_t)g.init;
            const uint64_t n=g.isArray?g.count:1;
            for(uint64_t i=0;i<n;++i)for(uint64_t b=0;b<esz;++b)L.data.push_back(uint8_t(v>>(8*b)));
            L.data.resize((size_t)(off+slot),0);}
    }
    return L;
}
// ===========================================================================
// .debug_line (v0.23.12-dev, P4.2)
//
// A DWARF v4 line-number program: one unit per input object, one row per
// statement boundary. This is what a debugger reads to answer "which source
// line is this instruction?" and "where does a breakpoint for line N go?" —
// so that `lldb a.out` followed by `b foo.ast:12` lands on the right
// instruction, and a backtrace shows source lines instead of addresses.
//
// Addresses are written as offsets from the start of the unit's own .text,
// because a relocatable object cannot know where its text will land. Every
// address field is therefore a patch site (DebugLineBlob::patchSites), carried
// in .rela.debug_line as an R_AARCH64_ABS64 against the .text section symbol;
// the linker adds the final text virtual address.
// ===========================================================================
static void dbgPut16(std::vector<uint8_t>& o,uint16_t v){o.push_back(uint8_t(v&0xffu));o.push_back(uint8_t(v>>8));}
static void dbgPut32(std::vector<uint8_t>& o,uint32_t v){for(int i=0;i<4;++i)o.push_back(uint8_t(v>>(8*i)));}
static void dbgPut64(std::vector<uint8_t>& o,uint64_t v){for(int i=0;i<8;++i)o.push_back(uint8_t(v>>(8*i)));}
static void dbgUleb(std::vector<uint8_t>& o,uint64_t v){do{uint8_t b=uint8_t(v&0x7fu);v>>=7;if(v)b|=0x80u;o.push_back(b);}while(v);}
static void dbgSleb(std::vector<uint8_t>& o,int64_t v){
    for(;;){uint8_t b=uint8_t(v&0x7fu);v>>=7;
        if((v==0&&!(b&0x40u))||(v==-1&&(b&0x40u))){o.push_back(b);break;}
        o.push_back(uint8_t(b|0x80u));}
}
// R_AARCH64_ABS64: the only relocation .debug_line needs. Every address in the
// line program is one 64-bit field, so a plain absolute write is enough.
static constexpr uint32_t kRelAbs64=257;
// v0.23.33-dev: R_AARCH64_PREL32, for an .eh_frame FDE's initial_location in a
// relocatable object — the field is a 32-bit PC-relative displacement, which
// is exactly what "S + A - P" writes.
static constexpr uint32_t kRelPrel32=261;
// Both shared-object writers put .text at this offset with a link base of 0,
// so it is the address a linked .so's line table is written against.
static constexpr uint64_t kSharedTextVaddr=0x1000;
struct DebugLineBlob {
    std::vector<uint8_t> bytes;
    std::vector<uint64_t> patchSites;   // byte offset of each 8-byte address field
};
static void dbgPatchAddress(std::vector<uint8_t>& bytes,uint64_t site,uint64_t value){
    if(site+8>bytes.size())throw Error("internal error: .debug_line address patch site is out of bounds");
    for(int i=0;i<8;++i)bytes[(size_t)site+(size_t)i]=uint8_t(value>>(8*i));
}
// Rows are (text offset, 1-based source line), ascending in address.
static DebugLineBlob encodeDebugLine(const std::vector<std::pair<uint64_t,uint32_t>>& rowsIn,
                                     uint64_t textSize,
                                     const std::string& compDir,
                                     const std::string& fileName){
    DebugLineBlob out;
    // Drop rows outside .text and collapse repeats: two rows at one address are
    // ambiguous to a debugger, and the earlier one is the one that owns it.
    std::vector<std::pair<uint64_t,uint32_t>> rows;
    for(const auto& r:rowsIn){
        if(r.second==0||r.first>=textSize)continue;
        if(!rows.empty()&&rows.back().first==r.first)continue;
        rows.push_back(r);
    }
    if(rows.empty())return out;
    std::vector<uint8_t> prog;
    auto advancePc=[&](uint64_t delta){ if(delta==0)return; prog.push_back(0x02);dbgUleb(prog,delta/4); };
    prog.push_back(0x00);dbgUleb(prog,9);prog.push_back(0x02);   // DW_LNE_set_address
    const uint64_t addrSite=prog.size();
    dbgPut64(prog,0);
    uint64_t addr=0;int64_t line=1;
    for(const auto& r:rows){
        advancePc(r.first-addr);addr=r.first;
        if(r.second!=(uint32_t)line){prog.push_back(0x03);dbgSleb(prog,(int64_t)r.second-line);line=r.second;}
        prog.push_back(0x01);                                    // DW_LNS_copy
    }
    advancePc(textSize-addr);
    prog.push_back(0x00);dbgUleb(prog,1);prog.push_back(0x01);   // DW_LNE_end_sequence
    std::vector<uint8_t> h;
    dbgPut32(h,0);              // unit_length (patched below)
    dbgPut16(h,4);              // DWARF version 4
    dbgPut32(h,0);              // header_length (patched below)
    h.push_back(4);             // minimum_instruction_length: 4 bytes per instruction
    h.push_back(1);             // maximum_operations_per_instruction (v4 only)
    h.push_back(1);             // default_is_stmt
    h.push_back(uint8_t(0xfb)); // line_base = -5
    h.push_back(14);            // line_range
    h.push_back(13);            // opcode_base
    static const uint8_t kStdLens[12]={0,1,1,1,1,0,0,0,1,0,0,1};
    for(uint8_t b:kStdLens)h.push_back(b);
    // A DWARF v4 line table normally leaves the directory to DW_AT_comp_dir in
    // .debug_info, and Aster emits no .debug_info. So the directory goes in the
    // include_directories list and the file points at it (indices there are
    // 1-based), which makes the full source path discoverable on its own.
    const std::string dir=compDir.empty()?std::string("."):compDir;
    h.insert(h.end(),dir.begin(),dir.end());h.push_back(0);h.push_back(0);  // include_directories + terminator
    const std::string file=fileName.empty()?std::string("<aster>"):fileName;
    h.insert(h.end(),file.begin(),file.end());h.push_back(0);
    dbgUleb(h,1);dbgUleb(h,0);dbgUleb(h,0);                                  // dir index, mtime, length
    h.push_back(0);                                                          // file_names terminator
    const uint32_t headerLength=uint32_t(h.size()-10),unitLength=uint32_t(h.size()-4+prog.size());
    for(int i=0;i<4;++i)h[(size_t)i]=uint8_t(unitLength>>(8*i));
    for(int i=0;i<4;++i)h[(size_t)(6+i)]=uint8_t(headerLength>>(8*i));
    out.bytes=h;out.bytes.insert(out.bytes.end(),prog.begin(),prog.end());
    out.patchSites.push_back(uint64_t(h.size())+addrSite);
    return out;
}
// ===========================================================================
// v0.23.32-dev: a DWARF v4 .debug_info section. The line table answers "which
// source line is this instruction?"; this answers the three questions a line
// table cannot: what is this thing *called*, what *type* is it, and *where*
// does it live. Without it a debugger can show a backtrace with file and line
// and still print nothing for `p x` — there is no name, no type and no address
// for any variable anywhere in the image, because a line program is addresses
// and lines and nothing else.
//
// The shape is one compilation unit per input object, exactly as the line
// table does it, so a link of two -g objects carries two units. Addresses are
// written as zero and carried in .rela.debug_info as R_AARCH64_ABS64 against
// the symbol they name — a function symbol for a subprogram's low_pc, a global
// symbol for DW_OP_addr, the .text section symbol for the unit's own range —
// and the linker fills them in. That is the same patch-site mechanism the line
// program already uses, and it is why an object can be linked anywhere.
//
// One .debug_abbrev serves every unit: the table below is a fixed declaration
// of every DIE shape this compiler can emit, so two objects' abbreviation
// tables are byte-identical and a link keeps one copy at offset 0.
// ===========================================================================
struct DebugInfoBlob {
    std::vector<uint8_t> bytes;
    std::vector<uint8_t> abbrev;
    // An address field in .debug_info: its byte offset, the symbol it means,
    // and how far past that symbol it points. A CU's low_pc is ".text" + 0,
    // a subprogram's its own function, a global's its own object.
    struct Patch { uint64_t offset; std::string symbol; int64_t addend; };
    std::vector<Patch> patches;
};
// Abbreviation codes. The table is part of the format an object ships, so the
// codes are fixed rather than allocated per unit.
enum : uint8_t {
    kAbbrCu=1,kAbbrBaseType=2,kAbbrPointer=3,kAbbrArray=4,kAbbrSubrange=5,
    kAbbrStruct=6,kAbbrMember=7,kAbbrSubprogram=8,kAbbrGlobalVar=9,
    kAbbrLocalVar=10,kAbbrParam=11,kAbbrUnspecified=12
};
// DWARF v4, 64-bit addresses: unit_length, version, debug_abbrev_offset,
// address_size. A DW_FORM_ref4 is an offset from the byte after this header,
// which is why the writer's own offsets need no adjusting.
static constexpr uint64_t kCuHeaderSize=11;
static const std::vector<uint8_t>& debugAbbrevTable(){
    static const std::vector<uint8_t> t=[]{
        struct A{uint8_t code;uint32_t tag;uint8_t kids;std::vector<std::pair<uint16_t,uint16_t>> at;};
        // Attributes
        const uint16_t kName=0x03,kLoc=0x02,kStmt=0x10,kLowPc=0x11,kHighPc=0x12,kLang=0x13,
            kCompDir=0x1b,kProducer=0x25,kByteSize=0x0b,kEncoding=0x3e,kType=0x49,
            kUpper=0x2f,kMemberLoc=0x38,kDeclLine=0x3b,kExternal=0x3f,kFrameBase=0x40;
        // Forms
        const uint16_t fAddr=0x01,fData1=0x0b,fData2=0x05,fData4=0x06,fData8=0x07,
            fStr=0x08,fRef4=0x13,fExpr=0x18,fFlagPresent=0x19;
        const A defs[]={
            {kAbbrCu,0x11,1,{{kProducer,fStr},{kLang,fData2},{kName,fStr},{kCompDir,fStr},
                             {kLowPc,fAddr},{kHighPc,fData8},{kStmt,fData4}}},
            {kAbbrBaseType,0x24,0,{{kName,fStr},{kByteSize,fData1},{kEncoding,fData1}}},
            {kAbbrPointer,0x0f,0,{{kByteSize,fData1},{kType,fRef4}}},
            {kAbbrArray,0x01,1,{{kType,fRef4}}},
            {kAbbrSubrange,0x21,0,{{kUpper,fData4}}},
            {kAbbrStruct,0x13,1,{{kName,fStr},{kByteSize,fData2}}},
            {kAbbrMember,0x0d,0,{{kName,fStr},{kType,fRef4},{kMemberLoc,fData4}}},
            {kAbbrSubprogram,0x2e,1,{{kName,fStr},{kLowPc,fAddr},{kHighPc,fData8},{kFrameBase,fExpr},
                                     {kType,fRef4},{kDeclLine,fData4},{kExternal,fFlagPresent}}},
            {kAbbrGlobalVar,0x34,0,{{kName,fStr},{kType,fRef4},{kLoc,fExpr},{kExternal,fFlagPresent}}},
            {kAbbrLocalVar,0x34,0,{{kName,fStr},{kType,fRef4},{kLoc,fExpr},{kDeclLine,fData4}}},
            {kAbbrParam,0x05,0,{{kName,fStr},{kType,fRef4},{kLoc,fExpr},{kDeclLine,fData4}}},
            // DW_TAG_unspecified_type: the target of an untyped ptr.
            {kAbbrUnspecified,0x3b,0,{}}
        };
        std::vector<uint8_t> o;
        for(const A& d:defs){
            dbgUleb(o,d.code);dbgUleb(o,d.tag);o.push_back(d.kids);
            for(const auto& p:d.at){dbgUleb(o,p.first);dbgUleb(o,p.second);}
            o.push_back(0);o.push_back(0);
        }
        o.push_back(0);   // end of the table
        return o;
    }();
    return t;
}
struct DwarfDieWriter {
    std::vector<uint8_t> info;                 // the DIE bytes, header excluded
    std::vector<DebugInfoBlob::Patch> patches; // offsets are relative to `info`
    std::map<std::string,uint32_t> types;      // type key -> DIE offset
    // A DW_FORM_ref4 counts from the first byte of the unit *header*, not from
    // the first DIE, so every offset handed out is the writer's own offset plus
    // the header the encoder prepends. (The unit's low_pc is patched against
    // .text for the same reason: nothing here knows its own address yet.)
    uint32_t dieOffset() const { return (uint32_t)info.size()+(uint32_t)kCuHeaderSize; }
    static std::string typeKey(Ty t,const std::vector<uint32_t>& dims){
        std::string k=tyName(t);k.push_back('#');k+=std::to_string(t.sid);
        if(!dims.empty()){k.push_back('[');for(uint32_t d:dims){k+=std::to_string(d);k.push_back(',');}k.push_back(']');}
        return k;
    }
    void name(const std::string& s){info.insert(info.end(),s.begin(),s.end());info.push_back(0);}
    void expr(const std::vector<uint8_t>& ops){dbgUleb(info,(uint64_t)ops.size());info.insert(info.end(),ops.begin(),ops.end());}
    // DW_OP_fbreg(slot*8): the variable's frame offset from DW_AT_frame_base.
    static std::vector<uint8_t> fbregOps(int slot){std::vector<uint8_t> e;e.push_back(0x91);dbgSleb(e,(int64_t)slot*8);return e;}
    // DW_OP_breg31 + 0: "the value of SP right now". Aster's frame is a fixed
    // 8192 bytes and SP does not move again inside the body, so SP itself is
    // the frame base — no CFA rules and no .eh_frame are needed to read it.
    static std::vector<uint8_t> frameBaseOps(){std::vector<uint8_t> e;e.push_back(0x8f);dbgSleb(e,0);return e;}
    // DW_OP_addr with a zeroed 8-byte operand: the linker fills it in.
    void addrOps(const std::string& symbol,int64_t addend){
        std::vector<uint8_t> e;e.push_back(0x03);for(int i=0;i<8;++i)e.push_back(0);
        const uint64_t base=info.size();
        expr(e);
        // length byte, then the opcode, then the operand
        patches.push_back({base+2,symbol,addend});
    }
    uint32_t unspecifiedRef(){
        auto it=types.find("unspecified");if(it!=types.end())return it->second;
        const uint32_t off=dieOffset();types["unspecified"]=off;
        dbgUleb(info,kAbbrUnspecified);
        return off;
    }
    uint32_t typeRef(Ty t,const std::vector<uint32_t>& dims){
        const std::string key=typeKey(t,dims);
        auto it=types.find(key);if(it!=types.end())return it->second;
        if(!dims.empty()){
            // An array of arrays: the element type is the array one dimension
            // in, so `i32[2][3]` is two elements of `i32[3]`, as in C.
            const uint32_t elem=typeRef(t,std::vector<uint32_t>(dims.begin()+1,dims.end()));
            const uint32_t off=dieOffset();types[key]=off;
            dbgUleb(info,kAbbrArray);dbgPut32(info,elem);
            dbgUleb(info,kAbbrSubrange);dbgPut32(info,dims[0]?dims[0]-1u:0u);
            dbgUleb(info,0);
            return off;
        }
        const uint32_t off=dieOffset();types[key]=off;
        if(t.k==Ty::Ptr){
            dbgUleb(info,kAbbrPointer);info.push_back(8);
            // The target may not exist yet — a ptr<S> can point at the struct
            // it is a field of — so the reference is a placeholder filled after
            // the recursive call, and `off` is recorded before it.
            const size_t at=info.size();dbgPut32(info,0);
            const uint32_t target=t.sid>=0?typeRef(Ty::ofStruct(t.sid),{}):unspecifiedRef();
            for(int i=0;i<4;++i)info[at+(size_t)i]=uint8_t(target>>(8*i));
            return off;
        }
        if(t.k==Ty::Struct){
            const StructDef& sd=structOf(t.sid);
            dbgUleb(info,kAbbrStruct);name(sd.name);dbgPut16(info,(uint16_t)sd.size);
            for(const StructField& f:sd.fields){
                std::vector<uint32_t> fd=f.dims;
                if(fd.empty()&&f.len>0)fd.push_back((uint32_t)f.len);
                const uint32_t mref=typeRef(f.ty,fd);
                dbgUleb(info,kAbbrMember);name(f.name);dbgPut32(info,mref);dbgPut32(info,f.offset);
            }
            dbgUleb(info,0);
            return off;
        }
        const char* nm="i32";uint8_t size=4,enc=0x05;   // DW_ATE_signed
        switch(t.k){
            case Ty::I32:  nm="i32"; size=4;enc=0x05;break;
            case Ty::U32:  nm="u32"; size=4;enc=0x07;break;   // DW_ATE_unsigned
            case Ty::U8:   nm="u8";  size=1;enc=0x07;break;
            case Ty::U16:  nm="u16"; size=2;enc=0x07;break;
            case Ty::I64:  nm="i64"; size=8;enc=0x05;break;
            // A bool slot is four bytes wide (v0.23.2-dev), so its type says so.
            case Ty::Bool: nm="bool";size=4;enc=0x02;break;   // DW_ATE_boolean
            default: break;
        }
        dbgUleb(info,kAbbrBaseType);
        info.insert(info.end(),nm,nm+std::strlen(nm));info.push_back(0);
        info.push_back(size);info.push_back(enc);
        return off;
    }
};
static DebugInfoBlob encodeDebugInfo(const ObjectLayout& L,
                                     const std::vector<CompiledFunction>& funcs,
                                     const std::vector<Function>& srcFuncs,
                                     const std::vector<Global>& globals,
                                     const std::string& compDir,
                                     const std::string& fileName){
    DebugInfoBlob out;
    out.abbrev=debugAbbrevTable();
    DwarfDieWriter w;
    std::map<std::string,const Function*> byName;
    for(const auto& f:srcFuncs)byName[f.name]=&f;
    std::map<std::string,const ObjectLayout::GlobalDef*> gdef;
    for(const auto& g:L.globals)gdef[g.name]=&g;
    // ---- the compilation unit ---------------------------------------------
    dbgUleb(w.info,kAbbrCu);
    const std::string producer=std::string("Aster v")+kVersion;
    w.name(producer);
    dbgPut16(w.info,1);                                    // DW_LANG_C89: a debugger's
    // C expression evaluator is what prints an i32 as an int and a struct by
    // its fields, which is exactly the reading Aster's own types want.
    w.name(fileName.empty()?std::string("<aster>"):fileName);
    w.name(compDir.empty()?std::string("."):compDir);
    dbgPut64(w.info,0);                                    // DW_AT_low_pc: patched
    w.patches.push_back({(uint64_t)w.info.size()-8,".text",0});
    dbgPut64(w.info,(uint64_t)L.ins.size()*4u);            // DW_AT_high_pc: a length
    dbgPut32(w.info,0);                                    // DW_AT_stmt_list
    // ---- every type the variables and functions below will name -----------
    // Emitted first, because a DW_FORM_ref4 is a forward offset: a DIE can
    // only point at one that already exists.
    for(const auto& f:funcs){
        auto it=byName.find(f.name);if(it==byName.end())continue;
        w.typeRef(it->second->retType,{});
        for(const DebugVar& v:f.debugVars)w.typeRef(v.ty,v.dims);
    }
    for(const auto& g:globals){
        if(g.external||g.isString||g.fromEmbed)continue;
        w.typeRef(g.ty,g.dims.empty()?(g.isArray?std::vector<uint32_t>{g.count}:std::vector<uint32_t>{}):g.dims);
    }
    // ---- globals: one DW_TAG_variable per object with an address ----------
    for(const auto& g:globals){
        if(g.external||g.isString||g.fromEmbed)continue;
        if(!gdef.count(g.name))continue;                   // laid out in this object
        const std::vector<uint32_t> dims=g.dims.empty()?(g.isArray?std::vector<uint32_t>{g.count}:std::vector<uint32_t>{}):g.dims;
        dbgUleb(w.info,kAbbrGlobalVar);
        w.name(g.name);
        dbgPut32(w.info,w.typeRef(g.ty,dims));
        w.addrOps(g.name,0);
    }
    // ---- one DW_TAG_subprogram per function -------------------------------
    for(const auto& f:funcs){
        auto it=byName.find(f.name);
        if(it==byName.end())continue;                      // a synthetic routine
        const Function& src=*it->second;
        const uint64_t size=L.functions.count(f.name)?L.functions.at(f.name).second:0;
        dbgUleb(w.info,kAbbrSubprogram);
        w.name(f.name);
        dbgPut64(w.info,0);                                // DW_AT_low_pc: patched
        w.patches.push_back({(uint64_t)w.info.size()-8,f.name,0});
        dbgPut64(w.info,size);                             // DW_AT_high_pc: a length
        w.expr(DwarfDieWriter::frameBaseOps());
        dbgPut32(w.info,w.typeRef(src.retType,{}));
        dbgPut32(w.info,(uint32_t)src.line);
        for(const DebugVar& v:f.debugVars){
            const bool param=v.isParam;
            dbgUleb(w.info,param?kAbbrParam:kAbbrLocalVar);
            w.name(v.name);
            dbgPut32(w.info,w.typeRef(v.ty,v.dims));
            w.expr(DwarfDieWriter::fbregOps(v.slot));
            dbgPut32(w.info,(uint32_t)v.line);
        }
        dbgUleb(w.info,0);                                 // end of the subprogram's children
    }
    dbgUleb(w.info,0);                                     // end of the unit's children
    // ---- the unit header --------------------------------------------------
    std::vector<uint8_t> h;
    dbgPut32(h,(uint32_t)(w.info.size()+7));               // unit_length: after this field
    dbgPut16(h,4);                                         // DWARF version 4
    dbgPut32(h,0);                                         // debug_abbrev_offset
    h.push_back(8);                                        // address_size
    out.bytes=h;out.bytes.insert(out.bytes.end(),w.info.begin(),w.info.end());
    for(const auto& p:w.patches)out.patches.push_back({p.offset+kCuHeaderSize,p.symbol,p.addend});
    return out;
}
// ===========================================================================
// v0.23.33-dev: an .eh_frame section — the answer to "how do I walk this
// stack?", which .debug_info cannot give. A DIE says a local lives at
// fbreg+40; it does not say what SP was before this frame existed, and without
// that a debugger can name the frame it stopped in and nothing above it.
// Call-frame information is the second half of the same observation the last
// round was built on, and it is free for the same reason: **every Aster frame
// is a fixed 8192 bytes and SP does not move again inside a body**. So the
// canonical frame address is one rule — CFA = SP + 8192 once the prologue's
// SUB has run — and the return address is one more: a body that returns stores
// X30 at SP + 8184, which is CFA - 8. There is no frame pointer, no push/pop
// bookkeeping and no variable-sized frame, so a function's entire unwinding
// table is six bytes of CFI.
//
// The layout is the one `aarch64-linux-gnu-gcc` emits, read off a real object
// rather than from a specification: a CIE with augmentation "zR" — a
// pcrel/sdata4 FDE pointer, so a shared object carries no relocation against
// its own table — and one FDE per function whose initial_location is that
// pcrel sdata4 field. In an ET_REL object the field is carried by
// R_AARCH64_PREL32 against the function's own symbol, which is the same
// patch-site idea .debug_info uses in its 32-bit PC-relative form; a static
// image and a .so write the value directly, because by then every address is
// known. The CFI program's leading byte is a nop, which is where gas puts the
// augmentation length a consumer that expects "z" will read — so both readings
// of the format agree on what follows it.
// ===========================================================================
struct EhFrameBlob {
    std::vector<uint8_t> bytes;
    // A pcrel sdata4 field: its byte offset in `bytes`, the symbol it means and
    // how far past that symbol it points. The value to write is
    // (symbol + addend) - (the section's address + offset).
    struct Patch { uint64_t offset; std::string symbol; int64_t addend; };
    std::vector<Patch> patches;
    // Where each FDE starts, in the same order as `patches` — what a
    // .eh_frame_hdr row has to name, and the only part of an FDE a writer that
    // did not build it can still recover from the bytes.
    std::vector<uint64_t> fdeOffsets;
};
static EhFrameBlob encodeEhFrame(const ObjectLayout& L,const std::vector<CompiledFunction>& funcs){
    EhFrameBlob out;
    if(funcs.empty())return out;
    // ---- the CIE: one per object, at offset 0 --------------------------------
    std::vector<uint8_t> cie;
    ehPut32(cie,0);                                  // CIE_id: this is a CIE
    cie.push_back(1);                                // version
    cie.insert(cie.end(),{'z','R',0});               // augmentation
    cie.push_back(4);                                // code alignment: one instruction is 4 bytes
    cie.push_back(0x78);                             // data alignment: SLEB128 -8
    cie.push_back(30);                               // return address column: X30
    cie.push_back(1);                                // augmentation data length
    cie.push_back(0x1b);                             // DW_EH_PE_pcrel | DW_EH_PE_sdata4
    cie.insert(cie.end(),{0x0c,0x1f,0x00});          // DW_CFA_def_cfa: r31 (sp) ofs 0
    ehPut32(out.bytes,(uint32_t)cie.size());
    out.bytes.insert(out.bytes.end(),cie.begin(),cie.end());
    // ---- one FDE per function -----------------------------------------------
    uint64_t entryStart=out.bytes.size();
    for(const auto& f:funcs){
        const uint64_t size=L.functions.count(f.name)?L.functions.at(f.name).second:0;
        std::vector<uint8_t> body;
        // The CIE pointer is the distance backwards from this field to the CIE,
        // and the CIE starts the section — so it is this field's own offset.
        ehPut32(body,uint32_t(entryStart+4));
        const uint64_t patchAt=out.bytes.size()+4+body.size();
        ehPut32(body,0);                             // initial_location: pcrel sdata4, patched
        ehPut32(body,(uint32_t)size);                // address_range
        body.push_back(0x00);                        // the augmentation byte a "z" reader consumes
        body.push_back(0x41);                        // DW_CFA_advance_loc 1: the SUB has run
        body.push_back(0x0e);ehUleb(body,8192);      // DW_CFA_def_cfa_offset: CFA = SP + 8192
        if(f.preservesRa){
            body.push_back(0x41);                    // ... and the STR X30 has run
            body.push_back(0x9e);ehUleb(body,1);     // DW_CFA_offset: r30 at CFA - 8
        }
        while(body.size()%4u!=0)body.push_back(0x00);// DW_CFA_nop: an entry is a whole number of words
        ehPut32(out.bytes,(uint32_t)body.size());
        out.bytes.insert(out.bytes.end(),body.begin(),body.end());
        out.patches.push_back({patchAt,f.name,0});
        out.fdeOffsets.push_back(entryStart);
        entryStart+=4+body.size();
    }
    return out;
}
// v0.23.33-dev: the .eh_frame_hdr rows for a table built above — one per FDE,
// naming its function rather than its address, because the writer that lays the
// table out is the one that knows where the functions ended up.
static std::vector<std::pair<std::string,uint64_t>> ehFrameFdeList(const EhFrameBlob& ef){
    std::vector<std::pair<std::string,uint64_t>> out;
    for(size_t i=0;i<ef.patches.size();++i)out.push_back({ef.patches[i].symbol,i<ef.fdeOffsets.size()?ef.fdeOffsets[i]:0});
    return out;
}
void writeObject(const std::string& path,const std::vector<CompiledFunction>& funcs,const std::vector<Global>& globals,bool pic=false,
                 const DebugLineBlob& debugLine=DebugLineBlob{},const DebugInfoBlob& debugInfo=DebugInfoBlob{},
                 const EhFrameBlob& ehFrame=EhFrameBlob{}){
    if(funcs.empty())throw Error("cannot write an empty object");
    // In PIC mode the object keeps every source-level name (no main -> _start aliasing) and all
    // global accesses already reference the __aster_gat_<name> slot that the shared-object linker
    // materializes; main is an ordinary function so the object can be linked into a .so.
    auto nameOf=[&](const std::string& n)->std::string{return pic?n:elfNameOf(n);};
    ObjectLayout L=layoutObject(funcs,globals);
    const bool hasData=!L.data.empty(), hasBss=L.bssSize>0, hasRodata=!L.rodata.empty();
    const bool hasDebugLine=!debugLine.bytes.empty();
    // v0.23.32-dev: .debug_info and its table of abbreviations. The three new
    // sections are numbered after every section that existed before, and only
    // when -g asked for them, so an ordinary object is unchanged byte for byte.
    const bool hasDebugInfo=!debugInfo.bytes.empty();
    uint16_t idxText=1,idxData=0,idxBss=0,idxRodata=0,next=2;
    if(hasData)idxData=next++;
    if(hasBss)idxBss=next++;
    if(hasRodata)idxRodata=next++;
    uint16_t idxDebugLine=0,idxRelaDebugLine=0,idxDebugAbbrev=0,idxDebugInfo=0,idxRelaDebugInfo=0;
    if(hasDebugLine){idxDebugLine=next++;idxRelaDebugLine=next++;}
    if(hasDebugInfo){idxDebugAbbrev=next++;idxDebugInfo=next++;idxRelaDebugInfo=next++;};
    // v0.23.33-dev: .eh_frame and its relocations, numbered after the debug
    // sections for the same reason — an ordinary object is unchanged.
    const bool hasEhFrame=!ehFrame.bytes.empty();
    uint16_t idxEhFrame=0,idxRelaEhFrame=0;
    if(hasEhFrame){idxEhFrame=next++;idxRelaEhFrame=next++;}
    const uint16_t idxRela=next++,idxSym=next++,idxStr=next++,idxShstr=next++,shnum=next;
    std::vector<Rela> relas,relasDl,relasDi,relasEh;
    std::string strtab(1,'\0');
    std::map<std::string,uint32_t> nameOff;
    auto addName=[&](const std::string& n)->uint32_t{auto it=nameOff.find(n);if(it!=nameOff.end())return it->second;uint32_t o=(uint32_t)strtab.size();strtab+=n;strtab.push_back('\0');nameOff[n]=o;return o;};
    std::set<std::string> defined,needed;std::map<std::string,uint32_t> neededType; // 1 = OBJECT, 2 = FUNC
    for(const auto& f:funcs)defined.insert(nameOf(f.name));
    for(const auto& g:L.globals)defined.insert(g.name);
    for(const auto& f:funcs)for(const auto& r:f.relocs){std::string n=(r.type==Codegen::kRelCall26)?nameOf(r.symbol):r.symbol;needed.insert(n);neededType[n]=(r.type==Codegen::kRelCall26)?2u:1u;}
    std::vector<std::string> undefined;for(const auto& n:needed)if(!defined.count(n))undefined.push_back(n);
    std::vector<Sym> syms(1+funcs.size()+L.globals.size()+undefined.size()+((hasDebugLine||hasDebugInfo)?1u:0u));std::map<std::string,uint32_t> symIndex;
    for(size_t i=0;i<funcs.size();++i){const auto& f=funcs[i];Sym& s=syms[i+1];std::string en=nameOf(f.name);s.name=addName(en);s.info=0x12;s.shndx=idxText;s.value=L.functions.at(f.name).first;s.size=L.functions.at(f.name).second;symIndex[en]=(uint32_t)i+1;}
    for(size_t i=0;i<L.globals.size();++i){const auto& g=L.globals[i];Sym& s=syms[1+funcs.size()+i];s.name=addName(g.name);s.info=0x11;s.shndx=g.kind==1?idxData:(g.kind==3?idxRodata:idxBss);s.value=g.offset;s.size=g.size;symIndex[g.name]=(uint32_t)(1+funcs.size()+i);}
    for(size_t i=0;i<undefined.size();++i){Sym& s=syms[1+funcs.size()+L.globals.size()+i];s.name=addName(undefined[i]);s.info=(neededType.at(undefined[i])==2)?0x12:0x11;s.shndx=0;symIndex[undefined[i]]=(uint32_t)(1+funcs.size()+L.globals.size()+i);}
    // A local STT_SECTION symbol for .text, so .rela.debug_line and
    // .rela.debug_info can say "the address this unit's text starts at" the
    // way any ELF object would.
    uint32_t textSymIndex=0;
    if(hasDebugLine||hasDebugInfo){
        const uint32_t i=(uint32_t)(1+funcs.size()+L.globals.size()+undefined.size());
        Sym& s=syms[i];s.name=addName(".text");s.info=0x03;s.shndx=idxText;s.value=0;s.size=0;
        symIndex[".text"]=i;textSymIndex=i;
        for(uint64_t site:debugLine.patchSites){Rela rel{};rel.offset=site;rel.info=(uint64_t)textSymIndex<<32|kRelAbs64;rel.addend=0;relasDl.push_back(rel);}
    }
    for(const auto& f:funcs)for(const auto& r:f.relocs){std::string en=(r.type==Codegen::kRelCall26)?nameOf(r.symbol):r.symbol;Rela rel{};rel.offset=L.functions.at(f.name).first+r.offset;rel.info=(uint64_t)symIndex.at(en)<<32|r.type;rel.addend=0;relas.push_back(rel);}
    // v0.23.32-dev: .rela.debug_info — one R_AARCH64_ABS64 per address the unit
    // wrote as zero, against the function, global or section symbol it names.
    if(hasDebugInfo)for(const auto& p:debugInfo.patches){
        const std::string en=(p.symbol==".text")?p.symbol:nameOf(p.symbol);
        auto it=symIndex.find(en);
        if(it==symIndex.end())throw Error("internal error: .debug_info references unknown symbol '"+en+"'");
        Rela rel{};rel.offset=p.offset;rel.info=(uint64_t)it->second<<32|kRelAbs64;rel.addend=p.addend;relasDi.push_back(rel);
    }
    // v0.23.33-dev: .rela.eh_frame — one R_AARCH64_PREL32 per FDE, against the
    // function it describes. The field is a displacement from itself to the
    // function's entry, which is what a linker can add a section base to and a
    // static image can compute outright.
    if(hasEhFrame)for(const auto& p:ehFrame.patches){
        const std::string en=nameOf(p.symbol);
        auto it=symIndex.find(en);
        if(it==symIndex.end())throw Error("internal error: .eh_frame references unknown symbol '"+en+"'");
        Rela rel{};rel.offset=p.offset;rel.info=(uint64_t)it->second<<32|kRelPrel32;rel.addend=p.addend;relasEh.push_back(rel);
    }
    const std::string shstr(std::string("\0.text",6)+(hasData?std::string("\0.data",6):std::string())+(hasBss?std::string("\0.bss",5):std::string())+(hasRodata?std::string("\0.rodata",8):std::string())
        +(hasDebugLine?std::string("\0.debug_line",12)+std::string("\0.rela.debug_line",18):std::string())
        +(hasDebugInfo?std::string("\0.debug_abbrev",15)+std::string("\0.debug_info",13)+std::string("\0.rela.debug_info",18):std::string())
        +(hasEhFrame?std::string("\0.eh_frame",10)+std::string("\0.rela.eh_frame",16):std::string())
        +std::string("\0.rela.text",11)+std::string("\0.symtab",8)+std::string("\0.strtab",8)+std::string("\0.shstrtab",10)+std::string("\0",1));
    auto nameAt=[&](const char* want)->uint32_t{size_t i=0;while(i<shstr.size()){std::string cur=shstr.c_str()+i;if(cur==want)return (uint32_t)i;i+=cur.size()+1;}throw Error("internal ELF layout error: missing section name");};
    auto align8=[](uint64_t n){return (n+7u)&~uint64_t(7u);};
    const uint64_t textOff=align8(sizeof(Ehdr)),textSize=L.ins.size()*4;
    uint64_t dataAlign=4,bssAlign=4;
    for(const auto& g:globals){if(g.external)continue;const uint64_t a=std::max<uint64_t>(g.align<4?4:g.align,tySize(g.ty));if((tyIs64(g.ty)?g.wideInit==0:g.init==0)){if(a>bssAlign)bssAlign=a;}else{if(a>dataAlign)dataAlign=a;}}
    const uint64_t dataOff=hasData?alignUp(textOff+textSize,dataAlign>8?dataAlign:8):0;
    const uint64_t rodataOff=hasRodata?alignUp((hasData?dataOff+L.data.size():textOff+textSize),1):0;
    const uint64_t afterLast=hasRodata?rodataOff+L.rodata.size():(hasData?dataOff+L.data.size():textOff+textSize);
    const uint64_t debugLineOff=hasDebugLine?align8(afterLast):0,debugLineSize=debugLine.bytes.size();
    const uint64_t relaDebugLineOff=hasDebugLine?align8(debugLineOff+debugLineSize):0,relaDebugLineSize=relasDl.size()*sizeof(Rela);
    const uint64_t afterDebugLine=hasDebugLine?relaDebugLineOff+relaDebugLineSize:afterLast;
    const uint64_t debugAbbrevOff=hasDebugInfo?align8(afterDebugLine):0,debugAbbrevSize=debugInfo.abbrev.size();
    const uint64_t debugInfoOff=hasDebugInfo?align8(debugAbbrevOff+debugAbbrevSize):0,debugInfoSize=debugInfo.bytes.size();
    const uint64_t relaDebugInfoOff=hasDebugInfo?align8(debugInfoOff+debugInfoSize):0,relaDebugInfoSize=relasDi.size()*sizeof(Rela);
    const uint64_t afterDebugInfo=hasDebugInfo?relaDebugInfoOff+relaDebugInfoSize:afterDebugLine;
    const uint64_t ehFrameOff=hasEhFrame?align8(afterDebugInfo):0,ehFrameSize=ehFrame.bytes.size();
    const uint64_t relaEhFrameOff=hasEhFrame?align8(ehFrameOff+ehFrameSize):0,relaEhFrameSize=relasEh.size()*sizeof(Rela);
    const uint64_t relaOff=align8(hasEhFrame?relaEhFrameOff+relaEhFrameSize:afterDebugInfo),relaSize=relas.size()*sizeof(Rela);
    const uint64_t symOff=align8(relaOff+relaSize),symSize=syms.size()*sizeof(Sym);
    const uint64_t strOff=symOff+symSize,shstrOff=strOff+strtab.size(),shoff=align8(shstrOff+shstr.size());
    Ehdr h{};initIdent(h,1);h.shoff=shoff;h.shentsize=sizeof(Shdr);h.shnum=shnum;h.shstrndx=idxShstr;
    std::vector<Shdr> sh(shnum);
    sh[1].name=nameAt(".text");sh[1].type=1;sh[1].flags=0x6;sh[1].offset=textOff;sh[1].size=textSize;sh[1].addralign=4;
    if(hasData){sh[idxData].name=nameAt(".data");sh[idxData].type=1;sh[idxData].flags=0x3;sh[idxData].offset=dataOff;sh[idxData].size=L.data.size();sh[idxData].addralign=dataAlign;}
    if(hasBss){sh[idxBss].name=nameAt(".bss");sh[idxBss].type=8;sh[idxBss].flags=0x3;sh[idxBss].offset=hasRodata?rodataOff+L.rodata.size():(hasData?dataOff+L.data.size():textOff+textSize);sh[idxBss].size=L.bssSize;sh[idxBss].addralign=bssAlign;}
    if(hasRodata){sh[idxRodata].name=nameAt(".rodata");sh[idxRodata].type=1;sh[idxRodata].flags=0x2;sh[idxRodata].offset=rodataOff;sh[idxRodata].size=L.rodata.size();sh[idxRodata].addralign=1;}
    if(hasDebugLine){
        sh[idxDebugLine].name=nameAt(".debug_line");sh[idxDebugLine].type=1;sh[idxDebugLine].offset=debugLineOff;sh[idxDebugLine].size=debugLineSize;sh[idxDebugLine].addralign=1;
        Shdr& e0=sh[idxRelaDebugLine];e0.name=nameAt(".rela.debug_line");e0.type=4;e0.offset=relaDebugLineOff;e0.size=relaDebugLineSize;e0.link=idxSym;e0.info=idxDebugLine;e0.addralign=8;e0.entsize=sizeof(Rela);
    }
    if(hasDebugInfo){
        sh[idxDebugAbbrev].name=nameAt(".debug_abbrev");sh[idxDebugAbbrev].type=1;sh[idxDebugAbbrev].offset=debugAbbrevOff;sh[idxDebugAbbrev].size=debugAbbrevSize;sh[idxDebugAbbrev].addralign=1;
        sh[idxDebugInfo].name=nameAt(".debug_info");sh[idxDebugInfo].type=1;sh[idxDebugInfo].offset=debugInfoOff;sh[idxDebugInfo].size=debugInfoSize;sh[idxDebugInfo].addralign=1;
        Shdr& e=sh[idxRelaDebugInfo];e.name=nameAt(".rela.debug_info");e.type=4;e.offset=relaDebugInfoOff;e.size=relaDebugInfoSize;e.link=idxSym;e.info=idxDebugInfo;e.addralign=8;e.entsize=sizeof(Rela);
    }
    if(hasEhFrame){
        sh[idxEhFrame].name=nameAt(".eh_frame");sh[idxEhFrame].type=1;sh[idxEhFrame].flags=0x2;sh[idxEhFrame].offset=ehFrameOff;sh[idxEhFrame].size=ehFrameSize;sh[idxEhFrame].addralign=4;
        Shdr& e=sh[idxRelaEhFrame];e.name=nameAt(".rela.eh_frame");e.type=4;e.offset=relaEhFrameOff;e.size=relaEhFrameSize;e.link=idxSym;e.info=idxEhFrame;e.addralign=8;e.entsize=sizeof(Rela);
    }
    sh[idxRela].name=nameAt(".rela.text");sh[idxRela].type=4;sh[idxRela].offset=relaOff;sh[idxRela].size=relaSize;sh[idxRela].link=idxSym;sh[idxRela].info=idxText;sh[idxRela].addralign=8;sh[idxRela].entsize=sizeof(Rela);
    sh[idxSym].name=nameAt(".symtab");sh[idxSym].type=2;sh[idxSym].offset=symOff;sh[idxSym].size=symSize;sh[idxSym].link=idxStr;sh[idxSym].info=1;sh[idxSym].addralign=8;sh[idxSym].entsize=sizeof(Sym);
    sh[idxStr].name=nameAt(".strtab");sh[idxStr].type=3;sh[idxStr].offset=strOff;sh[idxStr].size=strtab.size();sh[idxStr].addralign=1;
    sh[idxShstr].name=nameAt(".shstrtab");sh[idxShstr].type=3;sh[idxShstr].offset=shstrOff;sh[idxShstr].size=shstr.size();sh[idxShstr].addralign=1;
    std::ofstream o(path,std::ios::binary);if(!o)throw Error("cannot create output: "+path);
    o.write((const char*)&h,sizeof h);auto pad=[&](uint64_t target){auto pos=(uint64_t)o.tellp();if(pos>target)throw Error("internal ELF layout error");std::vector<char> z((size_t)(target-pos),0);if(!z.empty())o.write(z.data(),z.size());};
    pad(textOff);auto bytes=instructionBytes(L.ins);o.write((const char*)bytes.data(),bytes.size());
    if(hasData){pad(dataOff);o.write((const char*)L.data.data(),L.data.size());}
    if(hasRodata){pad(rodataOff);o.write((const char*)L.rodata.data(),L.rodata.size());}
    if(hasDebugLine){pad(debugLineOff);o.write((const char*)debugLine.bytes.data(),debugLine.bytes.size());
        pad(relaDebugLineOff);if(!relasDl.empty())o.write((const char*)relasDl.data(),relaDebugLineSize);}
    if(hasDebugInfo){pad(debugAbbrevOff);o.write((const char*)debugInfo.abbrev.data(),debugAbbrevSize);
        pad(debugInfoOff);o.write((const char*)debugInfo.bytes.data(),debugInfoSize);
        pad(relaDebugInfoOff);if(!relasDi.empty())o.write((const char*)relasDi.data(),relaDebugInfoSize);}
    if(hasEhFrame){pad(ehFrameOff);o.write((const char*)ehFrame.bytes.data(),ehFrameSize);
        pad(relaEhFrameOff);if(!relasEh.empty())o.write((const char*)relasEh.data(),relaEhFrameSize);}
    pad(relaOff);if(!relas.empty())o.write((const char*)relas.data(),relaSize);pad(symOff);o.write((const char*)syms.data(),symSize);o.write(strtab.data(),strtab.size());o.write(shstr.data(),shstr.size());pad(shoff);o.write((const char*)sh.data(),sh.size()*sizeof(Shdr));if(!o)throw Error("failed writing relocatable ELF object");
}
uint64_t checkedEnd(uint64_t off,uint64_t size,uint64_t total,const char* what){
    if(off>total||size>total-off) throw Error(std::string("malformed object: ")+what+" is out of bounds");
    return off+size;
}
std::string sectionName(const std::vector<uint8_t>& file,const Shdr& shstr,uint32_t offset){
    checkedEnd(shstr.offset,shstr.size,file.size(),"section-name table");
    if(offset>=shstr.size)throw Error("malformed object: section name offset is out of bounds");
    size_t begin=(size_t)(shstr.offset+offset),end=begin;
    while(end<shstr.offset+shstr.size&&file[end]!=0)++end;
    if(end>=shstr.offset+shstr.size)throw Error("malformed object: unterminated section name");
    return std::string((const char*)&file[begin],end-begin);
}
std::string symbolName(const std::vector<uint8_t>& file,const Shdr& strtab,uint32_t offset){
    checkedEnd(strtab.offset,strtab.size,file.size(),"symbol string table");
    if(offset>=strtab.size)throw Error("malformed object: symbol name offset is out of bounds");
    size_t begin=(size_t)(strtab.offset+offset),end=begin;
    while(end<strtab.offset+strtab.size&&file[end]!=0)++end;
    if(end>=strtab.offset+strtab.size)throw Error("malformed object: unterminated symbol name");
    return std::string((const char*)&file[begin],end-begin);
}
struct ParsedSymbol { std::string name; uint64_t value=0,size=0; uint8_t info=0; uint16_t shndx=0; };
struct ParsedReloc { uint64_t offset=0; std::string symbol; uint32_t type=0; int64_t addend=0; };
struct ParsedObject {
    std::vector<uint8_t> text; std::vector<uint8_t> data; std::vector<uint8_t> rodata; uint64_t bssSize=0;
    std::vector<ParsedSymbol> symbols; std::vector<ParsedReloc> relocs;
    // -g: the object's DWARF line program and the offsets in it that hold an
    // address, which the linker rewrites to the final text virtual address.
    std::vector<uint8_t> debugLine; std::vector<uint64_t> debugLinePatches;
    // v0.23.32-dev: the object's .debug_info, the abbreviation table it is read
    // against, and the addresses in it — each one naming the symbol it means,
    // because unlike a line table an address here is not always in .text.
    std::vector<uint8_t> debugInfo,debugAbbrev;
    std::vector<DebugInfoBlob::Patch> debugInfoPatches;
    // v0.23.33-dev: the object's unwind table, taken apart rather than copied —
    // one CIE, and one FDE per function reduced to what the link has to know:
    // which symbol it describes, how big it is, and the CFI program that says
    // where the frame is. The link re-emits each FDE at its own address, which
    // is the only thing about it that a link changes.
    std::vector<uint8_t> ehFrameCie;
    struct EhFrameFde { std::string symbol; int64_t addend=0; uint64_t range=0; std::vector<uint8_t> cfi; };
    std::vector<EhFrameFde> ehFrameFdes;
    uint64_t dataAlign=4,bssAlign=4,rodataAlign=1;
    bool hasStart=false; uint64_t entryOffset=0;
    int textIndex=-1,dataIndex=-1,bssIndex=-1,rodataIndex=-1,debugLineIndex=-1,relaDebugLineIndex=-1,
        debugAbbrevIndex=-1,debugInfoIndex=-1,relaDebugInfoIndex=-1,
        // v0.23.33-dev: .eh_frame is SHF_ALLOC — it has to be, because an
        // unwinder reads it out of the running image — so it needs a branch
        // here or the "unsupported allocated section" guard below rejects it.
        ehFrameIndex=-1,relaEhFrameIndex=-1;
};
ParsedObject parseObject(const std::string& input){
    auto fileText=readFile(input);std::vector<uint8_t> file(fileText.begin(),fileText.end());
    if(file.size()<sizeof(Ehdr))throw Error(input+": input is too small to be an ELF header");
    Ehdr h{};std::memcpy(&h,file.data(),sizeof h);
    if(std::memcmp(h.ident,"\x7f""ELF",4)!=0||h.ident[4]!=2||h.ident[5]!=1||h.ident[6]!=1)throw Error(input+": input must be ELF64 little-endian version 1");
    if(h.type!=1)throw Error(input+": input must be an ET_REL relocatable object");
    if(h.machine!=183)throw Error(input+": input architecture must be AArch64");
    if(h.ehsize!=sizeof(Ehdr)||h.shentsize!=sizeof(Shdr)||h.shnum==0)throw Error(input+": unsupported or malformed ELF section-header layout");
    if(h.shstrndx>=h.shnum)throw Error(input+": malformed object: invalid section-name table index");
    uint64_t shBytes=uint64_t(h.shnum)*sizeof(Shdr);checkedEnd(h.shoff,shBytes,file.size(),"section-header table");
    std::vector<Shdr> sections(h.shnum);std::memcpy(sections.data(),file.data()+h.shoff,(size_t)shBytes);
    const Shdr& names=sections[h.shstrndx];if(names.type!=3)throw Error(input+": section-name table must be a string table");
    ParsedObject result;
    int symIndex=-1,strIndex=-1,relaIndex=-1;
    for(size_t i=0;i<sections.size();++i){const auto& sh=sections[i];if(sh.type!=8)checkedEnd(sh.offset,sh.size,file.size(),"section data");std::string n=sectionName(file,names,sh.name);
        if(n==".text"){if(result.textIndex>=0)throw Error(input+": duplicate .text section");result.textIndex=(int)i;}
        else if(n==".data"){if(result.dataIndex>=0)throw Error(input+": duplicate .data section");result.dataIndex=(int)i;}
        else if(n==".bss"){if(result.bssIndex>=0)throw Error(input+": duplicate .bss section");result.bssIndex=(int)i;}
        else if(n==".rodata"){if(result.rodataIndex>=0)throw Error(input+": duplicate .rodata section");result.rodataIndex=(int)i;}
        else if(n==".symtab"){if(symIndex>=0)throw Error(input+": duplicate .symtab section");symIndex=(int)i;}
        else if(n==".strtab"){if(strIndex>=0)throw Error(input+": duplicate .strtab section");strIndex=(int)i;}
        else if(n==".rela.text"){if(relaIndex>=0)throw Error(input+": duplicate .rela.text section");relaIndex=(int)i;}
        else if(n==".debug_line"){if(result.debugLineIndex>=0)throw Error(input+": duplicate .debug_line section");result.debugLineIndex=(int)i;}
        else if(n==".rela.debug_line"){if(result.relaDebugLineIndex>=0)throw Error(input+": duplicate .rela.debug_line section");result.relaDebugLineIndex=(int)i;}
        else if(n==".debug_abbrev"){if(result.debugAbbrevIndex>=0)throw Error(input+": duplicate .debug_abbrev section");result.debugAbbrevIndex=(int)i;}
        else if(n==".debug_info"){if(result.debugInfoIndex>=0)throw Error(input+": duplicate .debug_info section");result.debugInfoIndex=(int)i;}
        else if(n==".rela.debug_info"){if(result.relaDebugInfoIndex>=0)throw Error(input+": duplicate .rela.debug_info section");result.relaDebugInfoIndex=(int)i;}
        else if(n==".eh_frame"){if(result.ehFrameIndex>=0)throw Error(input+": duplicate .eh_frame section");result.ehFrameIndex=(int)i;}
        else if(n==".rela.eh_frame"){if(result.relaEhFrameIndex>=0)throw Error(input+": duplicate .rela.eh_frame section");result.relaEhFrameIndex=(int)i;}
        else if(sh.flags&0x2u)throw Error(input+": unsupported allocated section: "+n);
    }
    if(result.textIndex<0||symIndex<0||strIndex<0)throw Error(input+": object must contain .text, .symtab, and .strtab sections");
    const Shdr& text=sections[result.textIndex];const Shdr& sym=sections[symIndex];const Shdr& str=sections[strIndex];
    if(text.type!=1||(text.flags&0x6)!=0x6||text.addralign<4||text.size==0||text.size%4)throw Error(input+": unsupported .text section attributes");
    if(sym.type!=2||sym.entsize!=sizeof(Sym)||sym.size%sizeof(Sym)||sym.link!=(uint32_t)strIndex||sym.info>sym.size/sizeof(Sym))throw Error(input+": malformed or unsupported symbol table");
    if(str.type!=3)throw Error(input+": .strtab must be a string table");
    if(result.dataIndex>=0){const Shdr& d=sections[result.dataIndex];if(d.type!=1||(d.flags&0x3)!=0x3||d.addralign<4||d.size%4||d.size==0)throw Error(input+": unsupported .data section attributes");result.dataAlign=d.addralign;result.data.assign(file.begin()+d.offset,file.begin()+d.offset+d.size);}
    if(result.rodataIndex>=0){const Shdr& r=sections[result.rodataIndex];if(r.type!=1||(r.flags&0x2)==0||(r.flags&0x1)!=0||r.size==0)throw Error(input+": unsupported .rodata section attributes");result.rodataAlign=r.addralign<1?1:r.addralign;result.rodata.assign(file.begin()+r.offset,file.begin()+r.offset+r.size);}
    if(result.bssIndex>=0){const Shdr& b=sections[result.bssIndex];if(b.type!=8||(b.flags&0x3)!=0x3||b.addralign<4||b.size%4||b.size==0)throw Error(input+": unsupported .bss section attributes");result.bssAlign=b.addralign;result.bssSize=b.size;}
    checkedEnd(text.offset,text.size,file.size(),".text data");result.text.assign(file.begin()+text.offset,file.begin()+text.offset+text.size);
    std::vector<std::string> namesByIndex;
    for(uint64_t off=0;off<sym.size;off+=sizeof(Sym)){Sym s{};std::memcpy(&s,file.data()+sym.offset+off,sizeof s);std::string name=symbolName(file,str,s.name);namesByIndex.push_back(name);ParsedSymbol ps{name,s.value,s.size,s.info,s.shndx};result.symbols.push_back(ps);
        if((s.info>>4)==1&&!name.empty()&&s.shndx!=0){
            uint16_t shndx=s.shndx;
            if(shndx==(uint16_t)result.textIndex){
                if((s.info&0x0f)!=2)throw Error(input+": global symbol in .text must be a function: "+name);
                if(s.value>=text.size||s.value%4||s.size>text.size-s.value)throw Error(input+": global symbol must be defined and in bounds in .text: "+name);
                if(name=="_start"){if(result.hasStart)throw Error(input+": duplicate _start symbol");result.hasStart=true;result.entryOffset=s.value;}
            } else if(result.dataIndex>=0&&shndx==(uint16_t)result.dataIndex){
                if((s.info&0x0f)!=1)throw Error(input+": global symbol in .data must be an object: "+name);
                if(s.value%4||s.size==0||s.size%4||s.value>result.data.size()||s.size>result.data.size()-s.value)throw Error(input+": global object must be defined and in bounds in .data: "+name);
            } else if(result.rodataIndex>=0&&shndx==(uint16_t)result.rodataIndex){
                if((s.info&0x0f)!=1)throw Error(input+": global symbol in .rodata must be an object: "+name);
                if(s.size==0||s.value>result.rodata.size()||s.size>result.rodata.size()-s.value)throw Error(input+": global object must be defined and in bounds in .rodata: "+name);
            } else if(result.bssIndex>=0&&shndx==(uint16_t)result.bssIndex){
                if((s.info&0x0f)!=1)throw Error(input+": global symbol in .bss must be an object: "+name);
                if(s.value%4||s.size==0||s.size%4||s.value>result.bssSize||s.size>result.bssSize-s.value)throw Error(input+": global object must be defined and in bounds in .bss: "+name);
            } else throw Error(input+": global symbol in an unsupported section: "+name);
        }
    }
    if(relaIndex>=0){const Shdr& rela=sections[relaIndex];if(rela.type!=4||rela.entsize!=sizeof(Rela)||rela.size%sizeof(Rela)||rela.link!=(uint32_t)symIndex||rela.info!=(uint32_t)result.textIndex)throw Error(input+": malformed .rela.text section");
        for(uint64_t off=0;off<rela.size;off+=sizeof(Rela)){Rela r{};std::memcpy(&r,file.data()+rela.offset+off,sizeof r);uint32_t si=(uint32_t)(r.info>>32),type=(uint32_t)r.info;if(type!=283&&type!=275&&type!=277)throw Error(input+": unsupported AArch64 relocation type "+std::to_string(type));if(si>=namesByIndex.size()||namesByIndex[si].empty())throw Error(input+": relocation references an invalid symbol");        if(r.offset+4>result.text.size()||r.offset%4)throw Error(input+": relocation offset is out of bounds or unaligned");result.relocs.push_back({r.offset,namesByIndex[si],type,r.addend});}
    }
    if(result.debugLineIndex>=0){
        const Shdr& dl=sections[result.debugLineIndex];
        if(dl.type!=1||(dl.flags&0x2u))throw Error(input+": unsupported .debug_line section attributes");
        checkedEnd(dl.offset,dl.size,file.size(),".debug_line data");
        result.debugLine.assign(file.begin()+dl.offset,file.begin()+dl.offset+dl.size);
    }
    if(result.relaDebugLineIndex>=0){
        if(result.debugLineIndex<0)throw Error(input+": .rela.debug_line without a .debug_line section");
        const Shdr& rela=sections[result.relaDebugLineIndex];
        if(rela.type!=4||rela.entsize!=sizeof(Rela)||rela.size%sizeof(Rela)||rela.link!=(uint32_t)symIndex||rela.info!=(uint32_t)result.debugLineIndex)throw Error(input+": malformed .rela.debug_line section");
        for(uint64_t off=0;off<rela.size;off+=sizeof(Rela)){Rela r{};std::memcpy(&r,file.data()+rela.offset+off,sizeof r);uint32_t si=(uint32_t)(r.info>>32),type=(uint32_t)r.info;
            if(type!=kRelAbs64)throw Error(input+": unsupported relocation type "+std::to_string(type)+" in .rela.debug_line");
            if(si>=namesByIndex.size()||namesByIndex[si].empty())throw Error(input+": relocation references an invalid symbol");
            // An address field sits wherever the variable-length header put it,
            // so there is no alignment to insist on — only bounds.
            if(r.offset+8>result.debugLine.size())throw Error(input+": .debug_line relocation offset is out of bounds");
            result.debugLinePatches.push_back(r.offset);}
        if(result.debugLinePatches.empty())throw Error(input+": malformed .debug_line: no relocatable address");
    }
    // v0.23.32-dev: .debug_info, read back with the symbol each address names.
    // The abbreviation table is shared by every unit, so the link keeps one
    // copy: all of them are byte-identical by construction.
    if(result.debugInfoIndex>=0){
        const Shdr& di=sections[result.debugInfoIndex];
        if(di.type!=1||(di.flags&0x2u))throw Error(input+": unsupported .debug_info section attributes");
        checkedEnd(di.offset,di.size,file.size(),".debug_info data");
        result.debugInfo.assign(file.begin()+di.offset,file.begin()+di.offset+di.size);
    }
    if(result.debugAbbrevIndex>=0){
        if(result.debugInfoIndex<0)throw Error(input+": .debug_abbrev without a .debug_info section");
        const Shdr& ab=sections[result.debugAbbrevIndex];
        if(ab.type!=1||(ab.flags&0x2u))throw Error(input+": unsupported .debug_abbrev section attributes");
        checkedEnd(ab.offset,ab.size,file.size(),".debug_abbrev data");
        result.debugAbbrev.assign(file.begin()+ab.offset,file.begin()+ab.offset+ab.size);
    }
    if(result.relaDebugInfoIndex>=0){
        if(result.debugInfoIndex<0)throw Error(input+": .rela.debug_info without a .debug_info section");
        const Shdr& rela=sections[result.relaDebugInfoIndex];
        if(rela.type!=4||rela.entsize!=sizeof(Rela)||rela.size%sizeof(Rela)||rela.link!=(uint32_t)symIndex||rela.info!=(uint32_t)result.debugInfoIndex)throw Error(input+": malformed .rela.debug_info section");
        for(uint64_t off=0;off<rela.size;off+=sizeof(Rela)){Rela r{};std::memcpy(&r,file.data()+rela.offset+off,sizeof r);uint32_t si=(uint32_t)(r.info>>32),type=(uint32_t)r.info;
            if(type!=kRelAbs64)throw Error(input+": unsupported relocation type "+std::to_string(type)+" in .rela.debug_info");
            if(si>=namesByIndex.size()||namesByIndex[si].empty())throw Error(input+": relocation references an invalid symbol");
            if(r.offset+8>result.debugInfo.size())throw Error(input+": .debug_info relocation offset is out of bounds");
            result.debugInfoPatches.push_back({r.offset,namesByIndex[si],r.addend});}
    }
    // v0.23.33-dev: .eh_frame, read back as a CIE plus one FDE per function.
    // The FDE's own address field is dropped — the link recomputes it — and
    // what replaces it is the relocation that used to fill it, matched by the
    // offset it pointed at.
    std::vector<uint8_t> ehFrameBytes;
    if(result.ehFrameIndex>=0){
        const Shdr& ef=sections[result.ehFrameIndex];
        if(ef.type!=1||(ef.flags&0x2u)==0||(ef.flags&0x1u)!=0)throw Error(input+": unsupported .eh_frame section attributes");
        checkedEnd(ef.offset,ef.size,file.size(),".eh_frame data");
        ehFrameBytes.assign(file.begin()+ef.offset,file.begin()+ef.offset+ef.size);
    }
    std::map<uint64_t,std::pair<std::string,int64_t>> ehRelocs;
    if(result.relaEhFrameIndex>=0){
        if(result.ehFrameIndex<0)throw Error(input+": .rela.eh_frame without an .eh_frame section");
        const Shdr& rela=sections[result.relaEhFrameIndex];
        if(rela.type!=4||rela.entsize!=sizeof(Rela)||rela.size%sizeof(Rela)||rela.link!=(uint32_t)symIndex||rela.info!=(uint32_t)result.ehFrameIndex)throw Error(input+": malformed .rela.eh_frame section");
        for(uint64_t off=0;off<rela.size;off+=sizeof(Rela)){Rela r{};std::memcpy(&r,file.data()+rela.offset+off,sizeof r);uint32_t si=(uint32_t)(r.info>>32),type=(uint32_t)r.info;
            if(type!=kRelPrel32)throw Error(input+": unsupported relocation type "+std::to_string(type)+" in .rela.eh_frame");
            if(si>=namesByIndex.size()||namesByIndex[si].empty())throw Error(input+": relocation references an invalid symbol");
            if(r.offset+4>ehFrameBytes.size())throw Error(input+": .eh_frame relocation offset is out of bounds");
            ehRelocs[r.offset]={namesByIndex[si],r.addend};}
    }
    if(result.ehFrameIndex>=0){
        uint64_t pos=0;
        while(pos+4<=ehFrameBytes.size()){
            uint32_t len=0;for(int i=0;i<4;++i)len|=uint32_t(ehFrameBytes[(size_t)pos+(size_t)i])<<(8*i);
            if(len==0)break;                                  // a zero-length entry ends the table
            if(len<12||len>ehFrameBytes.size()-pos-4)throw Error(input+": malformed .eh_frame: an entry overruns the section");
            uint32_t id=0;for(int i=0;i<4;++i)id|=uint32_t(ehFrameBytes[(size_t)pos+4+(size_t)i])<<(8*i);
            if(id==0){
                if(!result.ehFrameCie.empty())throw Error(input+": malformed .eh_frame: more than one CIE");
                result.ehFrameCie.assign(ehFrameBytes.begin()+pos,ehFrameBytes.begin()+pos+4+len);
            } else {
                ParsedObject::EhFrameFde f;
                for(int i=0;i<4;++i)f.range|=uint64_t(ehFrameBytes[(size_t)pos+12+(size_t)i])<<(8*i);
                f.cfi.assign(ehFrameBytes.begin()+pos+16,ehFrameBytes.begin()+pos+4+len);
                auto it=ehRelocs.find(pos+8);
                if(it==ehRelocs.end())throw Error(input+": malformed .eh_frame: an FDE has no relocation for its address");
                f.symbol=it->second.first;f.addend=it->second.second;
                result.ehFrameFdes.push_back(std::move(f));
            }
            pos+=4+(uint64_t)len;
        }
        if(result.ehFrameCie.empty())throw Error(input+": malformed .eh_frame: no CIE");
    }
    return result;
}
// Relocation bookkeeping shared by the executable linker and the shared-object writer.
struct LinkPending { uint64_t patch; std::string symbol; int64_t addend; uint32_t type; size_t inputIndex=0; };

// Applies R_AARCH64_CALL26 (283), R_AARCH64_ADR_PREL_PG_HI21 (275) and
// R_AARCH64_ADD_ABS_LO12_NC (277) relocations to an in-memory .text image.
// symbolKind: 0 = function in .text, 1 = object in .data, 2 = object in .bss,
//             3 = shared-object .got address slot. textVaddr is the link-time virtual address of text[0].
//
// `funcAddrDirect` (v0.23.24-dev): a static image may address a function
// directly — its text address is known at link time, and ADRP/ADD are
// PC-relative, so even a static PIE carries the right address wherever it
// loads. A shared object may not: its text cannot hold a load-time
// relocation, which is why the shared writers reroute every function
// address through a GOT slot before this point — there, an ADRP against a
// raw function symbol is a bug, and the check below catches it.
void resolveRelocations(std::vector<uint8_t>& text,const std::vector<LinkPending>& pending,
                        const std::map<std::string,uint64_t>& symbolVaddr,const std::map<std::string,int>& symbolKind,
                        uint64_t textVaddr,bool funcAddrDirect=false){
    for(const auto& r:pending){auto it=symbolVaddr.find(r.symbol);
        if(it==symbolVaddr.end()){
            if(r.type==283)throw Error("undefined function symbol '"+r.symbol+"'");
            throw Error("undefined global variable symbol '"+r.symbol+"'");
        }
        const int kind=symbolKind.at(r.symbol);
        uint64_t target=it->second+uint64_t(r.addend);
        uint32_t ins=0;for(int i=0;i<4;++i)ins|=uint32_t(text[(size_t)r.patch+i])<<(i*8);
        if(r.type==283){
            if(kind!=0)throw Error("CALL26 relocation references a non-function symbol '"+r.symbol+"'");
            int64_t delta=(int64_t)target-(int64_t)(textVaddr+r.patch);
            if((delta&3)!=0||delta<-(int64_t(1)<<27)||delta>=(int64_t(1)<<27))throw Error("AArch64 CALL26 relocation out of range for '"+r.symbol+"'");
            if((ins&0xfc000000u)!=0x94000000u)throw Error("CALL26 relocation does not point to a BL instruction");
            ins=(ins&0xfc000000u)|(uint32_t(delta>>2)&0x03ffffffu);
        } else if(r.type==275){
            if(kind==0&&!funcAddrDirect)throw Error("global address relocation references a function symbol '"+r.symbol+"'");
            if((ins&0x9f000000u)!=0x90000000u)throw Error("ADRP relocation does not point to an ADRP instruction");
            const uint64_t p=textVaddr+r.patch;
            int64_t pageDelta=(int64_t)((target&~uint64_t(0xfff))-(p&~uint64_t(0xfff)))>>12;
            if(pageDelta<-(int64_t(1)<<20)||pageDelta>=(int64_t(1)<<20))throw Error("AArch64 ADRP relocation out of range for '"+r.symbol+"'");
            uint32_t immlo=uint32_t(pageDelta)&0x3u,immhi=(uint32_t(pageDelta)>>2)&0x7ffffu;
            ins=(ins&~((0x3u<<29)|(0x7ffffu<<5)))|(immlo<<29)|(immhi<<5);
        } else {
            if(kind==0&&!funcAddrDirect)throw Error("global address relocation references a function symbol '"+r.symbol+"'");
            if((ins&0xff800000u)!=0x91000000u)throw Error("low-12 relocation does not point to an ADD immediate instruction");
            ins=(ins&~(0xfffu<<10))|(uint32_t(target&0xfffu)<<10);
        }
        for(int i=0;i<4;++i)text[(size_t)r.patch+i]=uint8_t(ins>>(i*8));
    }
}

#pragma pack(push,1)
struct Elf64Dyn { int64_t tag; uint64_t val; };
#pragma pack(pop)
struct SoExport { std::string name; uint64_t offset=0, size=0; };

// Emit an ELF64 AArch64 shared object (ET_DYN) that Linux/glibc can dlopen.
//
// Link-time virtual addresses equal file offsets (base 0); the dynamic loader adds the load bias
// to every virtual address, so no instruction in .text depends on where the object lands.
//   segment 0 (R+X, offset 0, vaddr 0): ELF header, program headers, .text, .dynsym, .dynstr,
//                                       .hash, .rela.dyn
//   segment 1 (R+W): .data, .got, .dynamic, .bss
// .got holds one 8-byte address slot per defined global. Shared-object code reaches a global
// through its slot, and the slot contents are fixed up at load time by R_AARCH64_RELATIVE
// entries in .rela.dyn (addend = the global's link-time address), so the relocation is load
// bearing: a loader that skipped it would hand the code a wrong address.
void writeSharedObject(const std::string& path,std::vector<uint8_t>& text,
                       const std::vector<LinkPending>& pending,const std::vector<SoExport>& exports,
                       const std::vector<uint8_t>& data,uint64_t bssSize,
                       const std::vector<ObjectLayout::GlobalDef>& globals,int64_t initOffset=-1,
                       const DebugLineBlob& debugLine=DebugLineBlob{},
                       const DebugInfoBlob& debugInfo=DebugInfoBlob{},
                       const std::vector<uint8_t>& ehFrame={},
                       const std::vector<EhFrameBlob::Patch>& ehFramePatches={},
                       const std::vector<std::pair<std::string,uint64_t>>& ehFrameFdes={}){
    enum { S_NULL=0,S_TEXT=1,S_DYNSYM=2,S_DYNSTR=3,S_HASH=4,S_RELA=5,S_DATA=6,S_GOT=7,S_DYNAMIC=8,S_BSS=9,S_INIT_ARRAY=10,S_SYMTAB=11,S_STRTAB=12,S_SHSTR=13,S_NUM=14 };
    const bool hasInit=initOffset>=0;
    const bool hasDebugLine=!debugLine.bytes.empty();
    // v0.23.32-dev: the same two sections the gnu-hash path emits, laid out the
    // same way — after everything else, so no existing index or offset moves.
    const bool hasDebugInfo=!debugInfo.bytes.empty();
    const bool hasEhFrame=!ehFrame.empty();
    if(text.empty())throw Error("cannot write a shared object without code");
    if(exports.empty())throw Error("shared object must export at least one function");
    const size_t nglobals=globals.size();
    // .dynstr / .dynsym: index 0 is the reserved null symbol, then one GLOBAL FUNC per export.
    std::string dynstr(1,'\0');
    std::vector<uint32_t> nameOff(exports.size());
    for(size_t i=0;i<exports.size();++i){nameOff[i]=(uint32_t)dynstr.size();dynstr+=exports[i].name;dynstr.push_back('\0');}
    std::vector<Sym> dynsym(1+exports.size());
    for(size_t i=0;i<exports.size();++i){Sym& s=dynsym[i+1];s.name=nameOff[i];s.info=0x12;s.other=0;s.shndx=S_TEXT;s.value=exports[i].offset;s.size=exports[i].size;}
    // .hash: DT_HASH / SysV hash table so the loader can resolve the exported names.
    const uint32_t nchain=(uint32_t)dynsym.size();
    const uint32_t nbucket=nchain<3?3:nchain;
    std::vector<uint32_t> hash(2+size_t(nbucket)+size_t(nchain),0u);
    hash[0]=nbucket;hash[1]=nchain;
    uint32_t* buckets=hash.data()+2;uint32_t* chains=buckets+nbucket;
    for(uint32_t i=1;i<nchain;++i){const char* n=dynstr.c_str()+dynsym[i].name;unsigned long hsh=0,g;
        for(const char* q=n;*q;++q){hsh=(hsh<<4)+((unsigned char)*q);if((g=hsh&0xf0000000ul))hsh^=g>>24;hsh&=~g;}
        const uint32_t b=uint32_t(hsh%nbucket);chains[i]=buckets[b];buckets[b]=i;}
    // Section / segment layout. Only the two PT_LOAD boundaries are page aligned.
    const uint64_t textOff=0x1000,textEnd=textOff+text.size();
    const uint64_t dynsymOff=alignUp(textEnd,8),dynsymSize=uint64_t(dynsym.size())*sizeof(Sym);
    const uint64_t dynstrOff=dynsymOff+dynsymSize,dynstrSize=dynstr.size();
    const uint64_t hashOff=alignUp(dynstrOff+dynstrSize,4),hashSize=uint64_t(hash.size())*4;
    const uint64_t relaOff=alignUp(hashOff+hashSize,8),relaSize=uint64_t(nglobals+(hasInit?1u:0u))*sizeof(Rela);
    const uint64_t seg0End=relaOff+relaSize;
    const uint64_t dataVaddr=alignUp(seg0End,0x1000),dataSize=data.size();
    // Keep user .data writable, but put init_array/GOT/.dynamic on dedicated pages so
    // PT_GNU_RELRO can protect them without accidentally making ordinary globals read-only.
    const uint64_t relroVaddr=alignUp(dataVaddr+dataSize,0x1000);
    const uint64_t initArrVaddr=relroVaddr,initArrSize=hasInit?8:0;
    const uint64_t gotVaddr=initArrVaddr+initArrSize,gotSize=uint64_t(nglobals)*8;
    const uint32_t kDynEntries=10u+(hasInit?2u:0u); // nine tags (eleven with DT_INIT_ARRAY) plus DT_NULL
    const uint64_t dynOff=alignUp(gotVaddr+gotSize,8),dynSize=uint64_t(kDynEntries)*sizeof(Elf64Dyn);
    const uint64_t seg1End=dynOff+dynSize;
    const uint64_t relroEnd=alignUp(seg1End,0x1000);
    const uint64_t bssVaddr=relroEnd;
    const uint64_t textVaddr=textOff;
    // .dynsym values are virtual addresses, not .text-relative offsets.
    for(size_t i=0;i<exports.size();++i)dynsym[i+1].value=textVaddr+exports[i].offset;
    // .got slots and their R_AARCH64_RELATIVE relocations (addend = the global's link-time address).
    std::vector<uint8_t> got((size_t)gotSize,0);
    std::vector<Rela> relas(nglobals+(hasInit?1u:0u));
    std::map<std::string,uint64_t> symbolVaddr;std::map<std::string,int> symbolKind;
    for(size_t i=0;i<nglobals;++i){
        const uint64_t v=globals[i].kind==1?dataVaddr+globals[i].offset:bssVaddr+globals[i].offset;
        for(int k=0;k<8;++k)got[i*8+k]=uint8_t(v>>(k*8));
        relas[i].offset=gotVaddr+uint64_t(i)*8;relas[i].info=1027;relas[i].addend=(int64_t)v;
        const std::string slot=gatSymbol(globals[i].name);
        symbolVaddr[slot]=gotVaddr+uint64_t(i)*8;symbolKind[slot]=3;
    }
    if(hasInit){Rela& r=relas[nglobals];r.offset=initArrVaddr;r.info=1027;r.addend=(int64_t)(textVaddr+uint64_t(initOffset));}
    for(const auto& e:exports){symbolVaddr[e.name]=textVaddr+e.offset;symbolKind[e.name]=0;}
    resolveRelocations(text,pending,symbolVaddr,symbolKind,textVaddr);
    // .dynamic
    std::vector<Elf64Dyn> dyn;
    dyn.push_back({4,(uint64_t)hashOff});              // DT_HASH
    dyn.push_back({5,(uint64_t)dynstrOff});            // DT_STRTAB
    dyn.push_back({6,(uint64_t)dynsymOff});            // DT_SYMTAB
    dyn.push_back({10,(uint64_t)dynstrSize});          // DT_STRSZ
    dyn.push_back({11,sizeof(Sym)});                   // DT_SYMENT
    dyn.push_back({7,(uint64_t)relaOff});              // DT_RELA
    dyn.push_back({8,(uint64_t)relaSize});             // DT_RELASZ
    dyn.push_back({9,sizeof(Rela)});                   // DT_RELAENT
    if(hasInit){dyn.push_back({25,(uint64_t)initArrVaddr});dyn.push_back({27,(uint64_t)initArrSize});} // DT_INIT_ARRAY / DT_INIT_ARRAYSZ
    dyn.push_back({1879048185,(uint64_t)(nglobals+(hasInit?1u:0u))});    // DT_RELACOUNT
    dyn.push_back({0,0});                              // DT_NULL
    // Section headers (the string table and the header table itself are not loaded).
    std::string shstr(1,'\0');
    auto addShName=[&](const char* n){uint32_t o=(uint32_t)shstr.size();shstr+=n;shstr.push_back('\0');return o;};
    const uint32_t nText=addShName(".text"),nDynsym=addShName(".dynsym"),nDynstr=addShName(".dynstr"),nHash=addShName(".hash"),
                   nRela=addShName(".rela.dyn"),nData=addShName(".data"),nGot=addShName(".got"),nDynamic=addShName(".dynamic"),
                   nBss=addShName(".bss");
    const uint32_t nInitArray=hasInit?addShName(".init_array"):0;
    const uint32_t nSymtab=addShName(".symtab"),nStrtab=addShName(".strtab"),nShstr=addShName(".shstrtab");
    const uint32_t nDebugLine=hasDebugLine?addShName(".debug_line"):0;
    const uint32_t nDebugAbbrev=hasDebugInfo?addShName(".debug_abbrev"):0;
    const uint32_t nDebugInfo=hasDebugInfo?addShName(".debug_info"):0;
    const uint32_t nEhFrame=hasEhFrame?addShName(".eh_frame"):0;
    const uint32_t nEhFrameHdr=hasEhFrame?addShName(".eh_frame_hdr"):0;
    const int kSymIdx=hasInit?S_SYMTAB:(S_SYMTAB-1);
    const int kStrIdx=hasInit?S_STRTAB:(S_STRTAB-1);
    const int kShstrIdx=hasInit?S_SHSTR:(S_SHSTR-1);
    const int kShnum=hasInit?S_NUM:(S_NUM-1);
    // .debug_line goes after every other section, including the string tables,
    // so that no existing index or offset moves: only shnum grows. v0.23.32-dev
    // puts .debug_abbrev and .debug_info after it, for the same reason.
    const int kDlIdx=hasDebugLine?kShnum:0;
    const int kDaIdx=kShnum+(hasDebugLine?1:0),kDiIdx=kDaIdx+1;
    // v0.23.33-dev: .eh_frame and .eh_frame_hdr go last, and they are the first
    // sections here that a running program reads — so unlike the debug sections
    // they ride in a PT_LOAD of their own.
    const int kEfIdx=kDiIdx+1,kEfhIdx=kDiIdx+2;
    const int kShnumAll=kShnum+(hasDebugLine?1:0)+(hasDebugInfo?2:0)+(hasEhFrame?2:0);
    // Source-level symbols: every exported function and every defined global/array. Synthetic
    // internal routines (__aster_init*) are already in .dynsym but are not source-level names.
    std::vector<OutSym> outSymbols;outSymbols.reserve(exports.size()+nglobals);
    for(const auto& e:exports){if(e.name.compare(0,8,"__aster_")==0)continue;outSymbols.push_back({e.name,0,e.offset,e.size});}
    for(size_t i=0;i<nglobals;++i)outSymbols.push_back({globals[i].name,globals[i].kind==1?1:2,globals[i].offset,globals[i].size});
    const SymTable st=buildSymbolTable(outSymbols,textVaddr,dataVaddr,bssVaddr,S_TEXT,S_DATA,S_BSS);
    // .symtab/.strtab and the section-header table are appended past the end of the loaded
    // segments, so no PT_LOAD boundary, no tag and no loaded byte changes.
    const uint64_t symOff=alignUp(relroEnd,8),symSize=uint64_t(st.syms.size())*sizeof(Sym);
    const uint64_t strOff=symOff+symSize,shstrOff=strOff+st.strtab.size();
    const uint64_t shoff=alignUp(shstrOff+shstr.size(),8);
    // The line program is laid out past the section-header table, so nothing
    // that is already placed has to move.
    const uint64_t afterShdr=alignUp(shoff+uint64_t(kShnumAll)*sizeof(Shdr),8);
    const uint64_t debugLineOff=hasDebugLine?afterShdr:0;
    std::vector<uint8_t> debugLineBytes=debugLine.bytes;
    for(uint64_t site:debugLine.patchSites)dbgPatchAddress(debugLineBytes,site,textVaddr);
    // Every address the unit wrote as a zero is filled in here, against the one
    // thing that knows where each symbol ended up: the layout above.
    const uint64_t afterDebugLine=hasDebugLine?debugLineOff+debugLine.bytes.size():afterShdr;
    const uint64_t debugAbbrevOff=hasDebugInfo?afterDebugLine:0;
    const uint64_t debugInfoOff=hasDebugInfo?alignUp(debugAbbrevOff+debugInfo.abbrev.size(),8):0;
    std::vector<uint8_t> debugInfoBytes=debugInfo.bytes;
    if(hasDebugInfo){
        std::map<std::string,uint64_t> symVaddr;
        symVaddr[".text"]=textVaddr;
        for(const auto& e:exports)symVaddr[e.name]=textVaddr+e.offset;
        for(const auto& g:globals)symVaddr[g.name]=(g.kind==1?dataVaddr:bssVaddr)+g.offset;
        for(const auto& p:debugInfo.patches){
            auto it=symVaddr.find(p.symbol);
            if(it==symVaddr.end())throw Error("internal error: .debug_info references a symbol the shared object does not define: "+p.symbol);
            dbgPatchAddress(debugInfoBytes,p.offset,it->second+(uint64_t)p.addend);
        }
    }
    // v0.23.33-dev: .eh_frame, resolved the same way, and the header an
    // unwinder searches — one sorted row per FDE, every column a displacement
    // from the header itself, so a loaded object at any address can read them.
    const uint64_t afterDebugInfo=hasDebugInfo?debugInfoOff+debugInfoBytes.size():afterDebugLine;
    const uint64_t ehFrameOff=hasEhFrame?alignUp(afterDebugInfo,8):0;
    const uint64_t ehFrameHdrOff=hasEhFrame?alignUp(ehFrameOff+ehFrame.size(),8):0;
    std::vector<uint8_t> ehFrameBytes=ehFrame,ehFrameHdr;
    if(hasEhFrame){
        std::map<std::string,uint64_t> symVaddr;
        symVaddr[".text"]=textVaddr;
        for(const auto& e:exports)symVaddr[e.name]=textVaddr+e.offset;
        for(const auto& g:globals)symVaddr[g.name]=(g.kind==1?dataVaddr:bssVaddr)+g.offset;
        for(const auto& p:ehFramePatches){
            auto it=symVaddr.find(p.symbol);
            if(it==symVaddr.end())throw Error("internal error: .eh_frame references a symbol the shared object does not define: "+p.symbol);
            if(p.offset+4>ehFrameBytes.size())throw Error("internal error: .eh_frame address patch is out of bounds");
            const int64_t disp=(int64_t)(it->second+(uint64_t)p.addend)-(int64_t)(ehFrameOff+p.offset);
            if(disp<-2147483648ll||disp>2147483647ll)throw Error("internal error: .eh_frame displacement does not fit in 32 bits");
            for(int i=0;i<4;++i)ehFrameBytes[(size_t)p.offset+(size_t)i]=uint8_t((uint32_t)disp>>(8*i));
        }
        std::vector<std::pair<uint64_t,uint64_t>> table;
        for(const auto& f:ehFrameFdes){auto it=symVaddr.find(f.first);if(it!=symVaddr.end())table.push_back({it->second,f.second});}
        std::sort(table.begin(),table.end());
        ehFrameHdr.push_back(1);                       // version
        ehFrameHdr.push_back(0x1b);                    // eh_frame_ptr: pcrel sdata4
        ehFrameHdr.push_back(0x03);                    // fde_count: udata4
        ehFrameHdr.push_back(0x3b);                    // table: datarel sdata4
        ehPut32(ehFrameHdr,(uint32_t)((int64_t)ehFrameOff-(int64_t)(ehFrameHdrOff+4)));
        ehPut32(ehFrameHdr,(uint32_t)table.size());
        for(const auto& e:table){
            ehPut32(ehFrameHdr,(uint32_t)((int64_t)e.first-(int64_t)ehFrameHdrOff));
            ehPut32(ehFrameHdr,(uint32_t)((int64_t)(ehFrameOff+e.second)-(int64_t)ehFrameHdrOff));
        }
    }
    std::vector<Shdr> sh(kShnumAll);
    auto setSh=[&](int i,uint32_t name,uint32_t type,uint64_t flags,uint64_t addr,uint64_t off,uint64_t size,uint32_t link,uint32_t info,uint64_t align,uint64_t entsize){
        Shdr& e=sh[i];e.name=name;e.type=type;e.flags=flags;e.addr=addr;e.offset=off;e.size=size;e.link=link;e.info=info;e.addralign=align;e.entsize=entsize;};
    setSh(S_TEXT,nText,1,0x6,textVaddr,textOff,text.size(),0,0,4,0);
    setSh(S_DYNSYM,nDynsym,11,0x2,dynsymOff,dynsymOff,dynsymSize,S_DYNSTR,1,8,sizeof(Sym));
    setSh(S_DYNSTR,nDynstr,3,0x2,dynstrOff,dynstrOff,dynstrSize,0,0,1,0);
    setSh(S_HASH,nHash,5,0x2,hashOff,hashOff,hashSize,S_DYNSYM,0,4,0);
    setSh(S_RELA,nRela,4,0x2,relaOff,relaOff,relaSize,S_DYNSYM,0,8,sizeof(Rela));
    setSh(S_DATA,nData,1,0x3,dataVaddr,dataVaddr,dataSize,0,0,8,0);
    setSh(S_GOT,nGot,1,0x3,gotVaddr,gotVaddr,gotSize,0,0,8,0);
    setSh(S_DYNAMIC,nDynamic,6,0x3,dynOff,dynOff,dynSize,S_DYNSTR,0,8,sizeof(Elf64Dyn));
    setSh(S_BSS,nBss,8,0x3,bssVaddr,relroEnd,bssSize,0,0,8,0);
    if(hasInit)setSh(S_INIT_ARRAY,nInitArray,1,0x3,initArrVaddr,initArrVaddr,initArrSize,0,0,8,0);
    setSh(kSymIdx,nSymtab,2,0,0,symOff,symSize,kStrIdx,outSymbols.empty()?0u:1u,8,sizeof(Sym));
    setSh(kStrIdx,nStrtab,3,0,0,strOff,st.strtab.size(),0,0,1,0);
    setSh(kShstrIdx,nShstr,3,0,0,shstrOff,shstr.size(),0,0,1,0);
    if(hasDebugLine)setSh(kDlIdx,nDebugLine,1,0,0,debugLineOff,debugLineBytes.size(),0,0,1,0);
    if(hasDebugInfo){
        setSh(kDaIdx,nDebugAbbrev,1,0,0,debugAbbrevOff,debugInfo.abbrev.size(),0,0,1,0);
        setSh(kDiIdx,nDebugInfo,1,0,0,debugInfoOff,debugInfoBytes.size(),0,0,1,0);
    }
    if(hasEhFrame){
        setSh(kEfIdx,nEhFrame,1,0x2,ehFrameOff,ehFrameOff,ehFrameBytes.size(),0,0,4,0);
        setSh(kEfhIdx,nEhFrameHdr,1,0x2,ehFrameHdrOff,ehFrameHdrOff,ehFrameHdr.size(),0,0,4,0);
    }
    Ehdr h{};initIdent(h,3);h.entry=0;h.phoff=sizeof(Ehdr);h.phentsize=sizeof(Phdr);h.phnum=(uint16_t)(4+(hasEhFrame?2:0));
    h.shoff=shoff;h.shentsize=sizeof(Shdr);h.shnum=kShnumAll;h.shstrndx=kShstrIdx;
    Phdr p0{};p0.type=1;p0.flags=5;p0.offset=0;p0.vaddr=0;p0.paddr=0;p0.filesz=seg0End;p0.memsz=seg0End;p0.align=0x1000;
    Phdr p1{};p1.type=1;p1.flags=6;p1.offset=dataVaddr;p1.vaddr=dataVaddr;p1.paddr=dataVaddr;p1.filesz=relroEnd-dataVaddr;p1.memsz=(bssVaddr-dataVaddr)+bssSize;p1.align=0x1000;
    Phdr p2{};p2.type=2;p2.flags=6;p2.offset=dynOff;p2.vaddr=dynOff;p2.paddr=dynOff;p2.filesz=dynSize;p2.memsz=dynSize;p2.align=8;
    Phdr p3{};p3.type=0x6474e552;p3.flags=4;p3.offset=relroVaddr;p3.vaddr=relroVaddr;p3.paddr=relroVaddr;p3.filesz=relroEnd-relroVaddr;p3.memsz=relroEnd-relroVaddr;p3.align=1;
    // The unwind table is read out of the running image, so it needs a PT_LOAD
    // of its own past every other segment — appending it to an existing one
    // would move a boundary every other offset in this file is computed from.
    Phdr p4{};if(hasEhFrame){p4.type=1;p4.flags=4;p4.offset=ehFrameOff;p4.vaddr=ehFrameOff;p4.paddr=ehFrameOff;p4.filesz=ehFrameHdrOff+ehFrameHdr.size()-ehFrameOff;p4.memsz=ehFrameHdrOff+ehFrameHdr.size()-ehFrameOff;p4.align=0x1000;}
    Phdr p5{};if(hasEhFrame){p5.type=0x6474e550u;p5.flags=4;p5.offset=ehFrameHdrOff;p5.vaddr=ehFrameHdrOff;p5.paddr=ehFrameHdrOff;p5.filesz=ehFrameHdr.size();p5.memsz=ehFrameHdr.size();p5.align=4;}
    std::ofstream o(path,std::ios::binary);if(!o)throw Error("cannot create output: "+path);
    auto pad=[&](uint64_t from,uint64_t to){if(to>from){std::vector<char> z((size_t)(to-from),0);o.write(z.data(),(std::streamsize)z.size());}};
    o.write((char*)&h,sizeof h);o.write((char*)&p0,sizeof p0);o.write((char*)&p1,sizeof p1);o.write((char*)&p2,sizeof p2);o.write((char*)&p3,sizeof p3);
    if(hasEhFrame){o.write((char*)&p4,sizeof p4);o.write((char*)&p5,sizeof p5);}
    pad(sizeof(Ehdr)+h.phnum*sizeof(Phdr),textOff);
    o.write((const char*)text.data(),(std::streamsize)text.size());
    pad(textEnd,dynsymOff);o.write((const char*)dynsym.data(),(std::streamsize)dynsymSize);
    o.write(dynstr.data(),(std::streamsize)dynstrSize);
    pad(dynstrOff+dynstrSize,hashOff);o.write((const char*)hash.data(),(std::streamsize)hashSize);
    pad(hashOff+hashSize,relaOff);o.write((const char*)relas.data(),(std::streamsize)relaSize);
    pad(seg0End,dataVaddr);o.write((const char*)data.data(),(std::streamsize)dataSize);
    if(hasInit){pad(dataVaddr+dataSize,initArrVaddr);std::vector<uint8_t> ia(8,0);for(int k=0;k<8;++k)ia[k]=uint8_t((textVaddr+uint64_t(initOffset))>>(k*8));o.write((const char*)ia.data(),8);}
    pad((uint64_t)o.tellp(),gotVaddr);o.write((const char*)got.data(),(std::streamsize)gotSize);
    pad(gotVaddr+gotSize,dynOff);o.write((const char*)dyn.data(),(std::streamsize)dynSize);
    pad((uint64_t)o.tellp(),symOff);o.write((const char*)st.syms.data(),(std::streamsize)symSize);
    o.write(st.strtab.data(),(std::streamsize)st.strtab.size());o.write(shstr.data(),(std::streamsize)shstr.size());
    pad((uint64_t)o.tellp(),shoff);o.write((const char*)sh.data(),(std::streamsize)(kShnumAll*sizeof(Shdr)));
    if(hasDebugLine){pad((uint64_t)o.tellp(),debugLineOff);o.write((const char*)debugLineBytes.data(),(std::streamsize)debugLineBytes.size());}
    if(hasDebugInfo){
        pad((uint64_t)o.tellp(),debugAbbrevOff);o.write((const char*)debugInfo.abbrev.data(),(std::streamsize)debugInfo.abbrev.size());
        pad((uint64_t)o.tellp(),debugInfoOff);o.write((const char*)debugInfoBytes.data(),(std::streamsize)debugInfoBytes.size());
    }
    if(hasEhFrame){
        pad((uint64_t)o.tellp(),ehFrameOff);o.write((const char*)ehFrameBytes.data(),(std::streamsize)ehFrameBytes.size());
        pad((uint64_t)o.tellp(),ehFrameHdrOff);o.write((const char*)ehFrameHdr.data(),(std::streamsize)ehFrameHdr.size());
    }
    if(!o)throw Error("failed writing shared object");
    (void)S_NULL;
}

// ----------------------------------------------------------------------------------------------
// v0.20.0: dynamic shared objects with GNU hash, PLT/GOT and page-aligned GNU RELRO.
//
// A .so emitted here carries real dynamic-linking metadata:
//   * DT_SONAME names the object itself; every DT_NEEDED names a library it depends on;
//   * each undefined *function* gets a .plt stub plus a .got.plt slot holding an
//     R_AARCH64_JUMP_SLOT relocation, described by DT_JMPREL/DT_PLTRELSZ/DT_PLTREL/DT_PLTGOT;
//   * each undefined *object* (a global or array owned by another .so) gets a .got slot holding an
//     R_AARCH64_GLOB_DAT relocation inside the DT_RELA/DT_RELASZ/DT_RELAENT range;
//   * every global the object itself defines keeps its GOT-style address slot, fixed up by an
//     R_AARCH64_RELATIVE relocation that is counted by DT_RELACOUNT;
//   * the SysV SysV DT_HASH and GNU DT_GNU_HASH both resolve every definition, including the globals.
// The PLT is built for eager binding (DT_BIND_NOW + DT_FLAGS=DF_BIND_NOW), so no lazy-resolution
// trampoline is needed: a stub is exactly ADRP x16,page(slot) / LDR x17,[x16,#lo12(slot)] / BR x17.
std::string pltSymbol(const std::string& n){return "__aster_plt_"+n;}
std::string baseNameOf(const std::string& p){size_t s=p.find_last_of('/');return s==std::string::npos?p:p.substr(s+1);}

// Map an extern import symbol to the Android system library that provides it.
// Aster emits DT_NEEDED from this so the on-device linker (which binds PLT
// stubs eagerly, RTLD_NOW) can resolve them at dlopen() time. Without a matching
// DT_NEEDED, dlopen() aborts with "cannot locate symbol" and the NativeActivity
// host crashes on launch. C-library symbols fall back to libc.so.
static std::string ndkLibraryFor(const std::string& s) {
    // Prefix tests use rfind(x,0)==0 (starts-with). NOTE: std::string::compare
    // (pos,count,cstr) compares lengths first and is NOT a prefix test, so it
    // must not be used here. Order matters: check the more specific
    // "__android_log*" (liblog) before the broader "__android*" (libandroid).
    if (s.rfind("__android_log", 0)==0) return "liblog.so";
    if (s.rfind("__android", 0)==0) return "libandroid.so";
    if (s.rfind("ANativeActivity_", 0)==0) return "libandroid.so";
    if (s.rfind("AConfiguration_", 0)==0) return "libandroid.so";
    if (s.rfind("ALooper_", 0)==0) return "libandroid.so";
    if (s.rfind("AInputQueue_", 0)==0) return "libandroid.so";
    if (s.rfind("AInputEvent_", 0)==0) return "libandroid.so";
    if (s.rfind("ASensorManager", 0)==0) return "libandroid.so";
    if (s.rfind("ASensor", 0)==0) return "libandroid.so";
    if (s.rfind("AChoreographer_", 0)==0) return "libandroid.so";
    if (s.rfind("ANativeWindow_", 0)==0) return "libandroid.so";
    if (s.rfind("ASurface", 0)==0) return "libandroid.so";
    if (s.rfind("AImageReader_", 0)==0) return "libandroid.so";
    if (s.rfind("AMedia", 0)==0) return "libandroid.so";
    if (s.rfind("AHardwareBuffer_", 0)==0) return "libandroid.so";
    if (s.rfind("AStorageManager", 0)==0) return "libandroid.so";
    if (s.rfind("ARect_", 0)==0) return "libandroid.so";
    if (s.rfind("ADataSpace_", 0)==0) return "libandroid.so";
    if (s=="dlopen"||s=="dlsym"||s=="dlclose"||s=="dlerror"||s=="dladdr"||s=="dl_iterate_phdr") return "libdl.so";
    static const char* kMath[]={"sin","cos","tan","sqrt","pow","exp","log","log10","fabs","floor","ceil","fmod","atan","asin","acos","atan2","sinh","cosh","tanh","hypot","round","trunc",
    // v0.23.15-dev: lrint* family. The native_touch example captures a C
    // `float` return value (AMotionEvent_getX/Y leaves the value in s0) by
    // calling the zero-argument lrintf right after: lrintf reads its argument
    // from s0 and returns a long in x0, which Aster's i32 return convention
    // (low 32 bits of x0) reads exactly for screen coordinates. That bridge
    // only works if lrintf resolves, which needs libm.so in DT_NEEDED.
    "lrintf","lrint","llrint","llrintf",nullptr};
    for (int i=0;kMath[i];++i) if (s==kMath[i]) return "libm.so";
    return "libc.so";
}

struct SoDynSpec {
    std::string soname;                            // DT_SONAME string (empty = no DT_SONAME)
    std::vector<std::string> needed;               // DT_NEEDED library names, in order
    std::vector<SoExport> exports;                 // defined functions, with .text offsets
    std::vector<ObjectLayout::GlobalDef> globals;   // defined objects (kind 1 = .data, 2 = .bss)
    std::vector<std::string> importFuncs;          // undefined functions, called through .plt
    std::vector<std::string> importObjects;        // undefined objects, addressed through .got
    std::vector<std::string> funcAddrRefs;         // defined functions referenced by address (callback tables)
    std::vector<uint8_t> data;
    std::vector<uint8_t> rodata;
    // -g: already-relocated .debug_line bytes for the whole image.
    std::vector<uint8_t> debugLine;
    // v0.23.32-dev: .debug_info, its abbreviation table, and the addresses in
    // it — resolved here, because only this writer knows where each segment
    // lands in a shared object.
    std::vector<uint8_t> debugInfo,debugAbbrev;
    std::vector<DebugInfoBlob::Patch> debugInfoPatches;
    // v0.23.33-dev: .eh_frame and the same question again — every FDE's address
    // is a displacement from itself, so it can only be written here. The FDE
    // table for .eh_frame_hdr names its function rather than its address,
    // because the two are resolved together.
    std::vector<uint8_t> ehFrame;
    std::vector<EhFrameBlob::Patch> ehFramePatches;
    std::vector<std::pair<std::string,uint64_t>> ehFrameFdes;
    uint64_t bssSize=0;
    int64_t initOffset=-1;                         // offset of __aster_init inside .text, or -1
};

void writeSharedObjectDyn(const std::string& path,std::vector<uint8_t>& text,
                          const std::vector<LinkPending>& pendingIn,const SoDynSpec& spec){
    if(text.empty())throw Error("cannot write a shared object without code");
    if(spec.exports.empty())throw Error("shared object must export at least one function");
    const size_t nExp=spec.exports.size(),nDef=spec.globals.size();
    const size_t nIF=spec.importFuncs.size(),nIO=spec.importObjects.size(),nFunc=spec.funcAddrRefs.size();
    const bool hasDebugLine=!spec.debugLine.empty();
    const uint32_t gnuSymOffset=1, gnuBloomShift=6;
    auto gnuHashName=[](const char* q)->uint32_t{uint32_t h=5381;for(;*q;++q)h=h*33u+(uint8_t)*q;return h;};
    struct GnuDef { bool isGlobal; size_t sourceIndex; uint32_t hash; uint32_t bucket; std::string name; };
    const uint32_t gnuBucketCount=(uint32_t)std::max<size_t>(1,(nExp+nDef)/2);
    const uint32_t gnuBloomCount=[&](){uint32_t n=1;while(n<std::max<size_t>(1,(nExp+nDef+7)/8))n<<=1;return n;}();
    std::vector<GnuDef> gnuDefs; gnuDefs.reserve(nExp+nDef);
    for(size_t i=0;i<nExp;++i){uint32_t h=gnuHashName(spec.exports[i].name.c_str());gnuDefs.push_back({false,i,h,h%gnuBucketCount,spec.exports[i].name});}
    for(size_t i=0;i<nDef;++i){uint32_t h=gnuHashName(spec.globals[i].name.c_str());gnuDefs.push_back({true,i,h,h%gnuBucketCount,spec.globals[i].name});}
    std::stable_sort(gnuDefs.begin(),gnuDefs.end(),[](const GnuDef& a,const GnuDef& b){return a.bucket<b.bucket;});
    std::map<std::string,uint32_t> dynIndex;
    for(size_t i=0;i<gnuDefs.size();++i)dynIndex[gnuDefs[i].name]=gnuSymOffset+(uint32_t)i;
    for(size_t i=0;i<nIF;++i)dynIndex[spec.importFuncs[i]]=gnuSymOffset+(uint32_t)gnuDefs.size()+(uint32_t)i;
    for(size_t i=0;i<nIO;++i)dynIndex[spec.importObjects[i]]=gnuSymOffset+(uint32_t)gnuDefs.size()+(uint32_t)nIF+(uint32_t)i;
    const bool hasInit=spec.initOffset>=0;
    // Calls to an imported function are retargeted at that function's PLT stub before resolution.
    std::vector<LinkPending> pending=pendingIn;
    std::set<std::string> importFuncSet(spec.importFuncs.begin(),spec.importFuncs.end());
    for(auto& r:pending)if(r.type==283&&importFuncSet.count(r.symbol))r.symbol=pltSymbol(r.symbol);

    // ---- .dynstr / .dynsym naming ------------------------------------------------------------
    std::string dynstr(1,'\0');
    auto addDynStr=[&](const std::string& s)->uint32_t{uint32_t o=(uint32_t)dynstr.size();dynstr+=s;dynstr.push_back('\0');return o;};
    std::vector<uint32_t> expName(nExp),glName(nDef),ifName(nIF),ioName(nIO);
    for(size_t i=0;i<nExp;++i)expName[i]=addDynStr(spec.exports[i].name);
    for(size_t i=0;i<nDef;++i)glName[i]=addDynStr(spec.globals[i].name);
    for(size_t i=0;i<nIF;++i)ifName[i]=addDynStr(spec.importFuncs[i]);
    for(size_t i=0;i<nIO;++i)ioName[i]=addDynStr(spec.importObjects[i]);
    const uint32_t sonameOff=spec.soname.empty()?0:addDynStr(spec.soname);
    std::vector<uint32_t> neededOff;for(const auto& n:spec.needed)neededOff.push_back(addDynStr(n));

    // ---- section names and indices -----------------------------------------------------------
    std::vector<std::string> shnames(1,std::string());
    auto addSec=[&](const char* n){shnames.push_back(n);return (uint16_t)(shnames.size()-1);};
    const uint16_t S_TEXT=addSec(".text"),S_PLT=addSec(".plt"),S_DYNSYM=addSec(".dynsym"),S_DYNSTR=addSec(".dynstr"),
        S_HASH=addSec(".hash"),S_RELADYN=addSec(".rela.dyn"),S_RELAPLT=addSec(".rela.plt");
    const uint16_t S_RODATA=spec.rodata.empty()?0:addSec(".rodata");
    const uint16_t S_DATA=addSec(".data"),S_GOTPLT=addSec(".got.plt"),S_GOT=addSec(".got"),S_DYNAMIC=addSec(".dynamic"),S_BSS=addSec(".bss");
    uint16_t S_INITARR=0;if(hasInit)S_INITARR=addSec(".init_array");
    const uint16_t S_GNUHASH=addSec(".gnu.hash");
    const uint16_t S_SYMTAB=addSec(".symtab"),S_STRTAB=addSec(".strtab"),S_SHSTR=addSec(".shstrtab");
    // Last, so that adding it moves no other index.
    const uint16_t S_DEBUGLINE=hasDebugLine?addSec(".debug_line"):0;
    // v0.23.32-dev: .debug_info and its table, after .debug_line for the same
    // reason: the sections that existed before keep the indices they had.
    const bool hasDebugInfo=!spec.debugInfo.empty();
    const uint16_t S_DEBUGABBREV=hasDebugInfo?addSec(".debug_abbrev"):0;
    const uint16_t S_DEBUGINFO=hasDebugInfo?addSec(".debug_info"):0;
    // v0.23.33-dev: the unwind table, last for the same reason — and the first
    // sections here a running program reads, so it gets a PT_LOAD of its own.
    const bool hasEhFrame=!spec.ehFrame.empty();
    const uint16_t S_EHFRAME=hasEhFrame?addSec(".eh_frame"):0;
    const uint16_t S_EHFRAMEHDR=hasEhFrame?addSec(".eh_frame_hdr"):0;
    const uint16_t shnum=(uint16_t)shnames.size();
    std::string shstr(1,'\0');std::vector<uint32_t> shNameOff(shnum,0);
    for(uint16_t i=1;i<shnum;++i){shNameOff[i]=(uint32_t)shstr.size();shstr+=shnames[i];shstr.push_back('\0');}

    // ---- fixed layout (link-time vaddr == file offset, load base 0) ---------------------------
    const uint64_t textVaddr=0x1000,textOff=0x1000,textEnd=textOff+text.size();
    const uint64_t pltOff=alignUp(textEnd,16),pltSize=16*nIF;
    const uint64_t nsym=1+nExp+nDef+nIF+nIO;
    const uint64_t dynsymOff=alignUp(pltOff+pltSize,8),dynsymSize=nsym*sizeof(Sym);
    const uint64_t dynstrOff=dynsymOff+dynsymSize,dynstrSize=dynstr.size();
    const uint32_t nchain=(uint32_t)nsym,nbucket=nchain<3?3u:nchain;
    const uint64_t hashOff=alignUp(dynstrOff+dynstrSize,4),hashSize=(2+uint64_t(nbucket)+uint64_t(nchain))*4;
    // Defined symbols are bucket-sorted in .dynsym; undefined imports follow them.
    const uint64_t gnuHashOff=alignUp(hashOff+hashSize,8);
    const uint64_t gnuHashSize=16+8*uint64_t(gnuBloomCount)+4*uint64_t(gnuBucketCount)+4*uint64_t(gnuDefs.size());
    const uint64_t nRel=1+nDef+nFunc+(hasInit?1u:0u);  // R_AARCH64_RELATIVE entries come first
    const uint64_t nRelaDyn=nRel+nIO;                      // + one R_AARCH64_GLOB_DAT per data import
    const uint64_t relaDynOff=alignUp(gnuHashOff+gnuHashSize,8),relaDynSize=nRelaDyn*sizeof(Rela);
    const uint64_t relaPltOff=alignUp(relaDynOff+relaDynSize,8),relaPltSize=uint64_t(nIF)*sizeof(Rela);
    const uint64_t seg0End=relaPltOff+relaPltSize;
    const uint64_t rodataVaddr=alignUp(seg0End,0x1000),rodataSize=spec.rodata.size();
    const uint64_t dataVaddr=alignUp(rodataVaddr+rodataSize,0x1000),dataSize=spec.data.size();
    // Dedicated page boundary between ordinary writable globals and loader-relocated data.
    // This prevents page-granular RELRO from changing .data permissions.
    const uint64_t relroVaddr=alignUp(dataVaddr+dataSize,0x1000);
    const uint64_t initArrVaddr=relroVaddr,initArrSize=hasInit?8:0;
    const uint64_t gotPltVaddr=initArrVaddr+initArrSize,gotPltSize=8*(3+nIF);
    const uint64_t gotVaddr=gotPltVaddr+gotPltSize,gotSize=8*(nDef+nIO+nFunc);
    const uint64_t dynOff=alignUp(gotVaddr+gotSize,8);

    // ---- .dynamic ----------------------------------------------------------------------------
    std::vector<Elf64Dyn> dyn;
    for(uint32_t o:neededOff)dyn.push_back({1,(uint64_t)o});
    if(!spec.soname.empty())dyn.push_back({14,(uint64_t)sonameOff});
    dyn.push_back({4,hashOff});
    dyn.push_back({0x6ffffef5,gnuHashOff});                  // DT_GNU_HASH
    dyn.push_back({5,dynstrOff});
    dyn.push_back({6,dynsymOff});
    dyn.push_back({10,dynstrSize});
    dyn.push_back({11,sizeof(Sym)});
    dyn.push_back({7,relaDynOff});
    dyn.push_back({8,relaDynSize});
    dyn.push_back({9,sizeof(Rela)});
    dyn.push_back({1879048185,(uint64_t)nRel});            // DT_RELACOUNT
    if(nIF>0){
        dyn.push_back({23,relaPltOff});                    // DT_JMPREL
        dyn.push_back({2,relaPltSize});                    // DT_PLTRELSZ
        dyn.push_back({20,7});                             // DT_PLTREL = DT_RELA
        dyn.push_back({3,gotPltVaddr});                    // DT_PLTGOT
        dyn.push_back({24,0});                             // DT_BIND_NOW
        dyn.push_back({30,0x8});                           // DT_FLAGS = DF_BIND_NOW
    }
    if(hasInit){dyn.push_back({25,initArrVaddr});dyn.push_back({27,initArrSize});}
    dyn.push_back({0,0});
    const uint64_t dynSize=dyn.size()*sizeof(Elf64Dyn);
    const uint64_t seg1End=dynOff+dynSize;
    const uint64_t relroEnd=alignUp(seg1End,0x1000);
    const uint64_t bssVaddr=relroEnd;

    // ---- .got.plt / .got and the dynamic relocations -----------------------------------------
    std::vector<uint8_t> gotPlt((size_t)gotPltSize,0),got((size_t)gotSize,0);
    std::vector<Rela> relas,relasPlt;
    auto put64=[&](std::vector<uint8_t>& v,size_t off,uint64_t x){for(int k=0;k<8;++k)v[off+(size_t)k]=uint8_t(x>>(k*8));};
    put64(gotPlt,0,dynOff);                                 // GOT[0] = &_DYNAMIC
    {Rela r{};r.offset=gotPltVaddr;r.info=1027;r.addend=(int64_t)dynOff;relas.push_back(r);}
    std::map<std::string,uint64_t> gatAddr;
    for(size_t i=0;i<nDef;++i){
        const uint64_t v=spec.globals[i].kind==1?dataVaddr+spec.globals[i].offset:(spec.globals[i].kind==3?rodataVaddr+spec.globals[i].offset:bssVaddr+spec.globals[i].offset);
        put64(got,8*i,v);
        Rela r{};r.offset=gotVaddr+8*i;r.info=1027;r.addend=(int64_t)v;relas.push_back(r);
        gatAddr[gatSymbol(spec.globals[i].name)]=gotVaddr+8*i;
    }
    if(hasInit){Rela r{};r.offset=initArrVaddr;r.info=1027;r.addend=(int64_t)(textVaddr+uint64_t(spec.initOffset));relas.push_back(r);}
    // Functions referenced by address (e.g. NativeActivity callback tables) each get a GOT slot
    // holding the run-time function address via an R_AARCH64_RELATIVE relocation (load-bearing:
    // a loader that skipped it would hand the code a null callback and crash on invocation).
    if(nFunc>0){
        std::map<std::string,uint64_t> exportVaddr;
        for(const auto& e:spec.exports)exportVaddr[e.name]=textVaddr+e.offset;
        for(size_t i=0;i<nFunc;++i){
            const auto it=exportVaddr.find(spec.funcAddrRefs[i]);
            if(it==exportVaddr.end())throw Error("internal error: FuncAddr target is not an exported function: "+spec.funcAddrRefs[i]);
            const uint64_t v=it->second;
            put64(got,8*(nDef+nIO+i),v);
            Rela r{};r.offset=gotVaddr+8*(nDef+nIO+i);r.info=1027;r.addend=(int64_t)v;relas.push_back(r);
            gatAddr[gatSymbol(spec.funcAddrRefs[i])]=gotVaddr+8*(nDef+nIO+i);
        }
    }
    for(size_t i=0;i<nIO;++i){
        const uint64_t slot=gotVaddr+8*(nDef+i);
        Rela r{};r.offset=slot;r.info=((uint64_t)dynIndex.at(spec.importObjects[i])<<32)|1025;r.addend=0;relas.push_back(r); // R_AARCH64_GLOB_DAT
        gatAddr[gatSymbol(spec.importObjects[i])]=slot;
    }
    std::vector<uint8_t> plt((size_t)pltSize,0);
    for(size_t i=0;i<nIF;++i){
        const uint64_t slot=gotPltVaddr+8*(3+i);
        Rela r{};r.offset=slot;r.info=((uint64_t)dynIndex.at(spec.importFuncs[i])<<32)|1026;r.addend=0;relasPlt.push_back(r);   // R_AARCH64_JUMP_SLOT
        const uint64_t ins=pltOff+16*i;
        const int64_t page=(int64_t)((slot&~uint64_t(0xfff))-(ins&~uint64_t(0xfff)))>>12;
        const uint32_t imm=uint32_t(page);
        const uint32_t ws[4]={0x90000000u|((imm&3u)<<29)|(((imm>>2)&0x7ffffu)<<5)|16u,   // ADRP x16, page(slot)
                              0xF9400000u|(uint32_t((slot&0xfff)>>3)<<10)|(16u<<5)|17u, // LDR  x17, [x16, #lo12(slot)] (imm12 scaled by 8)
                              0xD61F0000u|(17u<<5),                                      // BR   x17
                              0xD503201Fu};                                              // NOP
        for(int k=0;k<4;++k)for(int b=0;b<4;++b)plt[16*i+(size_t)(4*k+b)]=uint8_t(ws[k]>>(b*8));
    }

    // ---- .dynsym (null, bucket-sorted definitions, then undefined imports) --------------------
    std::vector<Sym> dynsym((size_t)nsym);
    for(size_t j=0;j<gnuDefs.size();++j){const auto& d=gnuDefs[j];Sym& sym=dynsym[gnuSymOffset+j];
        if(!d.isGlobal){const auto& e=spec.exports[d.sourceIndex];sym.name=expName[d.sourceIndex];sym.info=0x12;sym.shndx=S_TEXT;sym.value=textVaddr+e.offset;sym.size=e.size;}
        else {const auto& g=spec.globals[d.sourceIndex];sym.name=glName[d.sourceIndex];sym.info=0x11;sym.shndx=g.kind==1?S_DATA:(g.kind==3?S_RODATA:S_BSS);
            sym.value=g.kind==1?dataVaddr+g.offset:(g.kind==3?rodataVaddr+g.offset:bssVaddr+g.offset);sym.size=g.size;}}
    for(size_t i=0;i<nIF;++i){Sym& sym=dynsym[dynIndex.at(spec.importFuncs[i])];sym.name=ifName[i];sym.info=0x12;sym.shndx=0;sym.value=0;sym.size=0;}
    for(size_t i=0;i<nIO;++i){Sym& sym=dynsym[dynIndex.at(spec.importObjects[i])];sym.name=ioName[i];sym.info=0x11;sym.shndx=0;sym.value=0;sym.size=0;}

    // ---- DT_HASH over every dynamic symbol ---------------------------------------------------
    std::vector<uint32_t> hash((size_t)(2+uint64_t(nbucket)+uint64_t(nchain)),0u);
    hash[0]=nbucket;hash[1]=nchain;
    uint32_t* buckets=hash.data()+2;uint32_t* chains=buckets+nbucket;
    for(uint32_t i=1;i<nchain;++i){const char* q=dynstr.c_str()+dynsym[i].name;uint32_t h=0;
        for(;*q;++q){h=(h<<4)+uint32_t((unsigned char)*q);const uint32_t g=h&0xf0000000u;if(g)h^=g>>24;h&=~g;}
        const uint32_t b=(uint32_t)(h%nbucket);chains[i]=buckets[b];buckets[b]=i;}

    // ---- .gnu.hash (bucket-sorted definitions; undefined imports are not hashed) ----------
    std::vector<uint8_t> gnuHash((size_t)gnuHashSize,0);
    auto put32v=[&](size_t off,uint32_t x){for(int k=0;k<4;++k)gnuHash[off+(size_t)k]=uint8_t(x>>(k*8));};
    auto put64v=[&](size_t off,uint64_t x){for(int k=0;k<8;++k)gnuHash[off+(size_t)k]=uint8_t(x>>(k*8));};
    put32v(0,gnuBucketCount);put32v(4,gnuSymOffset);put32v(8,gnuBloomCount);put32v(12,gnuBloomShift);
    std::vector<uint64_t> bloom(gnuBloomCount,0);
    std::vector<uint32_t> gnuBuckets(gnuBucketCount,0),gnuChains(gnuDefs.size(),0);
    for(size_t j=0;j<gnuDefs.size();++j){
        const auto& def=gnuDefs[j];const uint32_t symIndex=gnuSymOffset+(uint32_t)j;const uint32_t h=def.hash;
        const uint32_t word=(h/64)%gnuBloomCount;
        bloom[word]|=uint64_t(1)<<(h%64);bloom[word]|=uint64_t(1)<<((h>>gnuBloomShift)%64);
        if(gnuBuckets[def.bucket]==0)gnuBuckets[def.bucket]=symIndex;
        gnuChains[j]=h&~1u;
        if(j+1==gnuDefs.size()||gnuDefs[j+1].bucket!=def.bucket)gnuChains[j]|=1u;
    }
    size_t go=16;for(uint32_t i=0;i<gnuBloomCount;++i,go+=8)put64v(go,bloom[i]);
    for(uint32_t i=0;i<gnuBucketCount;++i,go+=4)put32v(go,gnuBuckets[i]);
    for(size_t i=0;i<gnuChains.size();++i,go+=4)put32v(go,gnuChains[i]);

    // ---- relocation resolution ---------------------------------------------------------------
    std::map<std::string,uint64_t> symbolVaddr;std::map<std::string,int> symbolKind;
    for(const auto& e:spec.exports){symbolVaddr[e.name]=textVaddr+e.offset;symbolKind[e.name]=0;}
    for(const auto& kv:gatAddr){symbolVaddr[kv.first]=kv.second;symbolKind[kv.first]=3;}
    for(size_t i=0;i<nIF;++i){symbolVaddr[pltSymbol(spec.importFuncs[i])]=pltOff+16*i;symbolKind[pltSymbol(spec.importFuncs[i])]=0;}
    resolveRelocations(text,pending,symbolVaddr,symbolKind,textVaddr);

    // ---- source-level .symtab/.strtab --------------------------------------------------------
    std::vector<OutSym> outSymbols;
    for(size_t i=0;i<nExp;++i)if(spec.exports[i].name.compare(0,8,"__aster_")!=0)outSymbols.push_back({spec.exports[i].name,0,spec.exports[i].offset,spec.exports[i].size});
    for(size_t i=0;i<nDef;++i)outSymbols.push_back({spec.globals[i].name,spec.globals[i].kind,spec.globals[i].offset,spec.globals[i].size});
    const SymTable st=buildSymbolTable(outSymbols,textVaddr,dataVaddr,bssVaddr,S_TEXT,S_DATA,S_BSS,rodataVaddr,S_RODATA);
    const uint64_t symOff=alignUp(relroEnd,8),symSize=uint64_t(st.syms.size())*sizeof(Sym);
    const uint64_t strOff=symOff+symSize,shstrOff=strOff+st.strtab.size();
    const uint64_t shoff=alignUp(shstrOff+shstr.size(),8);
    // Past the section-header table, as in writeSharedObject: no earlier offset moves.
    const uint64_t debugLineOff=hasDebugLine?alignUp(shoff+uint64_t(shnum)*sizeof(Shdr),8):0;
    const uint64_t afterDebugLine=hasDebugLine?debugLineOff+spec.debugLine.size():shoff+uint64_t(shnum)*sizeof(Shdr);
    const uint64_t debugAbbrevOff=hasDebugInfo?alignUp(afterDebugLine,8):0;
    const uint64_t debugInfoOff=hasDebugInfo?alignUp(debugAbbrevOff+spec.debugAbbrev.size(),8):0;
    // v0.23.32-dev: fill in the addresses .debug_info wrote as zero. A unit's
    // low_pc is .text; a subprogram's its own function; a global's the segment
    // it was laid out in — all of which only exist in this function.
    std::vector<uint8_t> debugInfo=spec.debugInfo;
    if(hasDebugInfo){
        std::map<std::string,uint64_t> symVaddr;
        symVaddr[".text"]=kSharedTextVaddr;
        for(const auto& e:spec.exports)symVaddr[e.name]=kSharedTextVaddr+e.offset;
        for(const auto& g:spec.globals)symVaddr[g.name]=(g.kind==1?dataVaddr:(g.kind==3?rodataVaddr:bssVaddr))+g.offset;
        for(const auto& p:spec.debugInfoPatches){
            auto it=symVaddr.find(p.symbol);
            if(it==symVaddr.end())throw Error("internal error: .debug_info references a symbol the shared object does not define: "+p.symbol);
            dbgPatchAddress(debugInfo,p.offset,it->second+(uint64_t)p.addend);
        }
    }
    // v0.23.33-dev: and the ones .eh_frame wrote as zero, which are the same
    // question in a shorter form — a displacement from the field itself, so the
    // section's own address has to be known first. The header that lets an
    // unwinder find the table is built here too: one sorted row per FDE.
    const uint64_t afterDebugInfo=hasDebugInfo?debugInfoOff+debugInfo.size():afterDebugLine;
    const uint64_t ehFrameOff=hasEhFrame?alignUp(afterDebugInfo,8):0;
    const uint64_t ehFrameHdrOff=hasEhFrame?alignUp(ehFrameOff+spec.ehFrame.size(),8):0;
    std::vector<uint8_t> ehFrameBytes=spec.ehFrame,ehFrameHdr;
    if(hasEhFrame){
        std::map<std::string,uint64_t> symVaddr;
        symVaddr[".text"]=kSharedTextVaddr;
        for(const auto& e:spec.exports)symVaddr[e.name]=kSharedTextVaddr+e.offset;
        for(const auto& g:spec.globals)symVaddr[g.name]=(g.kind==1?dataVaddr:(g.kind==3?rodataVaddr:bssVaddr))+g.offset;
        for(const auto& p:spec.ehFramePatches){
            auto it=symVaddr.find(p.symbol);
            if(it==symVaddr.end())throw Error("internal error: .eh_frame references a symbol the shared object does not define: "+p.symbol);
            if(p.offset+4>ehFrameBytes.size())throw Error("internal error: .eh_frame address patch is out of bounds");
            const int64_t disp=(int64_t)(it->second+(uint64_t)p.addend)-(int64_t)(ehFrameOff+p.offset);
            if(disp<-2147483648ll||disp>2147483647ll)throw Error("internal error: .eh_frame displacement does not fit in 32 bits");
            for(int i=0;i<4;++i)ehFrameBytes[(size_t)p.offset+(size_t)i]=uint8_t((uint32_t)disp>>(8*i));
        }
        std::vector<std::pair<uint64_t,uint64_t>> table;
        for(const auto& f:spec.ehFrameFdes){auto it=symVaddr.find(f.first);if(it!=symVaddr.end())table.push_back({it->second,f.second});}
        std::sort(table.begin(),table.end());
        ehFrameHdr.push_back(1);                       // version
        ehFrameHdr.push_back(0x1b);                    // eh_frame_ptr: pcrel sdata4
        ehFrameHdr.push_back(0x03);                    // fde_count: udata4
        ehFrameHdr.push_back(0x3b);                    // table: datarel sdata4
        ehPut32(ehFrameHdr,(uint32_t)((int64_t)ehFrameOff-(int64_t)(ehFrameHdrOff+4)));
        ehPut32(ehFrameHdr,(uint32_t)table.size());
        for(const auto& e:table){
            ehPut32(ehFrameHdr,(uint32_t)((int64_t)e.first-(int64_t)ehFrameHdrOff));
            ehPut32(ehFrameHdr,(uint32_t)((int64_t)(ehFrameOff+e.second)-(int64_t)ehFrameHdrOff));
        }
    }

    // ---- program and section headers ---------------------------------------------------------
    Ehdr h{};initIdent(h,3);h.entry=0;h.phoff=sizeof(Ehdr);h.phentsize=sizeof(Phdr);h.phnum=(uint16_t)((spec.rodata.empty()?4:5)+(hasEhFrame?2:0));
    h.shoff=shoff;h.shentsize=sizeof(Shdr);h.shnum=shnum;h.shstrndx=S_SHSTR;
    Phdr p0{};p0.type=1;p0.flags=5;p0.offset=0;p0.vaddr=0;p0.paddr=0;p0.filesz=seg0End;p0.memsz=seg0End;p0.align=0x1000;
    Phdr pr{};pr.type=1;pr.flags=4;pr.offset=rodataVaddr;pr.vaddr=rodataVaddr;pr.paddr=rodataVaddr;pr.filesz=rodataSize;pr.memsz=rodataSize;pr.align=0x1000;
    Phdr p1{};p1.type=1;p1.flags=6;p1.offset=dataVaddr;p1.vaddr=dataVaddr;p1.paddr=dataVaddr;
    p1.filesz=relroEnd-dataVaddr;p1.memsz=(bssVaddr-dataVaddr)+spec.bssSize;p1.align=0x1000;
    Phdr p2{};p2.type=2;p2.flags=6;p2.offset=dynOff;p2.vaddr=dynOff;p2.paddr=dynOff;p2.filesz=dynSize;p2.memsz=dynSize;p2.align=8;
    Phdr p3{};p3.type=0x6474e552;p3.flags=4;p3.offset=relroVaddr;p3.vaddr=relroVaddr;p3.paddr=relroVaddr;p3.filesz=relroEnd-relroVaddr;p3.memsz=relroEnd-relroVaddr;p3.align=1;
    // v0.23.33-dev: the unwind table is read out of the running image, so it
    // rides in a PT_LOAD of its own past every other segment.
    Phdr p4{};if(hasEhFrame){p4.type=1;p4.flags=4;p4.offset=ehFrameOff;p4.vaddr=ehFrameOff;p4.paddr=ehFrameOff;p4.filesz=ehFrameHdrOff+ehFrameHdr.size()-ehFrameOff;p4.memsz=ehFrameHdrOff+ehFrameHdr.size()-ehFrameOff;p4.align=0x1000;}
    Phdr p5{};if(hasEhFrame){p5.type=0x6474e550u;p5.flags=4;p5.offset=ehFrameHdrOff;p5.vaddr=ehFrameHdrOff;p5.paddr=ehFrameHdrOff;p5.filesz=ehFrameHdr.size();p5.memsz=ehFrameHdr.size();p5.align=4;}
    std::vector<Shdr> sh(shnum);
    auto setSh=[&](uint16_t i,uint32_t type,uint64_t flags,uint64_t addr,uint64_t off,uint64_t size,uint32_t link,uint32_t info,uint64_t al,uint64_t es){
        Shdr& e=sh[i];e.name=shNameOff[i];e.type=type;e.flags=flags;e.addr=addr;e.offset=off;e.size=size;e.link=link;e.info=info;e.addralign=al;e.entsize=es;};
    setSh(S_TEXT,1,0x6,textVaddr,textOff,text.size(),0,0,4,0);
    setSh(S_PLT,1,0x6,pltOff,pltOff,pltSize,0,0,16,16);
    setSh(S_DYNSYM,11,0x2,dynsymOff,dynsymOff,dynsymSize,S_DYNSTR,1,8,sizeof(Sym));
    setSh(S_DYNSTR,3,0x2,dynstrOff,dynstrOff,dynstrSize,0,0,1,0);
    setSh(S_HASH,5,0x2,hashOff,hashOff,hashSize,S_DYNSYM,0,4,0);
    setSh(S_GNUHASH,0x6ffffff6,0x2,gnuHashOff,gnuHashOff,gnuHashSize,S_DYNSYM,0,8,0);
    setSh(S_RELADYN,4,0x2,relaDynOff,relaDynOff,relaDynSize,S_DYNSYM,0,8,sizeof(Rela));
    setSh(S_RELAPLT,4,0x2,relaPltOff,relaPltOff,relaPltSize,S_DYNSYM,0,8,sizeof(Rela));
    if(S_RODATA)setSh(S_RODATA,1,0x2,rodataVaddr,rodataVaddr,rodataSize,0,0,1,0);
    setSh(S_DATA,1,0x3,dataVaddr,dataVaddr,dataSize,0,0,8,0);
    setSh(S_GOTPLT,1,0x3,gotPltVaddr,gotPltVaddr,gotPltSize,0,0,8,0);
    setSh(S_GOT,1,0x3,gotVaddr,gotVaddr,gotSize,0,0,8,0);
    setSh(S_DYNAMIC,6,0x3,dynOff,dynOff,dynSize,S_DYNSTR,0,8,sizeof(Elf64Dyn));
    setSh(S_BSS,8,0x3,bssVaddr,relroEnd,spec.bssSize,0,0,8,0);
    if(hasInit)setSh(S_INITARR,1,0x3,initArrVaddr,initArrVaddr,initArrSize,0,0,8,0);
    setSh(S_SYMTAB,2,0,0,symOff,symSize,S_STRTAB,outSymbols.empty()?0u:1u,8,sizeof(Sym));
    setSh(S_STRTAB,3,0,0,strOff,st.strtab.size(),0,0,1,0);
    setSh(S_SHSTR,3,0,0,shstrOff,shstr.size(),0,0,1,0);
    if(hasDebugLine)setSh(S_DEBUGLINE,1,0,0,debugLineOff,spec.debugLine.size(),0,0,1,0);
    if(hasDebugInfo){setSh(S_DEBUGABBREV,1,0,0,debugAbbrevOff,spec.debugAbbrev.size(),0,0,1,0);
        setSh(S_DEBUGINFO,1,0,0,debugInfoOff,debugInfo.size(),0,0,1,0);}
    // v0.23.33-dev: SHF_ALLOC, because an unwinder reads both out of the loaded
    // image rather than out of the file — .eh_frame_hdr is what a debugger
    // binary-searches, and .eh_frame is what it lands on.
    if(hasEhFrame){setSh(S_EHFRAME,1,0x2,ehFrameOff,ehFrameOff,ehFrameBytes.size(),0,0,4,0);
        setSh(S_EHFRAMEHDR,1,0x2,ehFrameHdrOff,ehFrameHdrOff,ehFrameHdr.size(),0,0,4,0);}

    // ---- emit --------------------------------------------------------------------------------
    std::ofstream o(path,std::ios::binary);if(!o)throw Error("cannot create output: "+path);
    auto pad=[&](uint64_t target){auto pos=(uint64_t)o.tellp();if(pos>target)throw Error("internal ELF layout error");std::vector<char> z((size_t)(target-pos),0);if(!z.empty())o.write(z.data(),z.size());};
    o.write((char*)&h,sizeof h);o.write((char*)&p0,sizeof p0);if(!spec.rodata.empty())o.write((char*)&pr,sizeof pr);o.write((char*)&p1,sizeof p1);o.write((char*)&p2,sizeof p2);o.write((char*)&p3,sizeof p3);
    if(hasEhFrame){o.write((char*)&p4,sizeof p4);o.write((char*)&p5,sizeof p5);}
    pad(textOff);o.write((const char*)text.data(),(std::streamsize)text.size());
    pad(pltOff);if(pltSize)o.write((const char*)plt.data(),(std::streamsize)plt.size());
    pad(dynsymOff);o.write((const char*)dynsym.data(),(std::streamsize)dynsymSize);
    o.write(dynstr.data(),(std::streamsize)dynstr.size());
    pad(hashOff);o.write((const char*)hash.data(),(std::streamsize)hashSize);
    pad(gnuHashOff);o.write((const char*)gnuHash.data(),(std::streamsize)gnuHashSize);
    pad(relaDynOff);if(relaDynSize)o.write((const char*)relas.data(),(std::streamsize)relaDynSize);
    pad(relaPltOff);if(relaPltSize)o.write((const char*)relasPlt.data(),(std::streamsize)relaPltSize);
    pad(rodataVaddr);if(rodataSize)o.write((const char*)spec.rodata.data(),(std::streamsize)spec.rodata.size());
    pad(dataVaddr);if(dataSize)o.write((const char*)spec.data.data(),(std::streamsize)spec.data.size());
    if(hasInit){pad(initArrVaddr);uint64_t v=textVaddr+uint64_t(spec.initOffset);for(int k=0;k<8;++k)o.put((char)uint8_t(v>>(k*8)));}
    pad(gotPltVaddr);o.write((const char*)gotPlt.data(),(std::streamsize)gotPlt.size());
    pad(gotVaddr);if(gotSize)o.write((const char*)got.data(),(std::streamsize)got.size());
    pad(dynOff);o.write((const char*)dyn.data(),(std::streamsize)dynSize);
    pad(symOff);o.write((const char*)st.syms.data(),(std::streamsize)symSize);
    o.write(st.strtab.data(),(std::streamsize)st.strtab.size());o.write(shstr.data(),(std::streamsize)shstr.size());
    pad(shoff);o.write((const char*)sh.data(),(std::streamsize)(shnum*sizeof(Shdr)));
    if(hasDebugLine){pad(debugLineOff);o.write((const char*)spec.debugLine.data(),(std::streamsize)spec.debugLine.size());}
    if(hasDebugInfo){pad(debugAbbrevOff);o.write((const char*)spec.debugAbbrev.data(),(std::streamsize)spec.debugAbbrev.size());
        pad(debugInfoOff);o.write((const char*)debugInfo.data(),(std::streamsize)debugInfo.size());}
    if(hasEhFrame){pad(ehFrameOff);o.write((const char*)ehFrameBytes.data(),(std::streamsize)ehFrameBytes.size());
        pad(ehFrameHdrOff);o.write((const char*)ehFrameHdr.data(),(std::streamsize)ehFrameHdr.size());}
    if(!o)throw Error("failed writing shared object");
}

// Link one or more ET_REL *PIC* objects (produced by `build-obj --pic`) into one shared object.
// Symbols still undefined after the merge become cross-.so imports: functions through a PLT stub
// and JUMP_SLOT relocation, objects through a GOT slot and GLOB_DAT relocation.
void linkSharedObjects(const std::vector<std::string>& inputs,const std::string& output,
                       const std::string& sonameIn,const std::vector<std::string>& needed){
    if(inputs.empty())throw Error("link-so requires at least one input object");
    std::vector<uint8_t> mergedText,mergedData,mergedRodata;uint64_t mergedBss=0;
    struct Def{uint64_t off;uint32_t kind;uint64_t size;}; // 0 = .text, 1 = .data, 2 = .bss, 3 = .rodata
    std::map<std::string,Def> definitions;
    std::vector<LinkPending> pending;
    std::map<size_t,std::string> initNameByInput;
    // -g: one line program per input object, concatenated and raised to each
    // object's text address exactly as linkObjects does.
    std::vector<uint8_t> mergedDebugLine;
    std::vector<std::pair<uint64_t,uint64_t>> debugLineFixups;
    // v0.23.32-dev: the units themselves, merged the same way — one per object,
    // each address left for writeSharedObjectDyn, which knows the segment
    // addresses. A unit's low_pc addend is its object's offset in the text.
    std::vector<uint8_t> mergedDebugInfo,mergedDebugAbbrev;
    std::vector<DebugInfoBlob::Patch> debugInfoFixups;
    // v0.23.33-dev: the same question for the unwind table. Each input's FDEs
    // are taken apart into (function, range, CFI program) and rebuilt once the
    // shared object exists, because an FDE names its function by displacement
    // from itself and the writer is the first place that knows an address.
    std::vector<uint8_t> ehCie;
    struct EhEntry { std::string symbol; int64_t addend=0; uint64_t range=0; std::vector<uint8_t> cfi; size_t inputIndex=0; };
    std::vector<EhEntry> ehEntries;
    auto remapPrivateStringSymbol=[](const std::string& name,size_t inputIndex){
        const std::string direct="__aster_string_";
        const std::string got="__aster_gat___aster_string_";
        if(name.compare(0,got.size(),got)==0)return std::string("__aster_gat___aster_string_obj")+std::to_string(inputIndex)+"_"+name.substr(got.size());
        if(name.compare(0,direct.size(),direct)==0)return std::string("__aster_string_obj")+std::to_string(inputIndex)+"_"+name.substr(direct.size());
        return name;
    };
    for(size_t i=0;i<inputs.size();++i){const std::string& input=inputs[i];ParsedObject obj=parseObject(input);
        while(obj.dataAlign>1&&mergedData.size()%obj.dataAlign)mergedData.push_back(0);
        while(obj.bssAlign>1&&mergedBss%obj.bssAlign)++mergedBss;
        while(obj.rodataAlign>1&&mergedRodata.size()%obj.rodataAlign)mergedRodata.push_back(0);
        const uint64_t textBase=mergedText.size(),dataBase=mergedData.size(),bssBase=mergedBss,rodataBase=mergedRodata.size();
        for(const auto& s:obj.symbols){if((s.info>>4)!=1||s.name.empty()||s.shndx==0)continue;Def def{};
            if(s.shndx==(uint16_t)obj.textIndex){def.kind=0;def.off=textBase+s.value;def.size=s.size;}
            else if(obj.dataIndex>=0&&s.shndx==(uint16_t)obj.dataIndex){def.kind=1;def.off=dataBase+s.value;def.size=s.size;}
            else if(obj.bssIndex>=0&&s.shndx==(uint16_t)obj.bssIndex){def.kind=2;def.off=bssBase+s.value;def.size=s.size;}
            else if(obj.rodataIndex>=0&&s.shndx==(uint16_t)obj.rodataIndex){def.kind=3;def.off=rodataBase+s.value;def.size=s.size;}
            else throw Error(input+": global symbol in an unsupported section: "+s.name);
            if(s.name=="_start")throw Error(input+": a shared object must not define _start; build the object with --pic");
            std::string defName=remapPrivateStringSymbol(s.name,i);
            if(defName==kInitSymbol){defName=initNameByInput.empty()?std::string(kInitSymbol):std::string(kInitSymbol)+"$"+std::to_string(initNameByInput.size());initNameByInput[i]=defName;}
            auto inserted=definitions.emplace(defName,def);if(!inserted.second)throw Error("duplicate global symbol '"+defName+"' across input objects");
        }
        for(const auto& r:obj.relocs)pending.push_back({textBase+r.offset,remapPrivateStringSymbol(r.symbol,i),r.addend,r.type,i});
        if(!obj.debugLine.empty()){
            const uint64_t dlBase=mergedDebugLine.size();
            mergedDebugLine.insert(mergedDebugLine.end(),obj.debugLine.begin(),obj.debugLine.end());
            for(uint64_t site:obj.debugLinePatches)debugLineFixups.push_back({dlBase+site,textBase});
        }
        if(!obj.debugInfo.empty()){
            const uint64_t diBase=mergedDebugInfo.size();
            mergedDebugInfo.insert(mergedDebugInfo.end(),obj.debugInfo.begin(),obj.debugInfo.end());
            for(const auto& p:obj.debugInfoPatches)
                debugInfoFixups.push_back({diBase+p.offset,p.symbol,p.symbol==".text"?(int64_t)textBase:p.addend});
            if(mergedDebugAbbrev.empty())mergedDebugAbbrev=obj.debugAbbrev;
        }
        if(!obj.ehFrameFdes.empty()){
            if(ehCie.empty())ehCie=obj.ehFrameCie;
            for(const auto& f:obj.ehFrameFdes)ehEntries.push_back({remapPrivateStringSymbol(f.symbol,i),f.addend,f.range,f.cfi,i});
        }
        mergedText.insert(mergedText.end(),obj.text.begin(),obj.text.end());
        mergedData.insert(mergedData.end(),obj.data.begin(),obj.data.end());
        mergedRodata.insert(mergedRodata.end(),obj.rodata.begin(),obj.rodata.end());
        mergedBss+=obj.bssSize;
    }
    // Chain per-object run-time global initializers in input order (same rule as link-obj).
    uint64_t initEndOff=0;bool hasInitEnd=false;std::string firstInit;
    if(!initNameByInput.empty()){
        std::vector<size_t> initOrder;for(const auto& kv:initNameByInput)initOrder.push_back(kv.first);
        firstInit=initNameByInput[initOrder.front()];
        for(size_t oi=0;oi<initOrder.size();++oi){const std::string next=(oi+1<initOrder.size())?initNameByInput[initOrder[oi+1]]:std::string("__aster_init_end");
            for(auto& pr:pending)if(pr.inputIndex==initOrder[oi]&&pr.symbol==kInitNextSymbol)pr.symbol=next;}
        initEndOff=mergedText.size();for(int k=0;k<4;++k)mergedText.push_back(uint8_t(0xd65f03c0u>>(k*8)));hasInitEnd=true;
    }
    SoDynSpec spec;spec.soname=sonameIn.empty()?baseNameOf(output):sonameIn;spec.needed=needed;
    spec.data=mergedData;spec.rodata=mergedRodata;spec.bssSize=mergedBss;
    std::set<std::string> defFuncs,defObjs,impF,impO;
    for(const auto& d:definitions){
        if(d.second.kind==0){defFuncs.insert(d.first);spec.exports.push_back({d.first,d.second.off,d.second.size});}
        else{defObjs.insert(d.first);spec.globals.push_back({d.first,int(d.second.kind),d.second.off,d.second.size});}
    }
    if(hasInitEnd){defFuncs.insert("__aster_init_end");spec.exports.push_back({std::string("__aster_init_end"),initEndOff,4});}
    {auto it=definitions.find(firstInit);if(it!=definitions.end())spec.initOffset=(int64_t)it->second.off;}
    for(const auto& r:pending){
        if(r.type==283){
            if(r.symbol=="__aster_init_end")continue;
            if(defFuncs.count(r.symbol))continue;
            if(impF.insert(r.symbol).second)spec.importFuncs.push_back(r.symbol);
        } else {
            if(r.symbol.compare(0,12,"__aster_gat_")!=0)throw Error("PIC object relocation references unexpected symbol: "+r.symbol);
            const std::string src=r.symbol.substr(12);
            if(defObjs.count(src))continue;
            if(impO.insert(src).second)spec.importObjects.push_back(src);
        }
    }
    if(spec.exports.empty())throw Error("shared object must export at least one function");
    for(const auto& f:debugLineFixups)dbgPatchAddress(mergedDebugLine,f.first,kSharedTextVaddr+f.second);
    spec.debugLine=mergedDebugLine;
    // v0.23.32-dev: the same units, still holding zeroes; the addresses are
    // filled in where the segment addresses are decided.
    spec.debugInfo=mergedDebugInfo;spec.debugAbbrev=mergedDebugAbbrev;spec.debugInfoPatches=debugInfoFixups;
    // v0.23.33-dev: the unwind table, reassembled in the same way. The CIE
    // travels once; every FDE is rebuilt around its function's name, and the
    // displacement inside it stays a placeholder for the writer to fill.
    std::vector<uint8_t> mergedEhFrame;
    std::vector<EhFrameBlob::Patch> ehPatches;
    std::vector<std::pair<std::string,uint64_t>> ehFdes;
    if(!ehEntries.empty()){
        mergedEhFrame.insert(mergedEhFrame.end(),ehCie.begin(),ehCie.end());
        for(const auto& e:ehEntries){
            std::string sym=e.symbol;
            // A second object's initializer was renamed to keep the two apart,
            // so its FDE has to ask for the name the link actually defined.
            if(sym==kInitSymbol){auto it=initNameByInput.find(e.inputIndex);if(it!=initNameByInput.end())sym=it->second;}
            auto di=definitions.find(sym);
            if(di==definitions.end()||di->second.kind!=0)continue;   // not a function this link defined
            const uint64_t entryStart=mergedEhFrame.size();
            std::vector<uint8_t> body;
            ehPut32(body,uint32_t(entryStart+4));       // back to the CIE, which starts the section
            const uint64_t patchAt=mergedEhFrame.size()+4+body.size();
            ehPut32(body,0);                            // initial_location: a displacement, patched
            ehPut32(body,(uint32_t)e.range);
            body.insert(body.end(),e.cfi.begin(),e.cfi.end());
            while(body.size()%4u!=0)body.push_back(0x00);
            ehPut32(mergedEhFrame,(uint32_t)body.size());
            mergedEhFrame.insert(mergedEhFrame.end(),body.begin(),body.end());
            ehPatches.push_back({patchAt,sym,e.addend});
            ehFdes.push_back({sym,entryStart});
        }
        if(ehFdes.empty())mergedEhFrame.clear();
    }
    spec.ehFrame=mergedEhFrame;spec.ehFramePatches=ehPatches;spec.ehFrameFdes=ehFdes;
    writeSharedObjectDyn(output,mergedText,pending,spec);
    std::cout<<"Aster v"<<kVersion<<": linked "<<inputs.size()<<" AArch64 ET_REL PIC object(s) into shared object ("<<spec.exports.size()<<" exports, "
        <<spec.importFuncs.size()<<" PLT function imports, "<<spec.importObjects.size()<<" GOT data imports, "<<spec.needed.size()<<" DT_NEEDED, SONAME "<<spec.soname<<"): "<<output<<"\n";
}

// Link one or more ET_REL objects. base 0x400000 / etype 2 (ET_EXEC) is the v0.13.1/v0.14.0
// fixed-address behaviour; base 0 / etype 3 (ET_DYN) produces a static PIE whose virtual
// addresses equal file offsets and whose entry point is a plain offset from that base.
void linkObjects(const std::vector<std::string>& inputs,const std::string& output,uint64_t base=0x400000,uint16_t etype=2){
    if(base%0x1000)throw Error("internal error: link base must be page aligned");
    if(inputs.empty())throw Error("link-obj requires at least one input object");
    std::vector<uint8_t> mergedText,mergedData,mergedRodata;uint64_t mergedBss=0;
    // -g: each input object carries its own DWARF line program, so they are
    // concatenated (one unit per object) and every address in each is then
    // raised to that object's final text virtual address.
    std::vector<uint8_t> mergedDebugLine;
    std::vector<std::pair<uint64_t,uint64_t>> debugLineFixups; // (offset in mergedDebugLine, object text offset)
    // v0.23.32-dev: the same two ideas for .debug_info — concatenated units,
    // each address rewritten once the image has addresses.
    std::vector<uint8_t> mergedDebugInfo,mergedDebugAbbrev;
    std::vector<DebugInfoBlob::Patch> debugInfoFixups;
    // v0.23.33-dev: the unwind tables, which a link cannot simply concatenate —
    // an FDE says where its function is with a displacement from itself, so
    // every one has to be re-emitted once the image has addresses. The CIE
    // travels once; each FDE is rebuilt from its function's address and the CFI
    // program, which no address can change.
    std::vector<uint8_t> ehCie;
    struct EhEntry { std::string symbol; int64_t addend=0; uint64_t range=0; std::vector<uint8_t> cfi; size_t inputIndex=0; };
    std::vector<EhEntry> ehEntries;
    struct Def{uint64_t off;uint32_t kind;uint64_t size;}; // 0 = .text, 1 = .data, 2 = .bss, 3 = .rodata
    std::map<std::string,Def> definitions;
    std::vector<LinkPending> pending;uint64_t entryOffset=0;size_t startCount=0;uint64_t maxAlign=4;
    uint64_t maxDataAlign=4,maxBssAlign=4;
    uint64_t maxRodataAlign=1;
    std::map<size_t,std::string> initNameByInput;
    for(size_t i=0;i<inputs.size();++i){const std::string& input=inputs[i];ParsedObject obj=parseObject(input);
        while(obj.dataAlign>1&&mergedData.size()%obj.dataAlign)mergedData.push_back(0);
        while(obj.bssAlign>1&&mergedBss%obj.bssAlign)++mergedBss;
        while(obj.rodataAlign>1&&mergedRodata.size()%obj.rodataAlign)mergedRodata.push_back(0);
        uint64_t textBase=mergedText.size(),dataBase=mergedData.size(),bssBase=mergedBss,rodataBase=mergedRodata.size();
        for(const auto& s:obj.symbols){if((s.info>>4)!=1||s.name.empty()||s.shndx==0)continue;Def def{};
            if(s.shndx==(uint16_t)obj.textIndex){def.kind=0;def.off=textBase+s.value;def.size=s.size;}
            else if(obj.dataIndex>=0&&s.shndx==(uint16_t)obj.dataIndex){def.kind=1;def.off=dataBase+s.value;def.size=s.size;}
            else if(obj.bssIndex>=0&&s.shndx==(uint16_t)obj.bssIndex){def.kind=2;def.off=bssBase+s.value;def.size=s.size;}
            else if(obj.rodataIndex>=0&&s.shndx==(uint16_t)obj.rodataIndex){def.kind=3;def.off=rodataBase+s.value;def.size=s.size;}
            else throw Error(input+": global symbol in an unsupported section: "+s.name);
            std::string defName=s.name;
            if(defName==kInitSymbol){defName=initNameByInput.empty()?std::string(kInitSymbol):std::string(kInitSymbol)+"$"+std::to_string(initNameByInput.size());initNameByInput[i]=defName;}
            auto inserted=definitions.emplace(defName,def);if(!inserted.second)throw Error("duplicate global symbol '"+defName+"' across input objects");
            if(s.name=="_start"){++startCount;entryOffset=textBase+s.value;}
        }
        for(const auto& r:obj.relocs)pending.push_back({textBase+r.offset,r.symbol,r.addend,r.type,i});
        if(!obj.debugLine.empty()){
            const uint64_t dlBase=mergedDebugLine.size();
            mergedDebugLine.insert(mergedDebugLine.end(),obj.debugLine.begin(),obj.debugLine.end());
            for(uint64_t site:obj.debugLinePatches)debugLineFixups.push_back({dlBase+site,textBase});
        }
        // v0.23.32-dev: one unit per object, concatenated like the line tables.
        // The abbreviation table is the same bytes for every object, so the
        // first one's copy serves the whole image. A unit's low_pc was written
        // against its own object's .text, so its addend becomes that object's
        // offset in the merged text — the same raising the line table gets.
        if(!obj.debugInfo.empty()){
            const uint64_t diBase=mergedDebugInfo.size();
            mergedDebugInfo.insert(mergedDebugInfo.end(),obj.debugInfo.begin(),obj.debugInfo.end());
            for(const auto& p:obj.debugInfoPatches)
                debugInfoFixups.push_back({diBase+p.offset,p.symbol,p.symbol==".text"?(int64_t)textBase:p.addend});
            if(mergedDebugAbbrev.empty())mergedDebugAbbrev=obj.debugAbbrev;
        }
        if(!obj.ehFrameFdes.empty()){
            if(ehCie.empty())ehCie=obj.ehFrameCie;
            for(const auto& f:obj.ehFrameFdes)ehEntries.push_back({f.symbol,f.addend,f.range,f.cfi,i});
        }
        mergedText.insert(mergedText.end(),obj.text.begin(),obj.text.end());
        mergedData.insert(mergedData.end(),obj.data.begin(),obj.data.end());
        mergedRodata.insert(mergedRodata.end(),obj.rodata.begin(),obj.rodata.end());
        mergedBss+=obj.bssSize;
        if(obj.dataAlign>maxAlign)maxAlign=obj.dataAlign;
        if(obj.bssAlign>maxAlign)maxAlign=obj.bssAlign;
        if(obj.dataAlign>maxDataAlign)maxDataAlign=obj.dataAlign;
        if(obj.bssAlign>maxBssAlign)maxBssAlign=obj.bssAlign;
        if(obj.rodataAlign>maxRodataAlign)maxRodataAlign=obj.rodataAlign;
    }
    // Chain per-object global initializers in input order; the last one returns to a synthesized RET.
    uint64_t initEndOff=0;bool hasInitEnd=false;
    if(!initNameByInput.empty()){
        std::vector<size_t> initOrder;for(const auto& kv:initNameByInput)initOrder.push_back(kv.first);
        for(size_t oi=0;oi<initOrder.size();++oi){const std::string next=(oi+1<initOrder.size())?initNameByInput[initOrder[oi+1]]:std::string("__aster_init_end");
            for(auto& pr:pending)if(pr.inputIndex==initOrder[oi]&&pr.symbol==kInitNextSymbol)pr.symbol=next;}
        initEndOff=mergedText.size();for(int k=0;k<4;++k)mergedText.push_back(uint8_t(0xd65f03c0u>>(k*8)));hasInitEnd=true; // RET
    }
    while(maxAlign>1&&mergedData.size()%maxAlign)mergedData.push_back(0);
    if(startCount==0) throw Error("no input object defines global _start");
    if(startCount>1) throw Error("multiple input objects define global _start");
    const uint64_t textVaddr=base+0x1000;
    const bool hasRodata=!mergedRodata.empty();
    const uint64_t rodataFileOff=hasRodata?alignUp(0x1000+mergedText.size(),0x1000):0;
    const uint64_t rodataVaddr=hasRodata?base+rodataFileOff:0;
    const uint64_t afterRodata=hasRodata?rodataFileOff+mergedRodata.size():0x1000+mergedText.size();
    uint64_t dataVaddr=0,bssVaddr=0;
    if(!mergedData.empty()||mergedBss>0){uint64_t dataFileOff=alignUp(afterRodata,0x1000);dataVaddr=base+dataFileOff;bssVaddr=dataVaddr+mergedData.size();}
    std::map<std::string,uint64_t> symbolVaddr;std::map<std::string,int> symbolKind;
    for(const auto& d:definitions){uint64_t a=d.second.kind==0?textVaddr+d.second.off:d.second.kind==1?dataVaddr+d.second.off:d.second.kind==3?rodataVaddr+d.second.off:bssVaddr+d.second.off;symbolVaddr[d.first]=a;symbolKind[d.first]=int(d.second.kind);}
    if(hasInitEnd){symbolVaddr["__aster_init_end"]=textVaddr+initEndOff;symbolKind["__aster_init_end"]=0;}
    // A unit's low_pc is written against .text, so .text needs an address here
    // too — the section symbol the object used is not a definition the link
    // carries, but its address is simply where this image's text begins.
    symbolVaddr[".text"]=textVaddr;
    // A static image (ET_EXEC at a fixed base, or a static PIE whose text is
    // PC-relative throughout) may address a function directly — this is what
    // makes `let fp: ptr = f; f(…)` work outside a shared object.
    resolveRelocations(mergedText,pending,symbolVaddr,symbolKind,textVaddr,/*funcAddrDirect=*/true);
    // Now that the image has addresses, fill in the ones the line programs were
    // written with placeholders for. A unit's rows are relative to its own text,
    // so each patch site gets the virtual address that object's text starts at.
    for(const auto& f:debugLineFixups)dbgPatchAddress(mergedDebugLine,f.first,textVaddr+f.second);
    // v0.23.32-dev: and the ones .debug_info wrote as zero. Unlike the line
    // table each of these names a symbol — a function, a global, or .text —
    // so it is resolved here rather than raised by a text base.
    for(const auto& p:debugInfoFixups){
        auto it=symbolVaddr.find(p.symbol);
        if(it==symbolVaddr.end())throw Error("internal error: .debug_info references a symbol the link did not define: "+p.symbol);
        dbgPatchAddress(mergedDebugInfo,p.offset,it->second+(uint64_t)p.addend);
    }
    // v0.23.33-dev: and the unwind table, rebuilt now that every function has
    // an address. A CFI program travels unchanged; only the CIE pointer and the
    // function's own displacement are written here.
    std::vector<uint8_t> mergedEhFrame;
    std::vector<std::pair<uint64_t,uint64_t>> ehFramePatches,ehFrameTable; // (field offset, address), (function start, FDE offset)
    if(!ehEntries.empty()){
        mergedEhFrame.insert(mergedEhFrame.end(),ehCie.begin(),ehCie.end());
        for(const auto& e:ehEntries){
            std::string sym=e.symbol;
            // A second object's initializer is renamed to keep the two apart,
            // so its FDE has to ask for the name the link actually defined.
            if(sym==kInitSymbol){auto it=initNameByInput.find(e.inputIndex);if(it!=initNameByInput.end())sym=it->second;}
            auto si=symbolVaddr.find(sym);
            if(si==symbolVaddr.end())continue;          // a function the link dropped: nothing to describe
            const uint64_t target=si->second+(uint64_t)e.addend;
            const uint64_t entryStart=mergedEhFrame.size();
            std::vector<uint8_t> body;
            ehPut32(body,uint32_t(entryStart+4));       // back to the CIE, which starts the section
            const uint64_t patchAt=mergedEhFrame.size()+4+body.size();
            ehPut32(body,0);                            // initial_location: a displacement, patched
            ehPut32(body,(uint32_t)e.range);
            body.insert(body.end(),e.cfi.begin(),e.cfi.end());
            while(body.size()%4u!=0)body.push_back(0x00);
            ehPut32(mergedEhFrame,(uint32_t)body.size());
            mergedEhFrame.insert(mergedEhFrame.end(),body.begin(),body.end());
            ehFramePatches.push_back({patchAt,target});
            ehFrameTable.push_back({target,entryStart});
        }
        if(ehFrameTable.empty())mergedEhFrame.clear();
    }
    // Source-level symbols for the linked image: every defined function and global with the name it
    // has in the source. The entry function is emitted under its source name `main` (the object
    // files carry it as `_start`), and the conventional ELF entry alias `_start` is kept next to it.
    // Synthetic internal routines (__aster_init, __aster_init_next, __aster_init_end) are not
    // source-level names and are left out of the source-level table.
    std::vector<OutSym> outSymbols;outSymbols.reserve(definitions.size()+1);
    for(const auto& d:definitions){
        if(d.first.compare(0,8,"__aster_")==0)continue;
        outSymbols.push_back({d.first,int(d.second.kind),d.second.off,d.second.size});
        if(d.first=="_start")outSymbols.push_back({std::string("main"),int(d.second.kind),d.second.off,d.second.size});
    }
    writeElfBytes(output,mergedText,entryOffset,mergedData,mergedBss,base,etype,outSymbols,maxDataAlign,maxBssAlign,mergedRodata,maxRodataAlign,mergedDebugLine,mergedDebugInfo,mergedDebugAbbrev,mergedEhFrame,ehFramePatches,ehFrameTable);
    size_t callCount=0;for(const auto& r:pending)if(r.type==283)++callCount;
    std::cout<<"Aster v"<<kVersion<<": linked "<<inputs.size()<<" AArch64 ET_REL object(s), applied "<<pending.size()<<" relocation(s) ("<<callCount<<" CALL26) to ELF64 "<<(etype==2?"ET_EXEC":"ET_DYN")<<" ("<<mergedText.size()<<" text bytes, "<<mergedRodata.size()<<" rodata bytes, "<<mergedData.size()<<" data bytes, "<<mergedBss<<" bss bytes): "<<output<<"\n";
}
}
const char* kUsage="Aster bootstrap compiler v" ASTER_VERSION_STRING "\n"
    "Usage: aster build-elf|build-pie [-g] <source.ast> -o <output>\n"
    "       aster build-obj [--pic] [-g] <source.ast> -o <output.o>\n"
    "       aster build-so  [--soname NAME] [--needed LIB] <source.ast> -o <output.so>\n"
    "       aster link-obj|link-pie <input.o> [input2.o ...] -o <output>\n"
    "       aster link-so   [--soname NAME] [--needed LIB] <input.o> [input2.o ...] -o <output.so>\n"
    "       aster keygen [--dir DIR] [--bits 2048] [--force]\n"
    "       aster verify-apk <app.apk>\n"
    "  build-elf  fixed-address AArch64 ET_EXEC executable (link base 0x400000)\n"
    "  build-pie  static PIE: AArch64 ET_DYN executable, no interpreter (link base 0)\n"
    "  build-obj  relocatable AArch64 ET_REL object (--pic: position-independent, for link-so)\n"
    "  build-so   shared object: AArch64 ET_DYN with SysV DT_HASH + GNU DT_GNU_HASH (link base 0)\n"
    "  link-obj   link ET_REL objects into a fixed-address ET_EXEC\n"
    "  link-pie   link ET_REL objects into a static PIE (ET_DYN)\n"
    "  link-so    link ET_REL PIC objects into one shared object (cross-.so imports via PLT/GOT)\n"
    "  build-apk  <input.so|input.ast> -o <app.apk> --package PKG [--libname NAME] [--abi ABI]\n"
    "            [--label TXT] [--string NAME=VALUE] [--min-sdk N] [--target-sdk N] [--version-code N] [--version-name T]\n"
    "            [--emit-so PATH] (keep the .so compiled from .ast input)\n"
    "            [--sign-mode debug|release] [--keystore KEY] [--cert CRT]\n"
    "            [--keystore-dir DIR] [--key-bits N] [--no-verify]\n"
    "  keygen     generate the project's RSA debug key + self-signed certificate\n"
    "  verify-apk check an APK's own v1 + v2 signatures (structure, digests, certificate)\n"
    "  build-apk signs with one of two keys, never with a key baked into aster:\n"
    "    --sign-mode debug   (default) the project's own key in <keystore-dir>/.aster/\n"
    "                        debug.key.pem + debug.crt.pem, generated on first use\n"
    "    --sign-mode release your key: --keystore <key.pem> --cert <cert.pem>, both required;\n"
    "                        without them the build stops instead of signing with a debug key\n"
    "    --keystore-dir DIR  where debug keys live (default: $ASTER_KEY_DIR, else the nearest\n"
    "                        ancestor of the working directory holding .git/ or .aster/, else cwd)\n"
    "    --key-bits N        size of a debug key generated on first use: 2048/3072/4096\n"
    "  -g / --debug-line  emit DWARF v4 .debug_line and .debug_info sections so a debugger\n"
    "                     can map an instruction back to the .ast line that produced it and\n"
    "                     print variables by name (build-elf/build-pie/build-obj/build-so;\n"
    "                     a link carries whatever its input objects have). Off by default,\n"
    "                     and an ordinary build emits byte-for-byte what it always did.\n"
    "  --label TXT is stored once, as string/app_name in resources.arsc, and android:label\n"
"    points at it; --string NAME=VALUE (repeatable) adds further string resources. The\n"
"    launcher icon is drawable/ic_launcher. Every resource id comes from the table\n"
"    itself, so the manifest cannot name one the table does not hold.\n"
"  Keys are read as PEM or DER: PKCS#8 or PKCS#1 private keys (unencrypted) and X.509\n"
    "  certificates, so anything openssl/keytool wrote can be used directly.\n"
    "  build-apk re-verifies the APK in memory before writing it (--no-verify skips that);\n"
    "  by default every APK is v1 + v2 dual-signed."
    "  --soname NAME   DT_SONAME for the shared object (default: the output file name);\n"
    "                 for build-apk with .ast input, the library's DT_SONAME\n"
"  --bounds-check  trap on out-of-bounds array indexes at run time (off by default):\n"
"                 every dynamic index into a fixed-size array is compared against the\n"
"                 array's length and raises BRK #1 (SIGTRAP) when it is out of range.\n"
"                 Constant indexes are still rejected at compile time either way.\n"
"  @embed(\"PATH\")   the address of a file's bytes, which the compiler reads and puts\n"
"                 in rodata; @embed_len(\"PATH\") is how many bytes there are. PATH is\n"
"                 relative to the source file's own directory, or to --embed-dir DIR\n"
"                 when given. The same file embedded twice is embedded once.\n"
"  include \"PATH\"; another file's declarations, brought into this one. PATH is\n"
"                 relative to the file that writes it, or to --include-dir DIR.\n"
"                 Declarations only: a body and an initializer stay in the file\n"
"                 that owns them, so the declaration cannot drift from it.\n"
    "  --needed LIB    add DT_NEEDED LIB (repeatable) so the loader loads that .so first\n"
    "  build-apk emits a self-contained, v1 + v2 dual-signed NativeActivity APK with NO external\n"
    "  toolchain (aapt/d8/jarsigner/keytool/apksigner are not invoked); --libname defaults to the\n"
    "  output file base name; the v2 signature lives in an APK Signing Block (P2.1)\n"
    "  build-apk accepts .ast directly (compiled with the build-so pipeline first) — the\n"
    "    .so remains a first-class artifact: build-so it yourself, or pass --emit-so\n";
// ===================== Aster APK packager (Phase 1) =====================
// Self-contained APK v1 (JAR) signing for NativeActivity apps built by Aster.
// No external toolchain (aapt / d8 / jarsigner / keytool / openssl) is invoked:
// every byte of the APK is emitted by hand below.
// Modules: CRC32, SHA-256, bignum mod-exp (Knuth Algo D), RSA PKCS#1 v1.5,
//          DER + PKCS#7 SignedData, store-method ZIP, binary AXML manifest.

static inline uint32_t rotr(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

static std::string b64(const std::vector<uint8_t>& d) {
    static const char* t = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string o;
    o.reserve((d.size() + 2) / 3 * 4);
    for (size_t i = 0; i < d.size(); i += 3) {
        // A trailing group of one or two bytes still has to be emitted; dropping
        // it silently would truncate the DER (and only show up when something
        // else tries to read the file back).
        const bool has1 = i + 1 < d.size(), has2 = i + 2 < d.size();
        const uint32_t v = (uint32_t)d[i] << 16
                         | (has1 ? (uint32_t)d[i + 1] << 8 : 0u)
                         | (has2 ? (uint32_t)d[i + 2]      : 0u);
        o.push_back(t[(v >> 18) & 63]);
        o.push_back(t[(v >> 12) & 63]);
        o.push_back(has1 ? t[(v >> 6) & 63] : '=');
        o.push_back(has2 ? t[v & 63] : '=');
    }
    return o;
}
static std::vector<uint8_t> concat(const std::vector<uint8_t>& a, const std::vector<uint8_t>& b) {
    std::vector<uint8_t> o; o.reserve(a.size() + b.size());
    o.insert(o.end(), a.begin(), a.end()); o.insert(o.end(), b.begin(), b.end()); return o;
}

// ---------------------------------------------------------------- CRC32
static uint32_t crc32(const uint8_t* p, size_t n) {
    static uint32_t tab[256]; static bool init = false;
    if (!init) {
        for (uint32_t i = 0; i < 256; ++i) { uint32_t c = i; for (int k = 0; k < 8; ++k) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1); tab[i] = c; }
        init = true;
    }
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; ++i) c = tab[(c ^ p[i]) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

// ---------------------------------------------------------------- SHA-256
struct SHA256 {
    uint32_t h[8] = {0x6a09e667u,0xbb67ae85u,0x3c6ef372u,0xa54ff53au,0x510e527fu,0x9b05688cu,0x1f83d9abu,0x5be0cd19u};
    uint64_t len = 0; uint8_t buf[64]; int blen = 0;
    void block() {
        static const uint32_t K[64] = {
            0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
            0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
            0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
            0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
            0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
            0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
            0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
            0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
        uint32_t w[64];
        auto rd = [&](int i) -> uint32_t { return ((uint32_t)buf[i*4]<<24)|((uint32_t)buf[i*4+1]<<16)|((uint32_t)buf[i*4+2]<<8)|buf[i*4+3]; };
        for (int i = 0; i < 16; ++i) w[i] = rd(i);
        for (int i = 16; i < 64; ++i) { uint32_t s0=rotr(w[i-15],7)^rotr(w[i-15],18)^(w[i-15]>>3); uint32_t s1=rotr(w[i-2],17)^rotr(w[i-2],19)^(w[i-2]>>10); w[i]=w[i-16]+s0+w[i-7]+s1; }
        uint32_t a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],hh=h[7];
        for (int i = 0; i < 64; ++i) {
            uint32_t S1=rotr(e,6)^rotr(e,11)^rotr(e,25); uint32_t ch=(e&f)^((~e)&g); uint32_t t1=hh+S1+ch+K[i]+w[i];
            uint32_t S0=rotr(a,2)^rotr(a,13)^rotr(a,22); uint32_t maj=(a&b)^(a&c)^(b&c); uint32_t t2=S0+maj;
            hh=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2;
        }
        h[0]+=a;h[1]+=b;h[2]+=c;h[3]+=d;h[4]+=e;h[5]+=f;h[6]+=g;h[7]+=hh;
    }
    void upd(const uint8_t* p, size_t n) {
        len += n;
        while (n--) { buf[blen++] = *p++; if (blen == 64) { block(); blen = 0; } }
    }
    std::vector<uint8_t> fin() {
        uint64_t bits = len * 8; uint8_t pad = (len % 64 < 56) ? 56 - (uint8_t)(len % 64) : 120 - (uint8_t)(len % 64);
        uint8_t z = 0x80; upd(&z, 1); uint8_t zero = 0; for (uint8_t i = 0; i < pad - 1; ++i) upd(&zero, 1);
        for (int i = 7; i >= 0; --i) { uint8_t b = (bits >> (i*8)) & 0xFF; upd(&b, 1); }
        std::vector<uint8_t> o;
        for (int i = 0; i < 8; ++i) for (int j = 3; j >= 0; --j) o.push_back((h[i] >> (j*8)) & 0xFF);
        return o;
    }
};

// ---------------------------------------------------------------- BigInt (base 2^32, LE)
struct Big {
    std::vector<uint32_t> v;
    Big() { v = {0}; }
    Big(std::vector<uint32_t> w) : v(std::move(w)) { trim(); }
    void trim() { while (v.size() > 1 && v.back() == 0) v.pop_back(); if (v.empty()) v = {0}; }
    static Big fromBE(const uint8_t* p, size_t n) {
        std::vector<uint32_t> w((n + 3) / 4, 0);
        for (size_t i = 0; i < n; ++i) w[(n - 1 - i) / 4] |= (uint32_t)p[i] << (8 * ((n - 1 - i) % 4));
        Big b; b.v = w; b.trim(); return b;
    }
    std::vector<uint8_t> toBE() const {
        size_t n = v.size() * 4; std::vector<uint8_t> o(n, 0);
        for (size_t i = 0; i < n; ++i) o[n - 1 - i] = (v[i / 4] >> (8 * (i % 4))) & 0xFF;
        size_t z = 0; while (z < o.size() - 1 && o[z] == 0) ++z;
        return std::vector<uint8_t>(o.begin() + z, o.end());
    }
};
static int cmp(const Big& a, const Big& b) {
    if (a.v.size() != b.v.size()) return a.v.size() < b.v.size() ? -1 : 1;
    for (int i = (int)a.v.size() - 1; i >= 0; --i) if (a.v[i] != b.v[i]) return a.v[i] < b.v[i] ? -1 : 1;
    return 0;
}
[[maybe_unused]] static Big add(const Big& a, const Big& b) {
    std::vector<uint32_t> w; uint64_t c = 0; size_t n = std::max(a.v.size(), b.v.size());
    for (size_t i = 0; i < n || c; ++i) { uint64_t s = c + (i < a.v.size()?a.v[i]:0) + (i < b.v.size()?b.v[i]:0); w.push_back((uint32_t)s); c = s >> 32; }
    Big r; r.v = w; r.trim(); return r;
}
[[maybe_unused]] static Big sub(const Big& a, const Big& b) {
    std::vector<uint32_t> w; int64_t c = 0;
    for (size_t i = 0; i < a.v.size(); ++i) { int64_t s = (int64_t)a.v[i] - (i < b.v.size()?(int64_t)b.v[i]:0) - c; if (s < 0) { s += (1LL<<32); c = 1; } else c = 0; w.push_back((uint32_t)s); }
    Big r; r.v = w; r.trim(); return r;
}
static Big mul(const Big& a, const Big& b) {
    std::vector<uint32_t> w(a.v.size() + b.v.size(), 0);
    for (size_t i = 0; i < a.v.size(); ++i) { uint64_t c = 0; for (size_t j = 0; j < b.v.size() || c; ++j) { uint64_t s = (uint64_t)w[i+j] + (uint64_t)a.v[i] * (j < b.v.size()?b.v[j]:0) + c; w[i+j]=(uint32_t)s; c = s >> 32; } }
    Big r; r.v = w; r.trim(); return r;
}
// Knuth Algorithm D (base 2^32)
static std::pair<Big,Big> divmod(const Big& A, const Big& B) {
    if (cmp(B, Big()) == 0) return {Big(), Big()};
    if (cmp(A, B) < 0) return {Big(), A};
    size_t n = B.v.size(), m = A.v.size() - n;
    uint32_t shift = 0; { uint32_t hi = B.v.back(); while (!(hi & 0x80000000u)) { hi <<= 1; ++shift; } }
    auto shl = [&](const Big& x) -> Big {
        std::vector<uint32_t> w; w.reserve(x.v.size() + 1);
        uint64_t c = 0;
        for (size_t i = 0; i < x.v.size(); ++i) { uint64_t s = c + ((uint64_t)x.v[i] << shift); w.push_back((uint32_t)s); c = s >> 32; }
        w.push_back((uint32_t)c);
        Big r; r.v = w; r.trim(); return r;
    };
    Big u = shl(A), v = shl(B);
    u.v.push_back(0);
    std::vector<uint32_t> q(m + 1, 0);
    for (int j = (int)m; j >= 0; --j) {
        uint64_t num = ((uint64_t)u.v[j + n] << 32) | u.v[j + n - 1];
        uint64_t den = v.v[n - 1];
        uint64_t qhat = num / den, rhat = num % den;
        if (qhat >= (1ULL << 32)) { qhat = (1ULL << 32) - 1; rhat = num - qhat * den; }
        while (qhat * v.v[n - 2] > ((rhat << 32) | u.v[j + n - 2])) { --qhat; rhat += den; if (rhat >= (1ULL << 32)) break; }
        int64_t borrow = 0; uint64_t carry = 0;
        for (size_t i = 0; i < n; ++i) {
            uint64_t p = qhat * v.v[i] + carry; carry = p >> 32;
            int64_t subv = (int64_t)u.v[j + i] - (int64_t)(p & 0xFFFFFFFFu) - borrow;
            if (subv < 0) { subv += (1LL<<32); borrow = 1; } else borrow = 0;
            u.v[j + i] = (uint32_t)subv;
        }
        int64_t sb = (int64_t)u.v[j + n] - (int64_t)carry - borrow; u.v[j + n] = (uint32_t)sb;
        if (sb < 0) { --qhat; uint64_t c2 = 0; for (size_t i = 0; i < n; ++i) { c2 += (uint64_t)u.v[j + i] + v.v[i]; u.v[j + i] = (uint32_t)c2; c2 >>= 32; } u.v[j + n] += (uint32_t)c2; }
        q[j] = (uint32_t)qhat;
    }
    std::vector<uint32_t> rlimbs(n, 0); for (size_t i = 0; i < n; ++i) rlimbs[i] = u.v[i];
    std::vector<uint32_t> w = rlimbs;
    for (size_t i = 0; i < w.size(); ++i) {
        uint32_t low = w[i] >> shift;
        uint32_t fromHigh = (i + 1 < w.size()) ? (w[i + 1] & ((1u << shift) - 1)) : 0;
        w[i] = low | (fromHigh << (32 - shift));
    }
    Big r; r.v = w; r.trim();
    std::vector<uint32_t> qw(q.begin(), q.end()); Big qq; qq.v = qw; qq.trim();
    return {qq, r};
}
static Big mod(const Big& a, const Big& m) { return divmod(a, m).second; }
// Halving a nonnegative BigInt. This is only "divide by two", but modExp does
// it once per exponent bit, so it sits in the hot path of every RSA operation
// and of prime search: going through Knuth Algorithm D here costs more than
// the modular multiply it is paired with.
static Big halve(const Big& a) {
    std::vector<uint32_t> w(a.v.size(), 0);
    for (size_t i = 0; i + 1 < a.v.size(); ++i) w[i] = (a.v[i] >> 1) | (a.v[i + 1] << 31);
    w[a.v.size() - 1] = a.v[a.v.size() - 1] >> 1;
    Big r; r.v = w; r.trim(); return r;
}
static Big modExp(const Big& base, const Big& exp, const Big& m) {
    Big result; result.v = {1}; result.trim(); Big b = base, e = exp;
    while (cmp(e, Big()) > 0) {
        if (e.v[0] & 1) result = mod(mul(result, b), m);
        e = halve(e);
        if (cmp(e, Big()) > 0) b = mod(mul(b, b), m);
    }
    return result;
}
// ---------------------------------------------------------------- signing keys
// Up to v0.23.3 every APK Aster produced was signed with one RSA-2048 key
// compiled into the binary, so all Aster-built APKs in the world shared a
// signature and any Aster user could sign a replacement for anybody's app.
// From v0.23.4 the key is data, not a constant: it is either loaded from a
// developer-supplied PEM/DER file (release) or generated once and cached per
// project (debug). Nothing downstream is allowed to assume a particular key.
struct SigningKey {
    // PKCS#1 RSAPrivateKey fields, big-endian, minimal width.
    std::vector<uint8_t> n, e, d, p, q, dp, dq, qinv;
    std::vector<uint8_t> certDER;    // X.509 certificate carrying the public key
    std::vector<uint8_t> spki;       // SubjectPublicKeyInfo lifted out of certDER
    std::vector<uint8_t> serial;     // certificate serialNumber, for PKCS#7 issuerAndSerialNumber
    std::vector<uint8_t> issuerDER;  // certificate issuer Name, same purpose
    std::string source;              // where it came from, for diagnostics
};

static Big bigFromBE(const std::vector<uint8_t>& b) { return Big::fromBE(b.data(), b.size()); }
// Render to exactly k bytes, left-padding. toBE() strips leading zero bytes,
// which is right for a minimal integer encoding but wrong wherever the width
// is part of the format (PKCS#1 block size, signature length).
static std::vector<uint8_t> bigToFixedBE(const Big& a, size_t k) {
    std::vector<uint8_t> s = a.toBE();
    if (s.size() > k) throw Error("internal: integer wider than " + std::to_string(k) + " bytes");
    if (s.size() < k) s.insert(s.begin(), k - s.size(), 0x00);
    return s;
}

// DigestInfo prefix for SHA-256 (PKCS#1 v1.5); shared by signing and verifying
// so the two can never drift apart.
static const uint8_t kSha256DigestInfo[] = {
    0x30,0x31,0x30,0x0d,0x06,0x09,0x60,0x86,0x48,0x01,0x65,0x03,0x04,0x02,0x01,0x05,0x00,0x04,0x20
};

// ---------------------------------------------------------------- RSA PKCS#1 v1.5 sign (private exponent D)
static std::vector<uint8_t> rsaSign(const std::vector<uint8_t>& hash, const SigningKey& key) {
    Big N = bigFromBE(key.n);
    Big D = bigFromBE(key.d);
    size_t k = N.toBE().size();
    size_t tlen = sizeof(kSha256DigestInfo) + hash.size();
    if (k < tlen + 11) throw Error("signing key is too small for a PKCS#1 v1.5 SHA-256 signature");
    std::vector<uint8_t> em(k, 0xFF);
    em[0] = 0x00; em[1] = 0x01; em[k - tlen - 1] = 0x00;
    size_t p = k - tlen;
    memcpy(&em[p], kSha256DigestInfo, sizeof(kSha256DigestInfo));
    memcpy(&em[p + sizeof(kSha256DigestInfo)], hash.data(), hash.size());
    Big mm = Big::fromBE(em.data(), em.size());
    Big s = modExp(mm, D, N);
    std::vector<uint8_t> sig = s.toBE();
    // PKCS#1 v1.5 signatures are fixed-width: exactly k (the modulus size in
    // bytes), left zero-padded. A bare BigInt rendering strips leading zero
    // bytes, so whenever the signature integer's top byte(s) are zero (~1/256
    // of all signatures) the embedded signature came out shorter than the
    // modulus and every PKCS#7 verifier (openssl, Android's package verifier)
    // rejects the APK with "wrong signature length". Pad to k.
    if (sig.size() < k) sig.insert(sig.begin(), k - sig.size(), 0x00);
    return sig;
}

// ---------------------------------------------------------------- RSA PKCS#1 v1.5 verify (public exponent)
// Recomputes the whole EMSA-PKCS1-v1_5 block from the hash and compares, rather
// than only looking for the digest at the end: a verifier that tolerates a
// malformed padding block accepts forgeries.
static bool rsaVerify(const std::vector<uint8_t>& hash, const std::vector<uint8_t>& sig,
                      const std::vector<uint8_t>& nBytes, const std::vector<uint8_t>& eBytes) {
    if (nBytes.empty() || eBytes.empty()) return false;
    Big N = bigFromBE(nBytes), E = bigFromBE(eBytes);
    const size_t k = N.toBE().size();
    if (sig.size() != k) return false;                 // a v1.5 signature is exactly k bytes
    if (cmp(bigFromBE(sig), N) >= 0) return false;     // s must be a residue mod n
    const size_t tlen = sizeof(kSha256DigestInfo) + hash.size();
    if (k < tlen + 11) return false;
    std::vector<uint8_t> want(k, 0xFF);
    want[0] = 0x00; want[1] = 0x01; want[k - tlen - 1] = 0x00;
    size_t p = k - tlen;
    memcpy(&want[p], kSha256DigestInfo, sizeof(kSha256DigestInfo));
    memcpy(&want[p + sizeof(kSha256DigestInfo)], hash.data(), hash.size());
    const std::vector<uint8_t> got = bigToFixedBE(modExp(bigFromBE(sig), E, N), k);
    uint8_t diff = 0;
    for (size_t i = 0; i < k; ++i) diff = (uint8_t)(diff | (got[i] ^ want[i]));
    return diff == 0;
}

// ---------------------------------------------------------------- DER helpers
static std::vector<uint8_t> derLen(size_t n) {
    if (n < 0x80) return {(uint8_t)n};
    std::vector<uint8_t> b; while (n) { b.insert(b.begin(), (uint8_t)(n & 0xFF)); n >>= 8; }
    std::vector<uint8_t> o; o.push_back((uint8_t)(0x80 | b.size())); o.insert(o.end(), b.begin(), b.end()); return o;
}
static std::vector<uint8_t> derWrap(uint8_t tag, const std::vector<uint8_t>& c) {
    auto l = derLen(c.size()); std::vector<uint8_t> o; o.push_back(tag); o.insert(o.end(), l.begin(), l.end()); o.insert(o.end(), c.begin(), c.end()); return o;
}
static void put16(std::vector<uint8_t>& v, uint16_t x) {
    v.push_back((uint8_t)(x & 0xFF)); v.push_back((uint8_t)((x >> 8) & 0xFF));
}
static void put32(std::vector<uint8_t>& v, uint32_t x) {
    v.push_back((uint8_t)(x & 0xFF)); v.push_back((uint8_t)((x >> 8) & 0xFF));
    v.push_back((uint8_t)((x >> 16) & 0xFF)); v.push_back((uint8_t)((x >> 24) & 0xFF));
}
static std::vector<uint8_t> derSeq(const std::vector<uint8_t>& c) { return derWrap(0x30, c); }
static std::vector<uint8_t> derSet(const std::vector<uint8_t>& c) { return derWrap(0x31, c); }
static std::vector<uint8_t> derOctet(const std::vector<uint8_t>& c) { return derWrap(0x04, c); }
static std::vector<uint8_t> derOID(const std::vector<uint8_t>& oid) { return derWrap(0x06, oid); }
static std::vector<uint8_t> derInt(const std::vector<uint8_t>& b) { std::vector<uint8_t> bb = b; if (!bb.empty() && (bb[0] & 0x80)) bb.insert(bb.begin(), 0x00); return derWrap(0x02, bb); }
// ---------------------------------------------------------------- minimal DER reader
// Enough structure to lift fields out of a certificate or a PKCS#7 blob. Tag,
// header offset and length only: contents are never re-encoded, because DER
// SET OF ordering and length re-computation are where hand-rolled re-encoders
// break. Verifiers here always hash the original bytes.
struct DerNode { uint8_t tag = 0; size_t pos = 0, hdr = 0, len = 0; };
static bool derAt(const std::vector<uint8_t>& b, size_t p, DerNode& d) {
    if (p + 2 > b.size()) return false;
    d.pos = p; d.tag = b[p];
    size_t q = p + 1;
    if (b[q] & 0x80) {
        unsigned n = unsigned(b[q] & 0x7fu);
        if (n == 0 || n > 4 || q + 1 + n > b.size()) return false;
        uint64_t l = 0;
        for (unsigned i = 0; i < n; ++i) l = (l << 8) | b[q + 1 + i];
        q += 1 + n;
        if (l > (uint64_t)b.size()) return false;
        d.len = (size_t)l;
    } else { d.len = b[q]; q += 1; }
    d.hdr = q;
    return d.hdr + d.len <= b.size();
}
// The node's full encoding, tag and length included.
static std::vector<uint8_t> derSlice(const std::vector<uint8_t>& b, const DerNode& d) {
    return std::vector<uint8_t>(b.begin() + (long)d.pos, b.begin() + (long)(d.hdr + d.len));
}
// The immediate children of a constructed node.
static std::vector<DerNode> derChildren(const std::vector<uint8_t>& b, const DerNode& d) {
    std::vector<DerNode> out;
    size_t p = d.hdr, end = d.hdr + d.len;
    while (p + 2 <= end) {
        DerNode c;
        if (!derAt(b, p, c)) break;
        out.push_back(c);
        p = c.hdr + c.len;
    }
    return out;
}

// --- certificate fields, read out of the DER rather than assumed
// The v1 (PKCS#7) signature identifies its signer by issuer + serial number, so
// both have to come from the certificate actually in use. Hardcoding them was
// only possible while there was exactly one certificate.
static std::vector<uint8_t> certSubjectPublicKeyInfo(const std::vector<uint8_t>& cert) {
    DerNode certSeq, tbs;
    if (!derAt(cert, 0, certSeq) || certSeq.tag != 0x30 || !derAt(cert, certSeq.hdr, tbs) || tbs.tag != 0x30)
        throw Error("certificate is not a DER SEQUENCE of tbsCertificate");
    for (const DerNode& el : derChildren(cert, tbs)) {
        // SubjectPublicKeyInfo is the only tbsCertificate child that is a
        // SEQUENCE whose first child is a SEQUENCE (AlgorithmIdentifier) and
        // whose second is a BIT STRING. version is a context tag, serial an
        // INTEGER, issuer/subject hold SETs, validity holds UTCTimes.
        if (el.tag != 0x30) continue;
        std::vector<DerNode> kids = derChildren(cert, el);
        if (kids.size() == 2 && kids[0].tag == 0x30 && kids[1].tag == 0x03) return derSlice(cert, el);
    }
    throw Error("cannot find SubjectPublicKeyInfo in the certificate");
}
static void certIdentity(const std::vector<uint8_t>& cert, std::vector<uint8_t>& serial,
                         std::vector<uint8_t>& issuer, const std::string& what) {
    DerNode certSeq, tbs;
    if (!derAt(cert, 0, certSeq) || certSeq.tag != 0x30 || !derAt(cert, certSeq.hdr, tbs) || tbs.tag != 0x30)
        throw Error(what + " is not a DER SEQUENCE of tbsCertificate");
    std::vector<DerNode> kids = derChildren(cert, tbs);
    size_t i = 0;
    if (!kids.empty() && kids[i].tag == 0xA0) ++i;                 // [0] version, optional
    if (i >= kids.size() || kids[i].tag != 0x02) throw Error(what + ": no serialNumber");
    // The value bytes only: callers re-wrap them with derInt().
    serial.assign(cert.begin() + (long)kids[i].hdr, cert.begin() + (long)(kids[i].hdr + kids[i].len));
    ++i;
    if (i >= kids.size() || kids[i].tag != 0x30) throw Error(what + ": no signature algorithm");
    ++i;                                                            // signature AlgorithmIdentifier
    if (i >= kids.size() || kids[i].tag != 0x30) throw Error(what + ": no issuer Name");
    issuer = derSlice(cert, kids[i]);
}
// A DER INTEGER carries a leading 0x00 whenever the top bit of the value is
// set, so the same modulus is 256 bytes in a PKCS#1 key and 257 inside a
// certificate. Everything that compares or hashes key material works on the
// minimal big-endian form.
static std::vector<uint8_t> minimalBE(const std::vector<uint8_t>& v) {
    size_t z = 0;
    while (z + 1 < v.size() && v[z] == 0) ++z;
    return std::vector<uint8_t>(v.begin() + (long)z, v.end());
}

// RSA modulus and public exponent out of a SubjectPublicKeyInfo.
static void rsaPublicKey(const std::vector<uint8_t>& spki, std::vector<uint8_t>& n,
                         std::vector<uint8_t>& e, const std::string& what) {
    DerNode spkiSeq, alg, bits;
    if (!derAt(spki, 0, spkiSeq) || spkiSeq.tag != 0x30) throw Error(what + ": malformed public key");
    std::vector<DerNode> kids = derChildren(spki, spkiSeq);
    if (kids.size() != 2 || kids[0].tag != 0x30 || kids[1].tag != 0x03)
        throw Error(what + ": malformed public key");
    alg = kids[0]; bits = kids[1];
    static const uint8_t kRsaEncryption[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01};
    bool isRsa = false;
    for (const DerNode& k : derChildren(spki, alg))
        if (k.tag == 0x06 && derSlice(spki, k).size() == 2 + sizeof(kRsaEncryption) &&
            memcmp(spki.data() + k.hdr, kRsaEncryption, sizeof(kRsaEncryption)) == 0) isRsa = true;
    if (!isRsa) throw Error(what + ": only RSA signing keys are supported (found a non-rsaEncryption public key)");
    if (bits.len < 2 || spki[bits.hdr] != 0x00) throw Error(what + ": malformed public key bit string");
    DerNode pk;                                                     // skip the unused-bits byte
    if (!derAt(spki, bits.hdr + 1, pk) || pk.tag != 0x30) throw Error(what + ": malformed public key");
    std::vector<DerNode> pkc = derChildren(spki, pk);
    if (pkc.size() != 2 || pkc[0].tag != 0x02 || pkc[1].tag != 0x02)
        throw Error(what + ": malformed RSA public key");
    n = minimalBE(std::vector<uint8_t>(spki.begin() + (long)pkc[0].hdr, spki.begin() + (long)(pkc[0].hdr + pkc[0].len)));
    e = minimalBE(std::vector<uint8_t>(spki.begin() + (long)pkc[1].hdr, spki.begin() + (long)(pkc[1].hdr + pkc[1].len)));
}

// A key that is internally inconsistent signs APKs that every verifier rejects,
// and the failure surfaces far away from the cause. This checks the two things
// that can go wrong silently: that the certificate's public key really is the
// public half of the private key, and that our own verify accepts what our own
// sign produces. keygen runs it before writing anything to disk.
static void keySelfCheck(const SigningKey& k, const std::string& what) {
    std::vector<uint8_t> certN, certE;
    rsaPublicKey(k.spki, certN, certE, what);
    if (certN.empty() || certN != minimalBE(k.n) || certE != minimalBE(k.e))
        throw Error(what + ": the certificate's public key does not match the private key");
    SHA256 md;
    static const char kProbe[] = "aster signing key self-check";
    md.upd((const uint8_t*)kProbe, sizeof(kProbe) - 1);
    const std::vector<uint8_t> hash = md.fin();
    if (!rsaVerify(hash, rsaSign(hash, k), certN, certE))
        throw Error(what + ": sign/verify self-check failed");
}

// ---------------------------------------------------------------- PEM / DER input and output
// Aster has to read key material that ordinary tools produced, not only what it
// writes itself, so PEM (base64 between -----BEGIN/-----END lines) and raw DER
// are both accepted and told apart by content rather than by file extension.
static int b64val(uint8_t c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;                          // '=' padding, CR, LF, anything else
}
static std::vector<uint8_t> b64decode(const std::string& s) {
    std::vector<uint8_t> out;
    uint32_t acc = 0; int bits = 0;
    for (char ch : s) {
        int v = b64val((uint8_t)ch);
        if (v < 0) continue;
        acc = (acc << 6) | (uint32_t)v; bits += 6;
        if (bits >= 8) { bits -= 8; out.push_back((uint8_t)((acc >> bits) & 0xFF)); }
    }
    return out;
}
static std::string pemEncode(const char* label, const std::vector<uint8_t>& der) {
    const std::string b = b64(der);
    std::string o = "-----BEGIN "; o += label; o += "-----\n";
    for (size_t i = 0; i < b.size(); i += 64) o += b.substr(i, 64) + "\n";
    o += "-----END "; o += label; o += "-----\n";
    return o;
}
struct PemBlock { std::string label; std::vector<uint8_t> der; };
static std::vector<PemBlock> pemBlocks(const std::string& text) {
    std::vector<PemBlock> out;
    size_t p = 0;
    for (;;) {
        size_t b = text.find("-----BEGIN ", p);
        if (b == std::string::npos) break;
        size_t eol = text.find("-----", b + 11);
        if (eol == std::string::npos) break;
        std::string label = text.substr(b + 11, eol - (b + 11));
        while (!label.empty() && (label.back() == ' ' || label.back() == '\t' || label.back() == '\r')) label.pop_back();
        size_t end = text.find("-----END " + label, eol);
        if (end == std::string::npos) break;
        out.push_back({label, b64decode(text.substr(eol + 5, end - (eol + 5)))});
        p = end + 9 + label.size();
    }
    return out;
}
// DER bytes for one logical object: the whole file when it is already DER, or
// the body of the first PEM block carrying one of the accepted labels.
static std::vector<uint8_t> derFromMaybePem(const std::string& path, const std::vector<std::string>& labels,
                                            const std::string& what) {
    const std::string text = readFile(path);
    if (!text.empty() && (uint8_t)text[0] == 0x30)
        return std::vector<uint8_t>(text.begin(), text.end());
    std::vector<std::string> seen;
    for (const PemBlock& b : pemBlocks(text)) {
        for (const std::string& want : labels)
            if (b.label == want) return b.der;
        seen.push_back(b.label);
    }
    std::string msg = what + " " + path + ": expected a PEM block labelled ";
    for (size_t i = 0; i < labels.size(); ++i) msg += (i ? " or " : "") + labels[i];
    if (!seen.empty()) {
        msg += ", found";
        for (const std::string& l : seen) msg += " " + l;
    } else if (!text.empty()) {
        msg += ", but the file is neither DER nor PEM";
    }
    throw Error(msg);
}

// PKCS#1 RSAPrivateKey: SEQUENCE of nine INTEGERs
// (version, n, e, d, p, q, dP, dQ, qInv).
static void parsePkcs1(const std::vector<uint8_t>& der, SigningKey& k, const std::string& what) {
    DerNode seq;
    if (!derAt(der, 0, seq) || seq.tag != 0x30) throw Error(what + ": not a DER SEQUENCE");
    const std::vector<DerNode> kids = derChildren(der, seq);
    if (kids.size() != 9) throw Error(what + ": expected 9 RSAPrivateKey fields, found " + std::to_string(kids.size()));
    for (const DerNode& c : kids)
        if (c.tag != 0x02) throw Error(what + ": an RSAPrivateKey field is not an INTEGER");
    auto val = [&](size_t i) {
        return minimalBE(std::vector<uint8_t>(der.begin() + (long)kids[i].hdr,
                                              der.begin() + (long)(kids[i].hdr + kids[i].len)));
    };
    k.n = val(1); k.e = val(2); k.d = val(3);
    k.p = val(4); k.q = val(5); k.dp = val(6); k.dq = val(7); k.qinv = val(8);
}
static void loadPrivateKey(const std::string& path, SigningKey& k) {
    const std::string what = "private key";
    const std::vector<uint8_t> der = derFromMaybePem(path, {"PRIVATE KEY", "RSA PRIVATE KEY"}, what);
    DerNode outer;
    if (!derAt(der, 0, outer) || outer.tag != 0x30) throw Error(what + " " + path + ": not a DER SEQUENCE");
    const std::vector<DerNode> kids = derChildren(der, outer);
    if (kids.size() == 2 && kids[0].tag == 0x30 && kids[1].tag == 0x04)
        throw Error(what + " " + path + ": is encrypted; Aster reads unencrypted PEM keys only "
                    "(decrypt it first, e.g. openssl pkcs8 -in enc.pem -out plain.pem)");
    if (kids.size() == 3 && kids[0].tag == 0x02 && kids[1].tag == 0x30 && kids[2].tag == 0x04) {
        // PKCS#8 PrivateKeyInfo: the inner OCTET STRING holds the PKCS#1 key.
        static const uint8_t kRsaOid[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01};
        bool isRsa = false;
        for (const DerNode& c : derChildren(der, kids[1]))
            if (c.tag == 0x06 && c.len == sizeof(kRsaOid) &&
                memcmp(der.data() + c.hdr, kRsaOid, sizeof(kRsaOid)) == 0) isRsa = true;
        if (!isRsa) throw Error(what + " " + path + ": only RSA signing keys are supported");
        const std::vector<uint8_t> inner(der.begin() + (long)kids[2].hdr, der.begin() + (long)(kids[2].hdr + kids[2].len));
        parsePkcs1(inner, k, what + " " + path);
        return;
    }
    parsePkcs1(der, k, what + " " + path);      // bare PKCS#1 RSAPrivateKey
}
static void loadCertificate(const std::string& path, SigningKey& k) {
    const std::string what = "certificate";
    k.certDER = derFromMaybePem(path, {"CERTIFICATE", "X509 CERTIFICATE"}, what);
    k.spki = certSubjectPublicKeyInfo(k.certDER);
    certIdentity(k.certDER, k.serial, k.issuerDER, what + " " + path);
}
// A key is only usable as a pair: the private key signs, the certificate is
// what Android sees. Loading them together lets us prove right here that the
// certificate really carries this key's public half -- a mismatched pair would
// otherwise produce an APK that installs nowhere and says only "invalid".
static void loadSigningKey(const std::string& keyPath, const std::string& certPath, SigningKey& k) {
    k = SigningKey();
    loadPrivateKey(keyPath, k);
    loadCertificate(certPath, k);
    k.source = keyPath;
    keySelfCheck(k, "signing key " + keyPath);
}
static SigningKey loadSigningKey(const std::string& keyPath, const std::string& certPath) {
    SigningKey k;
    loadSigningKey(keyPath, certPath, k);
    return k;
}
// ---------------------------------------------------------------- random bytes
static std::vector<uint8_t> randomBytes(size_t n) {
    std::vector<uint8_t> out(n, 0);
    if (n == 0) return out;
    std::ifstream f("/dev/urandom", std::ios::binary);
    if (!f) throw Error("cannot open /dev/urandom: key generation needs a random source");
    f.read((char*)out.data(), (std::streamsize)n);
    if ((size_t)f.gcount() != n) throw Error("/dev/urandom returned fewer bytes than asked for");
    return out;
}

// ---------------------------------------------------------------- number theory
static Big gcd(const Big& a, const Big& b) {
    Big x = a, y = b;
    while (cmp(y, Big()) > 0) { Big t = mod(x, y); x = y; y = t; }
    return x;
}
// Modular inverse by extended Euclid. Coefficients are kept as residues mod m
// so that no intermediate value ever has to be represented as negative.
static bool modInverse(const Big& aIn, const Big& m, Big& out) {
    if (cmp(m, Big({1})) <= 0) return false;
    Big a = mod(aIn, m), g = m;
    Big x0, x1(std::vector<uint32_t>{1});   // x0 tracks g, x1 tracks a
    while (cmp(a, Big({1})) > 0) {
        if (cmp(a, Big()) == 0) return false;           // gcd(a, m) != 1
        const std::pair<Big, Big> dm = divmod(g, a);
        const Big q = dm.first;
        const Big qx1 = mod(mul(q, x1), m);
        Big t = (cmp(x0, qx1) >= 0) ? sub(x0, qx1) : add(x0, sub(m, qx1));
        t = mod(t, m);
        x0 = x1; x1 = t;
        g = a; a = dm.second;
    }
    if (cmp(a, Big({1})) != 0) return false;
    out = mod(x1, m);
    return true;
}
// Miller-Rabin. n-1 = d*2^s with d odd; a is a witness of compositeness when
// a^d != 1 and no a^(d*2^r) reaches n-1.
static bool millerRabin(const Big& n, size_t rounds) {
    const Big one(std::vector<uint32_t>{1});
    const Big nMinus1 = sub(n, one);
    Big d = nMinus1;
    int s = 0;
    while ((d.v[0] & 1u) == 0) { d = halve(d); ++s; }
    for (size_t r = 0; r < rounds; ++r) {
        Big a;
        if (r == 0) {
            // One round with base 2 rejects almost every composite for the
            // price of a single modexp; random bases come after it.
            a = Big(std::vector<uint32_t>{2});
            if (cmp(a, nMinus1) >= 0) continue;
        } else {
            const Big span = sub(n, Big(std::vector<uint32_t>{3}));
            for (;;) {
                const std::vector<uint8_t> rb = randomBytes((n.v.size() + 1) * 4);
                a = mod(add(Big::fromBE(rb.data(), rb.size()), Big(std::vector<uint32_t>{2})), span);
                a = add(a, Big(std::vector<uint32_t>{2}));
                if (cmp(a, one) > 0 && cmp(a, nMinus1) < 0) break;
            }
        }
        Big x = modExp(a, d, n);
        if (cmp(x, one) == 0 || cmp(x, nMinus1) == 0) continue;
        bool composite = true;
        for (int i = 1; i < s; ++i) {
            x = mod(mul(x, x), n);
            if (cmp(x, nMinus1) == 0) { composite = false; break; }
        }
        if (composite) return false;
    }
    return true;
}
static std::vector<uint32_t> smallPrimes(uint32_t limit) {
    std::vector<bool> composite(limit + 1, false);
    std::vector<uint32_t> out;
    for (uint32_t i = 2; i <= limit; ++i) {
        if (composite[i]) continue;
        out.push_back(i);
        if ((uint64_t)i * i <= limit)
            for (uint64_t j = (uint64_t)i * i; j <= limit; j += i) composite[(size_t)j] = true;
    }
    return out;
}
// The top two bits are forced set so that the number is at least 1.5*2^(bits-1):
// the product of two such primes then exceeds 2^(2*bits-1), which is what keeps
// the modulus exactly 2*bits wide. A modulus one byte short would silently
// shrink every PKCS#1 signature block and produce APKs that fail to verify.
static Big randomOddCandidate(size_t bits) {
    std::vector<uint8_t> b = randomBytes(bits / 8);
    b[0] |= 0xC0;
    b[b.size() - 1] |= 0x01;
    return Big::fromBE(b.data(), b.size());
}
static Big generatePrime(size_t bits, const std::vector<uint32_t>& sieve, size_t rounds) {
    for (;;) {
        const Big c = randomOddCandidate(bits);
        bool divisible = false;
        for (uint32_t p : sieve)
            if (cmp(mod(c, Big(std::vector<uint32_t>{p})), Big()) == 0) { divisible = true; break; }
        if (divisible) continue;
        if (millerRabin(c, rounds)) return c;
    }
}

// ---------------------------------------------------------------- key generation
static std::vector<uint8_t> algIdOf(const std::vector<uint8_t>& oid) {
    return derSeq(concat(derOID(oid), std::vector<uint8_t>{0x05, 0x00}));
}
static std::vector<uint8_t> derUtf8(const std::string& s) {
    return derWrap(0x0C, std::vector<uint8_t>(s.begin(), s.end()));
}
static std::vector<uint8_t> derUtcTime(const std::string& s) {
    return derWrap(0x17, std::vector<uint8_t>(s.begin(), s.end()));
}
// X.690 11.8 UTCTime: YYMMDDHHMMSSZ, two digits per field, always UTC.
static std::string utcStamp(time_t t) {
    struct tm parts;
    gmtime_r(&t, &parts);
    const unsigned f[6] = {
        (unsigned)(parts.tm_year % 100), (unsigned)(parts.tm_mon + 1), (unsigned)parts.tm_mday,
        (unsigned)parts.tm_hour,         (unsigned)parts.tm_min,       (unsigned)parts.tm_sec };
    std::string s;
    for (int i = 0; i < 6; ++i) {
        const unsigned v = f[i] % 100u;          // a malformed tm must not widen the field
        s.push_back((char)('0' + v / 10));
        s.push_back((char)('0' + v % 10));
    }
    s.push_back('Z');
    return s;
}
// Self-signed certificate, matching the shape Aster has always emitted: v3 with
// a critical basicConstraints, sha256WithRSAEncryption, issuer == subject.
static std::vector<uint8_t> selfSignedCert(const SigningKey& k, const std::vector<uint8_t>& serial) {
    const std::vector<uint8_t> oidSha256Rsa = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x0b};
    const std::vector<uint8_t> oidRsaEnc    = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01};
    const std::vector<uint8_t> oidO         = {0x55,0x04,0x0a};
    const std::vector<uint8_t> oidCn        = {0x55,0x04,0x03};
    const std::vector<uint8_t> oidBasicC    = {0x55,0x1d,0x13};
    // CN stays "Aster Dev Signing Key": tests and on-device notes identify the
    // debug certificate by it, and two debug keys are meant to be interchangeable.
    const std::vector<uint8_t> rdnO  = derSet(derSeq(concat(derOID(oidO),  derUtf8("Aster Bootstrap Compiler"))));
    const std::vector<uint8_t> rdnCn = derSet(derSeq(concat(derOID(oidCn), derUtf8("Aster Dev Signing Key"))));
    const std::vector<uint8_t> name  = derSeq(concat(rdnO, rdnCn));
    const std::vector<uint8_t> spki  = derSeq(concat(algIdOf(oidRsaEnc),
        derWrap(0x03, concat(std::vector<uint8_t>{0x00}, derSeq(concat(derInt(k.n), derInt(k.e)))))));
    const std::vector<uint8_t> basicConstraints =
        derWrap(0xA3, derSeq(derSeq(concat(concat(derOID(oidBasicC), derWrap(0x01, std::vector<uint8_t>{0xff})),
                                           derOctet(derSeq(derWrap(0x01, std::vector<uint8_t>{0xff})))))));
    const std::vector<uint8_t> validity = derSeq(concat(
        // Backdate by a day so a skewed device clock does not reject it outright.
        derUtcTime(utcStamp(time(nullptr) - 24 * 3600)),
        // UTCTime cannot express past 2049; clamping here avoids GeneralizedTime.
        derUtcTime("491231235959Z")));
    static const uint8_t kVersion3[] = {0x02, 0x01, 0x02};      // INTEGER 2
    const std::vector<uint8_t> tbs = derSeq(concat(concat(
        concat(derWrap(0xA0, std::vector<uint8_t>(kVersion3, kVersion3 + 3)), derInt(serial)),
        concat(algIdOf(oidSha256Rsa), name)),
        concat(concat(validity, name), concat(spki, basicConstraints))));
    SHA256 md; md.upd(tbs.data(), tbs.size());
    const std::vector<uint8_t> sig = rsaSign(md.fin(), k);
    return derSeq(concat(concat(tbs, algIdOf(oidSha256Rsa)),
                         derWrap(0x03, concat(std::vector<uint8_t>{0x00}, sig))));
}
static SigningKey generateKey(int bits) {
    if (bits != 2048 && bits != 3072 && bits != 4096)
        throw Error("keygen: unsupported size " + std::to_string(bits) + " (use 2048, 3072 or 4096)");
    const size_t half = (size_t)bits / 2;
    const std::vector<uint32_t> sieve = smallPrimes(65536);
    const Big e(std::vector<uint32_t>{65537});
    const Big one(std::vector<uint32_t>{1});
    // 32 random bases on top of the base-2 pre-filter: a composite surviving
    // that has probability at most 4^-32, far below the chance of a hardware
    // fault, and the cost is one modexp per candidate that reaches this point.
    const size_t kRounds = 33;
    for (;;) {
        const Big p = generatePrime(half, sieve, kRounds);
        Big q = generatePrime(half, sieve, kRounds);
        if (cmp(p, q) == 0) continue;
        const Big p1 = sub(p, one), q1 = sub(q, one);
        if (cmp(gcd(e, p1), one) != 0 || cmp(gcd(e, q1), one) != 0) continue;   // e must invert
        const Big n = mul(p, q);
        if (n.toBE().size() != (size_t)bits / 8)
            continue;                                   // modulus lost its top byte; resample
        Big lambda = divmod(mul(p1, q1), gcd(p1, q1)).first;   // lcm(p-1, q-1)
        Big d;
        if (!modInverse(e, lambda, d) || cmp(d, one) <= 0) continue;
        Big qinv;
        if (!modInverse(q, p, qinv)) continue;
        SigningKey k;
        k.n = n.toBE();
        k.e = e.toBE();
        k.d = bigToFixedBE(d, k.n.size());
        k.p = p.toBE();
        k.q = q.toBE();
        k.dp = mod(d, p1).toBE();
        k.dq = mod(d, q1).toBE();
        k.qinv = bigToFixedBE(qinv, k.p.size());
        // keySelfCheck below is the real correctness gate: it signs and then
        // verifies, which only succeeds if d really inverts e modulo lambda.
        std::vector<uint8_t> serial = randomBytes(16);
        serial[0] &= 0x7F;                              // positive INTEGER
        k.certDER = selfSignedCert(k, serial);
        k.spki = certSubjectPublicKeyInfo(k.certDER);
        certIdentity(k.certDER, k.serial, k.issuerDER, "the generated certificate");
        k.source = "generated debug key";
        keySelfCheck(k, "the generated key");
        return k;
    }
}

// ---------------------------------------------------------------- key material on disk
template <class... Ts> static std::vector<uint8_t> catAll(const Ts&... vs) {
    std::vector<uint8_t> o;
    (void)std::initializer_list<int>{(o.insert(o.end(), vs.begin(), vs.end()), 0)...};
    return o;
}
static std::vector<uint8_t> pkcs1Der(const SigningKey& k) {
    return derSeq(catAll(derWrap(0x02, std::vector<uint8_t>{0x00}), derInt(k.n), derInt(k.e), derInt(k.d),
                         derInt(k.p), derInt(k.q), derInt(k.dp), derInt(k.dq), derInt(k.qinv)));
}
static std::vector<uint8_t> pkcs8Der(const SigningKey& k) {
    const std::vector<uint8_t> oidRsaEnc = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01};
    return derSeq(catAll(derWrap(0x02, std::vector<uint8_t>{0x00}), algIdOf(oidRsaEnc), derOctet(pkcs1Der(k))));
}
static bool dirExists(const std::string& p) {
    struct stat st;
    return stat(p.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}
static bool fileExists(const std::string& p) {
    struct stat st;
    return stat(p.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}
static std::string parentDir(const std::string& p) {
    const size_t s = p.find_last_of('/');
    if (s == std::string::npos) return std::string(".");
    return s == 0 ? std::string("/") : p.substr(0, s);
}
// Where a project's debug key lives. --keystore-dir wins, then $ASTER_KEY_DIR,
// then the nearest ancestor of the working directory that looks like a project
// root, then the working directory itself. Anchoring on the working directory
// rather than on the input file matters: a build may read its .so from build/
// and its .ast from src/, and one app must not end up with two debug keys.
static std::string projectKeyDir(const std::string& explicitDir) {
    if (!explicitDir.empty()) return explicitDir;
    if (const char* env = getenv("ASTER_KEY_DIR")) if (*env) return std::string(env);
    char cwd[4096];
    if (!getcwd(cwd, sizeof(cwd))) return std::string(".");
    std::string dir(cwd);
    for (;;) {
        if (dirExists(dir + "/.git") || dirExists(dir + "/.aster")) return dir;
        const std::string up = parentDir(dir);
        if (up == dir) break;
        dir = up;
    }
    return std::string(cwd);
}
static std::string keyDirOf(const std::string& projectDir) { return projectDir + "/.aster"; }
static std::string debugKeyPath(const std::string& projectDir) { return keyDirOf(projectDir) + "/debug.key.pem"; }
static std::string debugCertPath(const std::string& projectDir) { return keyDirOf(projectDir) + "/debug.crt.pem"; }
static void writeFileAtomic(const std::string& path, const std::string& data) {
    const std::string tmp = path + ".tmp";
    {
        std::ofstream os(tmp, std::ios::binary);
        if (!os) throw Error("cannot write " + tmp);
        os.write(data.data(), (std::streamsize)data.size());
    }
    // Write-then-rename: two builds racing in one project must never observe a
    // half-written key.
    if (std::rename(tmp.c_str(), path.c_str()) != 0) throw Error("cannot move " + tmp + " into place");
}
static void writeKeyPair(const std::string& projectDir, const SigningKey& k) {
    const std::string kd = keyDirOf(projectDir);
    if (!dirExists(kd) && mkdir(kd.c_str(), 0700) != 0 && !dirExists(kd))
        throw Error("cannot create " + kd);
    writeFileAtomic(debugKeyPath(projectDir), pemEncode("PRIVATE KEY", pkcs8Der(k)));
    writeFileAtomic(debugCertPath(projectDir), pemEncode("CERTIFICATE", k.certDER));
    // Both files are derived artifacts and the private key must never be
    // committed, so the directory ignores itself.
    writeFileAtomic(kd + "/.gitignore", "*\n");
}
// --sign-mode debug: reuse the project's key, generating one on first use.
static SigningKey debugKeyFor(const std::string& projectDir, int bits) {
    const std::string kp = debugKeyPath(projectDir), cp = debugCertPath(projectDir);
    if (fileExists(kp) && fileExists(cp)) return loadSigningKey(kp, cp);
    SigningKey k = generateKey(bits);
    writeKeyPair(projectDir, k);
    k.source = kp;      // once it is on disk, name the file -- that is what a rebuild will reuse
    std::cerr << "aster: generated a " << std::to_string(bits) << "-bit debug key for this project: " << kp << "\n"
              << "aster: it is for development only -- sign releases with --sign-mode release --keystore ... --cert ...\n";
    return k;
}
static int keygenCommand(const std::string& projectDir, int bits, bool force) {
    const std::string kp = debugKeyPath(projectDir), cp = debugCertPath(projectDir);
    if (!force && (fileExists(kp) || fileExists(cp))) {
        std::cerr << "aster: keygen: " << kp << " already exists; pass --force to replace it\n";
        return 1;
    }
    const SigningKey k = generateKey(bits);
    writeKeyPair(projectDir, k);
    std::cout << "Aster v" << kVersion << ": generated a " << bits << "-bit RSA debug key\n"
              << "  private key: " << kp << "\n"
              << "  certificate: " << cp << "\n"
              << "  modulus " << k.n.size() * 8 << " bits, self-signed, CN=Aster Dev Signing Key\n"
              << "  development only -- do not publish with this key\n";
    return 0;
}
// --sign-mode release: fail closed. A release build that quietly fell back to a
// generated key would look exactly like a correctly signed one.
static SigningKey releaseKey(const std::string& keystore, const std::string& cert) {
    if (keystore.empty() || cert.empty()) {
        std::cerr << "aster: build-apk: --sign-mode release requires both --keystore <key.pem> and --cert <cert.pem>\n"
                  << "aster: build-apk: a release key must be yours; Aster will not invent one for you\n";
        throw Error("release signing key not provided");
    }
    return loadSigningKey(keystore, cert);
}

static std::vector<uint8_t> derInt(uint32_t v) { std::vector<uint8_t> b; for (int i = 3; i >= 0; --i) b.push_back((v >> (i*8)) & 0xFF); while (b.size() > 1 && b[0] == 0) b.erase(b.begin()); return derWrap(0x02, b); }

// ---------------------------------------------------------------- PNG (minimal 32-bit RGBA encoder)
// A launcher icon has to be a real PNG: Android decodes it with its own image
// decoder, so a hand-rolled bitmap is not an option. None of this needs a
// library — a deflate stream may consist of *stored* (verbatim) blocks, which
// PNG explicitly permits, and the only checksums are ones Aster already has.
namespace PNG {
static uint32_t adler32(const uint8_t* p, size_t n) {
    uint32_t a = 1, b = 0;
    for (size_t i = 0; i < n; ++i) {
        a += p[i];               if (a >= 65521u) a -= 65521u;
        b += a;                  if (b >= 65521u) b -= 65521u;
    }
    return (b << 16) | a;
}
static void put32be(std::vector<uint8_t>& v, uint32_t x) {
    v.push_back((uint8_t)((x >> 24) & 0xFF)); v.push_back((uint8_t)((x >> 16) & 0xFF));
    v.push_back((uint8_t)((x >> 8) & 0xFF));  v.push_back((uint8_t)(x & 0xFF));
}
// One stored block per <=65535 bytes: three header bits (BFINAL, then BTYPE=00)
// left-aligned in a byte, the rest of that byte being the pad to the byte
// boundary, then LEN, its complement, and the bytes themselves.
static void deflateStored(std::vector<uint8_t>& o, const uint8_t* p, size_t n) {
    size_t pos = 0;
    do {
        size_t chunk = n - pos; if (chunk > 65535) chunk = 65535;
        bool last = (pos + chunk >= n);
        o.push_back((uint8_t)(last ? 0x01 : 0x00));
        uint16_t len = (uint16_t)chunk;
        o.push_back((uint8_t)(len & 0xFF));        o.push_back((uint8_t)(len >> 8));
        o.push_back((uint8_t)((~len) & 0xFF));     o.push_back((uint8_t)((~len) >> 8));
        o.insert(o.end(), p + pos, p + pos + chunk);
        pos += chunk;
    } while (pos < n);
}
static void chunk(std::vector<uint8_t>& o, const char type[4], const std::vector<uint8_t>& data) {
    put32be(o, (uint32_t)data.size());
    o.insert(o.end(), type, type + 4);
    o.insert(o.end(), data.begin(), data.end());
    std::vector<uint8_t> t(type, type + 4); t.insert(t.end(), data.begin(), data.end());
    put32be(o, crc32(t.data(), t.size()));
}
// The plate is transparent outside its corners, which is what makes it read as
// an icon rather than as a filled square. Three states are enough — plate,
// glyph, transparent — so the image is stored as a 2-bit palette with the
// transparent entry carrying an alpha of 0 through tRNS: that is 9 KB instead
// of the 147 KB a 32-bit RGBA encoding of the same picture would cost, and it
// still has a real alpha channel, which is what a launcher icon requires.
static std::vector<uint8_t> indices(int w, int h) {
    static const char* g[8] = {
        "..####..", ".##..##.", "##....##", "##....##",
        "########", "##....##", "##....##", "##....##" };
    const int pad = w / 8, cell = (w - 2 * pad) / 8, r = w / 6;
    std::vector<uint8_t> idx;
    for (int y = 0; y < h; ++y) {
        for (int b = 0; b < (w + 3) / 4; ++b) {          // four 2-bit samples per byte
            uint8_t byte = 0;
            for (int s = 0; s < 4; ++s) {
                int x = b * 4 + s;
                uint8_t v = 2;                            // outside the image row: transparent
                if (x < w) {
                    int cx = std::min(std::max(x, r), w - 1 - r), cy = std::min(std::max(y, r), h - 1 - r);
                    int dx = x - cx, dy = y - cy;
                    if (dx * dx + dy * dy <= r * r) {
                        // C++ truncates towards zero, so (x - pad) / cell is 0 for
                        // every x in [pad - cell + 1, pad] — the left edge of the
                        // grid would stretch 17px further left than the right edge
                        // does right, and the glyph would sit off-centre. Guard it.
                        int gx = (x >= pad) ? (x - pad) / cell : -1;
                        int gy = (y >= pad) ? (y - pad) / cell : -1;
                        v = (gx >= 0 && gx < 8 && gy >= 0 && gy < 8 && g[gy][gx] == '#') ? 1 : 0;
                    }
                }
                byte |= (uint8_t)(v << (6 - 2 * s));
            }
            idx.push_back(byte);
        }
    }
    return idx;
}
static std::vector<uint8_t> build(int w, int h) {
    std::vector<uint8_t> idx = indices(w, h);
    const size_t stride = (size_t)((w + 3) / 4);
    // Every scanline is prefixed with a filter byte. Filter 0 (None) is the one
    // that needs no neighbour arithmetic, so it is also the one that cannot be
    // gotten subtly wrong.
    std::vector<uint8_t> raw;
    raw.reserve((size_t)h * (1 + stride));
    for (int y = 0; y < h; ++y) {
        raw.push_back(0);
        raw.insert(raw.end(), idx.begin() + (size_t)y * stride, idx.begin() + ((size_t)y + 1) * stride);
    }
    std::vector<uint8_t> z;
    z.push_back(0x78); z.push_back(0x01);   // zlib: deflate, 32 KiB window, fastest
    deflateStored(z, raw.data(), raw.size());
    put32be(z, adler32(raw.data(), raw.size()));
    std::vector<uint8_t> ihdr;
    put32be(ihdr, (uint32_t)w); put32be(ihdr, (uint32_t)h);
    ihdr.push_back(2);   // bit depth
    ihdr.push_back(3);   // colour type 3 = indexed
    ihdr.push_back(0); ihdr.push_back(0); ihdr.push_back(0);
    std::vector<uint8_t> plte = {0x28,0x35,0x93, 0xFF,0xFF,0xFF, 0x00,0x00,0x00};
    std::vector<uint8_t> trns = {0xFF, 0xFF, 0x00};   // the third entry is the transparent one
    std::vector<uint8_t> out = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
    chunk(out, "IHDR", ihdr); chunk(out, "PLTE", plte); chunk(out, "tRNS", trns);
    chunk(out, "IDAT", z); chunk(out, "IEND", std::vector<uint8_t>());
    return out;
}
} // namespace PNG

// ---------------------------------------------------------------- resources.arsc (binary resource table)
// A manifest cannot point at a file: `android:icon` is a resource *id*, and the
// only place an id is mapped to a path is this table. An APK with an icon
// therefore needs one, and Aster has to build it itself. The table carries the
// minimum a launcher needs: one package (0x7f), one type ("drawable"), one
// entry ("ic_launcher") whose value is the path of the PNG inside the APK.
namespace ARSC {
static void encLen(std::vector<uint8_t>& o, size_t n) {
    // ResStringPool reads a two-byte length as ((first & 0x7F) << 8) | second,
    // so the high bits go in the first byte.
    if (n < 0x80) o.push_back((uint8_t)n);
    else { o.push_back((uint8_t)(0x80 | ((n >> 8) & 0x7F))); o.push_back((uint8_t)(n & 0xFF)); }
}
static void encStr(std::vector<uint8_t>& o, const std::string& s) {
    encLen(o, s.size()); encLen(o, s.size());   // character count, then byte count
    o.insert(o.end(), s.begin(), s.end()); o.push_back(0x00);
}
static std::vector<uint8_t> stringPool(const std::vector<std::string>& strings) {
    std::vector<uint8_t> offs, data; size_t pos = 0;
    for (const std::string& s : strings) {
        put32(offs, (uint32_t)pos);
        size_t before = data.size(); encStr(data, s); pos += data.size() - before;
    }
    size_t count = strings.size(), stringsStart = 28 + 4 * count;
    while (((stringsStart + data.size()) & 3) != 0) data.push_back(0x00);
    std::vector<uint8_t> sp;
    put16(sp, 0x0001); put16(sp, 28); put32(sp, (uint32_t)(stringsStart + data.size()));
    put32(sp, (uint32_t)count); put32(sp, 0);
    put32(sp, 0x00000100u);                     // UTF8_FLAG — same encoding as the AXML pool
    put32(sp, (uint32_t)stringsStart); put32(sp, 0);
    sp.insert(sp.end(), offs.begin(), offs.end()); sp.insert(sp.end(), data.begin(), data.end());
    return sp;
}
static void patchSize(std::vector<uint8_t>& c, uint32_t size) {
    c[4] = (uint8_t)(size & 0xFF);         c[5] = (uint8_t)((size >> 8) & 0xFF);
    c[6] = (uint8_t)((size >> 16) & 0xFF); c[7] = (uint8_t)((size >> 24) & 0xFF);
}
// A resource table entry: one (type, name) pair and the value the framework
// reads for it.
//
// v0.23.7-dev: the table used to be one drawable written by a function with
// three string arguments, which is to say it was not a table at all — it could
// not hold a second resource of any kind. It now holds an ordered list, and
// two kinds of value, because the framework reads them differently:
//
//   File   — TYPE_STRING whose data indexes the global pool, which holds a path
//            *inside the APK*. The AssetManager opens that path.
//   Inline — TYPE_STRING whose data indexes the global pool, which holds the
//            string itself. Nothing is opened: the table is the value. This is
//            what a string resource is, and it is why a label belongs in here
//            rather than spelled out in the manifest.
//
// The two are the same on the wire. The difference is what the string in the
// pool happens to name.
struct Entry {
    std::string type;      // "drawable", "string", ...
    std::string name;      // "ic_launcher", "app_name", ...
    std::string value;     // a path inside the APK, or the string itself
    bool isFile = false;
};
struct Table {
    std::vector<Entry> entries;
    std::vector<std::string> types;   // distinct type names, in type-id order
    void add(const Entry& e) {
        bool known = false;
        for (const auto& t : types) if (t == e.type) known = true;
        if (!known) types.push_back(e.type);
        entries.push_back(e);
    }
    // 0xPPTTEEEE. Type ids start at 1 (0 is reserved) and are handed out in
    // order of first appearance, so the order resources are added in is the
    // order they appear in the table and the order their ids come out in.
    // Returns 0 when the pair is not in the table: the caller is asking for an
    // id it did not put there.
    uint32_t resId(const std::string& type, const std::string& name) const {
        size_t ti = 0; bool found = false;
        for (size_t i = 0; i < types.size(); ++i) if (types[i] == type) { ti = i; found = true; break; }
        if (!found) return 0;
        uint32_t idx = 0;
        for (const auto& e : entries) {
            if (e.type != type) continue;
            if (e.name == name) return (0x7fu << 24) | ((uint32_t)(ti + 1) << 16) | idx;
            ++idx;
        }
        return 0;
    }
};
// One type's worth of a table: the entries whose type is `t`, in id order.
static std::vector<const Entry*> entriesOfType(const Table& tb, const std::string& t) {
    std::vector<const Entry*> v;
    for (const auto& e : tb.entries) if (e.type == t) v.push_back(&e);
    return v;
}
static std::vector<uint8_t> build(const std::string& pkgName, const Table& table) {
    // Global string pool: every value in the table, whether it names a file or
    // *is* a string. Interned, because two resources may well share one value.
    std::vector<std::string> gstrings;
    std::map<std::string, uint32_t> gindex;
    auto gintern = [&](const std::string& s) -> uint32_t {
        auto it = gindex.find(s);
        if (it != gindex.end()) return it->second;
        uint32_t i = (uint32_t)gstrings.size();
        gstrings.push_back(s); gindex[s] = i; return i;
    };
    std::vector<std::string> knames;
    std::map<std::string, uint32_t> kindex;
    auto kintern = [&](const std::string& s) -> uint32_t {
        auto it = kindex.find(s);
        if (it != kindex.end()) return it->second;
        uint32_t i = (uint32_t)knames.size();
        knames.push_back(s); kindex[s] = i; return i;
    };
    // Walk the types in id order so the pool, the key pool and the chunks all
    // agree on which entry is which.
    std::vector<std::vector<const Entry*>> byType;
    for (const auto& t : table.types) {
        std::vector<const Entry*> es = entriesOfType(table, t);
        for (const auto* e : es) { gintern(e->value); kintern(e->name); }
        byType.push_back(std::move(es));
    }
    std::vector<uint8_t> gsp = stringPool(gstrings);
    std::vector<uint8_t> tsp = stringPool(table.types);
    std::vector<uint8_t> ksp = stringPool(knames);

    // One typeSpec + one type chunk per type, in type-id order: a reader walks
    // this package's chunks in order and the ids have to ascend.
    std::vector<uint8_t> chunks;
    for (size_t ti = 0; ti < table.types.size(); ++ti) {
        const uint32_t typeId = (uint32_t)(ti + 1);
        const std::vector<const Entry*>& es = byType[ti];
        const uint32_t n = (uint32_t)es.size();

        std::vector<uint8_t> spec;                  // ResTable_typeSpec
        put16(spec, 0x0202); put16(spec, 16); put32(spec, 16 + 4 * n);
        spec.push_back((uint8_t)typeId); spec.push_back(0); put16(spec, 0);
        put32(spec, n);
        for (uint32_t i = 0; i < n; ++i) put32(spec, 0);   // flags: entry present, no config variance

        // ResTable_type: header is 8 (chunk) + 4 (id/res0/res1) + 4 (entryCount) +
        // 4 (entriesStart) + config, and the entry offsets follow the header.
        const uint32_t kConfigSize = 56;            // what aapt emits for a default config
        const uint32_t headerSize = 20 + kConfigSize;
        const uint32_t entriesStart = headerSize + 4 * n;
        std::vector<uint8_t> type;
        put16(type, 0x0201); put16(type, (uint16_t)headerSize); put32(type, 0);
        type.push_back((uint8_t)typeId); type.push_back(0); put16(type, 0);
        put32(type, n);
        put32(type, entriesStart);
        put32(type, kConfigSize);                   // config.size — the field that tells
        for (uint32_t i = 4; i < kConfigSize; ++i) type.push_back(0x00);  // the reader how much config follows
        uint32_t run = 0;
        for (uint32_t i = 0; i < n; ++i) { put32(type, run); run += 8 + 8; }  // ResTable_entry + Res_value
        for (const Entry* e : es) {
            put16(type, 8); put16(type, 0); put32(type, kintern(e->name));   // size, flags, key
            put16(type, 8); type.push_back(0); type.push_back(0x03); put32(type, gintern(e->value));
            //                                     ^ Res_value: TYPE_STRING, data = index into the global pool
        }
        patchSize(type, (uint32_t)type.size());
        chunks.insert(chunks.end(), spec.begin(), spec.end());
        chunks.insert(chunks.end(), type.begin(), type.end());
    }

    std::vector<uint8_t> pkg;
    put16(pkg, 0x0200); put16(pkg, 288); put32(pkg, 0);
    put32(pkg, 0x7f);                               // application package id
    for (int i = 0; i < 128; ++i) put16(pkg, (uint16_t)((size_t)i < pkgName.size() ? pkgName[i] : 0));
    put32(pkg, 288);                                // typeStrings
    put32(pkg, (uint32_t)table.types.size());       // lastPublicType
    put32(pkg, 288 + (uint32_t)tsp.size());         // keyStrings
    put32(pkg, (uint32_t)knames.size());            // lastPublicKey
    put32(pkg, 0);                                  // typeIdOffset
    pkg.insert(pkg.end(), tsp.begin(), tsp.end());
    pkg.insert(pkg.end(), ksp.begin(), ksp.end());
    pkg.insert(pkg.end(), chunks.begin(), chunks.end());
    patchSize(pkg, (uint32_t)pkg.size());

    std::vector<uint8_t> out;
    put16(out, 0x0002); put16(out, 12); put32(out, 0);
    put32(out, 1);                                  // packageCount
    out.insert(out.end(), gsp.begin(), gsp.end());
    out.insert(out.end(), pkg.begin(), pkg.end());
    patchSize(out, (uint32_t)out.size());
    return out;
}
} // namespace ARSC

// ---------------------------------------------------------------- AXML (binary AndroidManifest)
namespace AXML {
static uint32_t ATTRID(const std::string& n) {
    if (n=="package") return 0u;              // 非 android:* 属性，无资源 ID —— 框架按字符串名匹配
    if (n=="versionCode") return 0x0101021Bu;
    if (n=="versionName") return 0x0101021Cu;
    if (n=="minSdkVersion") return 0x0101020Cu;
    if (n=="targetSdkVersion") return 0x01010270u;
    if (n=="label") return 0x01010001u;
    if (n=="hasCode") return 0x0101000Cu;
    if (n=="debuggable") return 0x0101000Fu;
    if (n=="name") return 0x01010003u;
    if (n=="exported") return 0x01010010u;
    if (n=="configChanges") return 0x0101001Fu;
    if (n=="value") return 0x01010024u;
    if (n=="theme") return 0x01010000u;
    if (n=="icon") return 0x01010002u;
    return 0;
}
struct Builder {
    std::vector<std::string> attrNames, others;
    std::vector<uint32_t> attrResids;
    std::map<std::string,int> idxMap;
    int nsUriIdx = -1, nsPrefixIdx = -1;
    int strIdx(const std::string& s, bool isAttr) {
        if (idxMap.count(s)) return idxMap[s];
        if (isAttr) { attrNames.push_back(s); attrResids.push_back(ATTRID(s)); }
        else others.push_back(s);
        int off = isAttr ? 0 : (int)attrNames.size();
        int i = off + (int)(isAttr ? attrNames.size()-1 : others.size()-1);
        idxMap[s] = i; return i;
    }
    void encLen(std::vector<uint8_t>& o, size_t n) { if (n < 0x80) o.push_back((uint8_t)n); else { o.push_back((uint8_t)(0x80|(n&0x7F))); o.push_back((uint8_t)(n>>7)); } }
    void encStr(std::vector<uint8_t>& o, const std::string& s) {
        std::vector<uint8_t> b(s.begin(), s.end());
        encLen(o, s.size()); encLen(o, b.size());
        o.insert(o.end(), b.begin(), b.end()); o.push_back(0x00);
    }
    struct Node { std::string name; std::vector<std::vector<std::string>> attrs; std::vector<Node> children; };
    std::vector<uint8_t> attrBytes(const std::string& aname, const std::string& kind, const std::string& val) {
        int nameIdx = strIdx(aname, true);
        std::vector<uint8_t> a;
        uint32_t ns = (aname=="package") ? 0xFFFFFFFFu : (uint32_t)nsUriIdx;
        uint32_t rawVal = 0xFFFFFFFFu; uint8_t dtype; uint32_t data = 0;
        if (kind=="str") { int vi = strIdx(val, false); rawVal = (uint32_t)vi; dtype=0x03; data=(uint32_t)vi; }
        else if (kind=="int") { dtype=0x10; data=(uint32_t)std::stoul(val); }
        else if (kind=="hex") { dtype=0x11; data=(uint32_t)std::stoul(val, nullptr, 0); }
        // TYPE_REFERENCE: the value is a resource id, not a number. Writing it
        // as TYPE_INT_HEX would make the id look right in a hex dump and still
        // resolve to nothing at runtime.
        else if (kind=="ref") { dtype=0x01; data=(uint32_t)std::stoul(val, nullptr, 0); }
        else { dtype=0x12; data=(val=="true")?0xFFFFFFFFu:0; }
        put32(a, ns); put32(a, (uint32_t)nameIdx); put32(a, rawVal);
        put16(a, 8); a.push_back(0x00); a.push_back(dtype); put32(a, data);
        return a;
    }
    std::vector<uint8_t> element(const Node& n) {
        int nameIdx = strIdx(n.name, false);
        std::vector<uint8_t> ab;
        for (auto& a : n.attrs) { auto x = attrBytes(a[0], a[1], a[2]); ab.insert(ab.end(), x.begin(), x.end()); }
        size_t acount = n.attrs.size();
        std::vector<uint8_t> start;
        put16(start, 0x0102); put16(start, 16); put32(start, (uint32_t)(36 + ab.size()));
        put32(start, 0); put32(start, 0xFFFFFFFFu); put32(start, 0xFFFFFFFFu); put32(start, (uint32_t)nameIdx);
        put16(start, 20); put16(start, 20); put16(start, (uint16_t)acount); put16(start, 0); put16(start, 0); put16(start, 0);
        std::vector<uint8_t> inner; for (auto& c : n.children) { std::vector<uint8_t> ec = element(c); inner.insert(inner.end(), ec.begin(), ec.end()); }
        std::vector<uint8_t> end;
        put16(end, 0x0103); put16(end, 16); put32(end, 24); put32(end, 0); put32(end, 0xFFFFFFFFu);
        put32(end, 0xFFFFFFFFu); put32(end, (uint32_t)nameIdx);
        std::vector<uint8_t> out; out.insert(out.end(), start.begin(), start.end()); out.insert(out.end(), ab.begin(), ab.end());
        out.insert(out.end(), inner.begin(), inner.end()); out.insert(out.end(), end.begin(), end.end());
        return out;
    }
    std::vector<uint8_t> build(const Node& root) {
        std::function<void(const Node&)> pre = [&](const Node& n){ for (auto& a : n.attrs) strIdx(a[0], true); for (auto& c : n.children) pre(c); };
        pre(root);
        nsUriIdx = strIdx("http://schemas.android.com/apk/res/android", false);
        nsPrefixIdx = strIdx("android", false);
        std::vector<uint8_t> body = element(root);
        std::vector<std::string> all = attrNames; all.insert(all.end(), others.begin(), others.end());
        std::vector<uint8_t> offs, data; size_t pos = 0;
        for (auto& s : all) {
            put32(offs, (uint32_t)pos);
            size_t before=data.size(); encStr(data, s); pos += (data.size()-before);
        }
        size_t count = all.size(); size_t stringsStart = 28 + 4*count;
        while (((stringsStart + data.size()) & 3) != 0) data.push_back(0x00);
        size_t spSize = stringsStart + data.size();
        std::vector<uint8_t> sp;
        put16(sp, 0x0001); put16(sp, 28); put32(sp, (uint32_t)spSize); put32(sp, (uint32_t)count);
        put32(sp, 0); put32(sp, 0x00000100); put32(sp, (uint32_t)stringsStart); put32(sp, 0);
        sp.insert(sp.end(), offs.begin(), offs.end()); sp.insert(sp.end(), data.begin(), data.end());
        std::vector<uint8_t> rm;
        put16(rm, 0x0180); put16(rm, 8); put32(rm, (uint32_t)(8 + 4*attrResids.size()));
        for (auto r : attrResids) put32(rm, r);
        auto nsChunk=[&](uint16_t t){ std::vector<uint8_t> c; put16(c, t); put16(c, 16); put32(c, 24); put32(c, 0); put32(c, 0xFFFFFFFFu); put32(c, (uint32_t)nsPrefixIdx); put32(c, (uint32_t)nsUriIdx); return c; };
        std::vector<uint8_t> nsStart = nsChunk(0x0100), nsEnd = nsChunk(0x0101);
        size_t total = 8 + sp.size() + rm.size() + nsStart.size() + body.size() + nsEnd.size();
        std::vector<uint8_t> hdr; put16(hdr, 0x0003); put16(hdr, 8); put32(hdr, (uint32_t)total);
        std::vector<uint8_t> out; out.insert(out.end(), hdr.begin(), hdr.end()); out.insert(out.end(), sp.begin(), sp.end());
        out.insert(out.end(), rm.begin(), rm.end()); out.insert(out.end(), nsStart.begin(), nsStart.end());
        out.insert(out.end(), body.begin(), body.end()); out.insert(out.end(), nsEnd.begin(), nsEnd.end());
        return out;
    }
};
// How the app name is spelled in the manifest (v0.23.7-dev).
//
// The aapt way is a resource id: `android:label` is a TYPE_REFERENCE into
// resources.arsc, so the name lives in exactly one place next to the icon. The
// framework resolves it, so an installed app shows the name either way.
//
// The default here is the *other* spelling, TYPE_STRING, because a reference is
// only a promise to go open the table, and a third-party APK viewer that parses
// the binary manifest and stops there never opens it — it shows a blank name
// for an app that is perfectly fine on the device. Both spellings are valid
// AXML; the literal is the one every consumer can read.
//
// `--label-as-reference` asks for the aapt spelling back. The table still holds
// string/app_name either way, and validate_apk.py [4d] checks that the two
// spellings agree, so they cannot drift apart unnoticed.
static std::vector<uint8_t> nativeActivity(const std::string& pkg, int verCode,
                                           const std::string& verName, int minSdk, int targetSdk,
                                           const std::string& libName, uint32_t iconResId,
                                           uint32_t labelResId,
                                           const std::string& labelLiteral) {
    char labelId[32]; std::snprintf(labelId, sizeof labelId, "0x%08X", labelResId);
    Builder b; Builder::Node activity; activity.name="activity";
    activity.attrs={{"name","str","android.app.NativeActivity"},{"label","ref",labelId},{"exported","bool","true"},{"configChanges","hex","0x490"}};
    if(!labelLiteral.empty()) activity.attrs[1]={"label","str",labelLiteral};
    Builder::Node metadata; metadata.name="meta-data";
    metadata.attrs={{"name","str","android.app.lib_name"},{"value","str",libName}};
    Builder::Node itfilter; itfilter.name="intent-filter";
    Builder::Node action; action.name="action"; action.attrs={{"name","str","android.intent.action.MAIN"}};
    Builder::Node category; category.name="category"; category.attrs={{"name","str","android.intent.category.LAUNCHER"}};
    itfilter.children={action,category}; activity.children={metadata,itfilter};
    Builder::Node application; application.name="application";
    application.attrs={{"label","ref",labelId},{"hasCode","bool","false"},{"debuggable","bool","true"}};
    if(!labelLiteral.empty()) application.attrs[0]={"label","str",labelLiteral};
    if (iconResId) {
        char id[32]; std::snprintf(id, sizeof id, "0x%08X", iconResId);
        application.attrs.insert(application.attrs.begin() + 1, {"icon","ref",id});
    }
    application.children={activity};
    Builder::Node usesSdk; usesSdk.name="uses-sdk";
    usesSdk.attrs={{"minSdkVersion","int",std::to_string(minSdk)},{"targetSdkVersion","int",std::to_string(targetSdk)}};
    Builder::Node manifest; manifest.name="manifest";
    manifest.attrs={{"package","str",pkg},{"versionCode","int",std::to_string(verCode)},{"versionName","str",verName}};
    manifest.children={usesSdk,application};
    return b.build(manifest);
}
} // namespace AXML

// ---------------------------------------------------------------- ZIP (store) writer
namespace ZIP {
struct Entry { std::string name; std::vector<uint8_t> data; uint32_t crc; size_t offset; };
static std::vector<uint8_t> localHeader(const std::string& name, uint32_t crc, size_t size) {
    std::vector<uint8_t> h; auto u16=[&](uint16_t v){ h.push_back(v&0xFF); h.push_back((v>>8)&0xFF); };
    auto u32=[&](uint32_t v){ h.push_back(v&0xFF); h.push_back((v>>8)&0xFF); h.push_back((v>>16)&0xFF); h.push_back((v>>24)&0xFF); };
    u32(0x04034b50); u16(20); u16(0); u16(0); u16(0); u16(0); u32(crc); u32((uint32_t)size); u32((uint32_t)size); u16((uint16_t)name.size()); u16(0);
    h.insert(h.end(), name.begin(), name.end()); return h;
}
static std::vector<uint8_t> centralHeader(const std::string& name, uint32_t crc, size_t size, size_t offset) {
    std::vector<uint8_t> h; auto u16=[&](uint16_t v){ h.push_back(v&0xFF); h.push_back((v>>8)&0xFF); };
    auto u32=[&](uint32_t v){ h.push_back(v&0xFF); h.push_back((v>>8)&0xFF); h.push_back((v>>16)&0xFF); h.push_back((v>>24)&0xFF); };
    u32(0x02014b50); u16(20); u16(20); u16(0); u16(0); u16(0); u16(0); u32(crc); u32((uint32_t)size); u32((uint32_t)size);
    u16((uint16_t)name.size()); u16(0); u16(0); u16(0); u16(0); u32(0); u32((uint32_t)offset);
    h.insert(h.end(), name.begin(), name.end()); return h;
}
}

// ---------------------------------------------------------------- APK Signature Scheme v2 (v0.23.3-dev, P2.1)
//
// A v2 signature lives in an "APK Signing Block" wedged between the last ZIP
// local entry and the ZIP Central Directory:
//
//   uint64   size of block (excluding this field)
//   pairs:   uint64 size (incl. the 4-byte ID) | uint32 ID | value
//   uint64   size of block (same as the first field)
//   uint128  magic "APK Sig Block 42"
//
// The v2 scheme's own ID is 0x7109871a. Everything inside is little-endian and
// uint32 length-prefixed, mirroring apksig:
//
//   signers:            lp(lp(signer))          -- outer length wraps the sequence
//   signer:             lp(signedData) lp(signatures) lp(publicKey)
//   signedData:         lp(digests) lp(certificates) lp(attributes) lp(<empty>)
//   digests:            each lp(lp(uint32 algID, digest))
//   signatures:         each lp(lp(uint32 algID, signature))
//
// The content digest covers three segments -- the ZIP entry region, the Central
// Directory and the EOCD -- each split into 1 MiB chunks; every chunk is hashed
// as {0xa5, uint32 chunkLen, chunk} and the result as
// {0x5a, uint32 chunkCount, chunkDigests...}. For digesting, the EOCD's
// "offset of start of central directory" is rewritten to the offset at which
// the APK Signing Block starts, so the record that gets hashed is not the one
// that ends up in the file.
namespace APKv2 {
static constexpr uint32_t kBlockId = 0x7109871a;
// RSASSA-PKCS1-v1_5 with SHA2-256, content digested with chunked SHA2-256.
// Chosen because PKCS#1 v1.5 is deterministic, so Aster's builds stay
// reproducible; the PSS variants (0x0101/0x0102) need a random salt.
static constexpr uint32_t kAlgRsaPkcs1Sha256 = 0x0103;
static constexpr size_t kChunk = 1024u * 1024u;

static void putU64(std::vector<uint8_t>& v, uint64_t x) {
    for (int k = 0; k < 8; ++k) v.push_back(uint8_t(x >> (k * 8)));
}
// length-prefixed bytes: uint32 length followed by that many bytes
static std::vector<uint8_t> lp(const std::vector<uint8_t>& d) {
    std::vector<uint8_t> o; put32(o, (uint32_t)d.size()); o.insert(o.end(), d.begin(), d.end()); return o;
}
// sequence of length-prefixed elements (no outer length -- callers wrap with lp() when needed)
static std::vector<uint8_t> lpseq(const std::vector<std::vector<uint8_t>>& es) {
    std::vector<uint8_t> o;
    for (const auto& e : es) { auto x = lp(e); o.insert(o.end(), x.begin(), x.end()); }
    return o;
}
// sequence of (uint32 key, length-prefixed bytes) pairs
static std::vector<uint8_t> lppairs(const std::vector<std::pair<uint32_t, std::vector<uint8_t>>>& ps) {
    std::vector<uint8_t> o;
    for (const auto& p : ps) { put32(o, (uint32_t)(8 + p.second.size())); put32(o, p.first); auto x = lp(p.second); o.insert(o.end(), x.begin(), x.end()); }
    return o;
}

struct Seg { const uint8_t* p; size_t n; };

// Chunked ("Merkle-ish") digest over the integrity-protected segments.
static std::vector<uint8_t> contentDigest(const std::vector<Seg>& segs) {
    uint64_t total = 0;
    for (const auto& s : segs) total += (s.n + kChunk - 1) / kChunk;
    if (total > 0xFFFFFFFFull) throw Error("build-apk: APK too large for a v2 signature");
    uint32_t chunkCount = (uint32_t)total;
    std::vector<uint8_t> top(5 + (size_t)chunkCount * 32, 0);
    top[0] = 0x5a;
    for (int k = 0; k < 4; ++k) top[1 + k] = uint8_t(chunkCount >> (k * 8));
    uint32_t idx = 0;
    uint8_t prefix[5] = {0xa5, 0, 0, 0, 0};
    for (const auto& s : segs) {
        size_t off = 0;
        while (off < s.n) {
            size_t sz = s.n - off < kChunk ? s.n - off : kChunk;
            for (int k = 0; k < 4; ++k) prefix[1 + k] = uint8_t((uint32_t)sz >> (k * 8));
            SHA256 md; md.upd(prefix, 5); md.upd(s.p + off, sz);
            std::vector<uint8_t> d = md.fin();
            memcpy(&top[5 + (size_t)idx * 32], d.data(), 32);
            ++idx; off += sz;
        }
    }
    SHA256 md; md.upd(top.data(), top.size()); return md.fin();
}

// Build the whole "APK Sig Block 42" carrying a single v2 signer. The DER
// reader it uses to lift the public key out of the certificate is the shared
// one at file scope, so the v2 public key can never drift from the certificate.
static std::vector<uint8_t> signingBlock(const std::vector<uint8_t>& contentDigest,
                                         const SigningKey& key) {
    const std::vector<uint8_t> digests = lppairs({{kAlgRsaPkcs1Sha256, contentDigest}});
    const std::vector<uint8_t> certificates = lpseq({key.certDER});
    const std::vector<uint8_t> attributes;      // no v3, so no stripping-protection attribute
    const std::vector<uint8_t> signedData = lpseq({digests, certificates, attributes, {}});
    SHA256 sd; sd.upd(signedData.data(), signedData.size());
    const std::vector<uint8_t> sig = rsaSign(sd.fin(), key);
    const std::vector<uint8_t> signatures = lppairs({{kAlgRsaPkcs1Sha256, sig}});
    const std::vector<uint8_t> signer = lpseq({signedData, signatures, key.spki});
    const std::vector<uint8_t> v2 = lp(lpseq({signer}));

    std::vector<uint8_t> pair;
    putU64(pair, (uint64_t)(4 + v2.size()));
    put32(pair, kBlockId);
    pair.insert(pair.end(), v2.begin(), v2.end());

    std::vector<uint8_t> out;
    const uint64_t blockSize = (uint64_t)(pair.size() + 24);  // 8 size + pairs + 8 size + 16 magic
    putU64(out, blockSize);
    out.insert(out.end(), pair.begin(), pair.end());
    putU64(out, blockSize);
    static const char magic[16] = {'A','P','K',' ','S','i','g',' ','B','l','o','c','k',' ','4','2'};
    out.insert(out.end(), magic, magic + 16);
    return out;
}
} // namespace APKv2

// ============================== APK verification ==============================
// build-apk signs and verify-apk checks. They share the constants and the
// chunked-digest code above and deliberately share nothing else: the verifier
// re-reads the file the way an independent consumer would instead of trusting
// the structures the builder still has in memory, because a builder checking its
// own in-memory state would happily confirm a file it never wrote correctly.
namespace Verify {

struct ZipEntry {
    std::string name;
    uint32_t crc = 0, compSize = 0;
    uint16_t method = 0;
    size_t dataOff = 0;
};
struct Zip {
    std::vector<ZipEntry> entries;
    size_t cdStart = 0, cdSize = 0, eocdOff = 0;
    uint16_t entryCount = 0;
};

static uint16_t rd16(const std::vector<uint8_t>& b, size_t p) { return (uint16_t)(b[p] | ((uint16_t)b[p + 1] << 8)); }
static uint32_t rd32(const std::vector<uint8_t>& b, size_t p) {
    return (uint32_t)b[p] | ((uint32_t)b[p + 1] << 8) | ((uint32_t)b[p + 2] << 16) | ((uint32_t)b[p + 3] << 24);
}
static uint64_t rd64(const std::vector<uint8_t>& b, size_t p) {
    uint64_t v = 0;
    for (int k = 7; k >= 0; --k) v = (v << 8) | b[p + k];
    return v;
}

static bool readZip(const std::vector<uint8_t>& b, Zip& z, std::string& err) {
    if (b.size() < 22) { err = "file is smaller than an End of Central Directory record"; return false; }
    const size_t minI = b.size() > 65557 + 22 ? b.size() - 65557 - 22 : 0;
    bool found = false;
    for (size_t i = b.size() - 22; ; --i) {
        if (rd32(b, i) == 0x06054b50u) { z.eocdOff = i; found = true; break; }
        if (i == minI) break;
    }
    if (!found) { err = "no End of Central Directory record"; return false; }
    z.entryCount = rd16(b, z.eocdOff + 10);
    z.cdSize = rd32(b, z.eocdOff + 12);
    z.cdStart = rd32(b, z.eocdOff + 16);
    if ((uint64_t)z.cdStart + z.cdSize > b.size() || z.cdStart + z.cdSize != z.eocdOff) {
        err = "the central directory does not end where the EOCD starts"; return false;
    }
    size_t p = z.cdStart;
    const size_t end = z.cdStart + z.cdSize;
    while (p + 46 <= end) {
        if (rd32(b, p) != 0x02014b50u) { err = "a central directory entry has a bad signature"; return false; }
        ZipEntry ze;
        ze.method = rd16(b, p + 10);
        ze.crc = rd32(b, p + 16);
        ze.compSize = rd32(b, p + 20);
        const uint16_t nameLen = rd16(b, p + 28), extraLen = rd16(b, p + 30), commentLen = rd16(b, p + 32);
        const size_t localOff = rd32(b, p + 42);
        ze.name.assign(b.begin() + (long)(p + 46), b.begin() + (long)(p + 46 + nameLen));
        if (localOff + 30 > b.size() || rd32(b, localOff) != 0x04034b50u) {
            err = "entry " + ze.name + " has a bad local header"; return false;
        }
        if (rd32(b, localOff + 14) != ze.crc) { err = "entry " + ze.name + ": local header and central directory disagree on CRC-32"; return false; }
        ze.dataOff = localOff + 30 + rd16(b, localOff + 26) + rd16(b, localOff + 28);
        if (ze.dataOff + ze.compSize > b.size()) { err = "entry " + ze.name + " runs past the end of the file"; return false; }
        z.entries.push_back(ze);
        p += 46 + nameLen + extraLen + commentLen;
    }
    if (z.entries.size() != z.entryCount) { err = "central directory entry count disagrees with the EOCD"; return false; }
    return true;
}
static const ZipEntry* findEntry(const Zip& z, const std::string& name) {
    for (const ZipEntry& e : z.entries) if (e.name == name) return &e;
    return nullptr;
}
static std::vector<uint8_t> entryData(const std::vector<uint8_t>& b, const ZipEntry& e) {
    return std::vector<uint8_t>(b.begin() + (long)e.dataOff, b.begin() + (long)(e.dataOff + e.compSize));
}

// --- JAR (v1) signature files
struct JarSection {
    std::string name;                                   // empty for the main section
    std::string raw;                                    // section text, blank-line terminator included
    std::map<std::string, std::string> attrs;
};
static std::vector<JarSection> parseJarFile(const std::string& text) {
    std::vector<JarSection> out;
    size_t p = 0;
    while (p < text.size()) {
        size_t e = text.find("\r\n\r\n", p);
        if (e == std::string::npos) { out.push_back({}); out.back().raw = text.substr(p); break; }
        out.push_back({});
        out.back().raw = text.substr(p, e - p + 2);     // keep the section's own trailing CRLF
        p = e + 4;
    }
    for (JarSection& s : out) {
        std::string line, lastKey;
        for (size_t i = 0; i <= s.raw.size(); ++i) {
            const bool atEnd = (i == s.raw.size());
            if (!atEnd && s.raw[i] != '\n') { line.push_back(s.raw[i]); continue; }
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (!line.empty()) {
                if (line[0] == ' ') { if (!lastKey.empty()) s.attrs[lastKey] += line.substr(1); }
                else {
                    const size_t colon = line.find(": ");
                    if (colon != std::string::npos) { lastKey = line.substr(0, colon); s.attrs[lastKey] = line.substr(colon + 2); }
                    else lastKey.clear();
                }
            }
            line.clear();
            if (atEnd) break;
        }
        auto it = s.attrs.find("Name");
        if (it != s.attrs.end()) s.name = it->second;
    }
    return out;
}

// --- PKCS#7 SignedData (v1)
static bool pkcs7Verify(const std::vector<uint8_t>& sf, const std::vector<uint8_t>& p7,
                        std::vector<uint8_t>& certOut, std::string& err) {
    static const uint8_t oidMsgDigest[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x09,0x04};
    static const uint8_t oidContentType[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x09,0x03};
    static const uint8_t oidIdData[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x07,0x01};
    DerNode ci;
    if (!derAt(p7, 0, ci) || ci.tag != 0x30) { err = "CERT.RSA is not a DER SEQUENCE"; return false; }
    const std::vector<DerNode> ciKids = derChildren(p7, ci);
    if (ciKids.size() != 2 || ciKids[1].tag != 0xA0) { err = "CERT.RSA is not a PKCS#7 ContentInfo"; return false; }
    DerNode sd;
    if (!derAt(p7, ciKids[1].hdr, sd) || sd.tag != 0x30) { err = "CERT.RSA has no SignedData"; return false; }
    const std::vector<DerNode> sdKids = derChildren(p7, sd);
    if (sdKids.size() < 5 || sdKids[3].tag != 0xA0 || sdKids[4].tag != 0x31) {
        err = "SignedData layout is not the one Aster emits"; return false;
    }
    DerNode cert0;
    if (!derAt(p7, sdKids[3].hdr, cert0) || cert0.tag != 0x30) { err = "SignedData carries no certificate"; return false; }
    certOut = derSlice(p7, cert0);
    DerNode si;
    if (!derAt(p7, sdKids[4].hdr, si) || si.tag != 0x30) { err = "SignedData carries no SignerInfo"; return false; }
    const std::vector<DerNode> siKids = derChildren(p7, si);
    if (siKids.size() != 5 && siKids.size() != 6) { err = "SignerInfo layout is unexpected"; return false; }
    const bool hasAttrs = (siKids.size() == 6);
    const DerNode& sigNode = hasAttrs ? siKids[5] : siKids[4];
    if (sigNode.tag != 0x04) { err = "the SignerInfo signature is not an OCTET STRING"; return false; }
    const std::vector<uint8_t> sig(p7.begin() + (long)sigNode.hdr, p7.begin() + (long)(sigNode.hdr + sigNode.len));

    std::vector<uint8_t> toHash;
    if (hasAttrs) {
        const DerNode& sa = siKids[3];
        if (sa.tag != 0xA0) { err = "signed attributes are not tagged [0]"; return false; }
        bool mdOk = false, ctOk = false;
        for (const DerNode& attr : derChildren(p7, sa)) {
            if (attr.tag != 0x30) continue;
            const std::vector<DerNode> ak = derChildren(p7, attr);
            if (ak.size() != 2 || ak[0].tag != 0x06 || ak[1].tag != 0x31) continue;
            const bool isMd = ak[0].len == sizeof(oidMsgDigest) &&
                              memcmp(p7.data() + ak[0].hdr, oidMsgDigest, sizeof(oidMsgDigest)) == 0;
            const bool isCt = ak[0].len == sizeof(oidContentType) &&
                              memcmp(p7.data() + ak[0].hdr, oidContentType, sizeof(oidContentType)) == 0;
            const std::vector<DerNode> vals = derChildren(p7, ak[1]);
            if (vals.size() != 1) continue;
            if (isMd && vals[0].tag == 0x04) {
                SHA256 md; md.upd(sf.data(), sf.size());
                mdOk = std::vector<uint8_t>(p7.begin() + (long)vals[0].hdr,
                                            p7.begin() + (long)(vals[0].hdr + vals[0].len)) == md.fin();
            }
            if (isCt && vals[0].tag == 0x06)
                ctOk = vals[0].len == sizeof(oidIdData) &&
                       memcmp(p7.data() + vals[0].hdr, oidIdData, sizeof(oidIdData)) == 0;
        }
        if (!mdOk) { err = "the signed message-digest attribute does not match SHA-256(CERT.SF)"; return false; }
        if (!ctOk) { err = "the signed content-type attribute is not id-data"; return false; }
        // RFC 5652 5.4: the bytes that were signed are the signed attributes
        // re-tagged from IMPLICIT [0] to SET OF. Length is unchanged, and the
        // attributes are never re-encoded -- DER SET OF ordering would be a
        // second, avoidable chance to get it wrong.
        toHash = derSlice(p7, sa);
        toHash[0] = 0x31;
    } else {
        toHash = sf;
    }
    std::vector<uint8_t> n, e;
    rsaPublicKey(certSubjectPublicKeyInfo(certOut), n, e, "the APK certificate");
    SHA256 md; md.upd(toHash.data(), toHash.size());
    if (!rsaVerify(md.fin(), sig, n, e)) { err = "the PKCS#7 signature did not verify"; return false; }
    return true;
}

// --- APK Signing Block (v2)
static bool findSigningBlock(const std::vector<uint8_t>& b, const Zip& z, size_t& sbStart, size_t& sbEnd,
                             std::string& err) {
    if (z.cdStart < 24) { err = "no APK Signing Block (the central directory starts too early)"; return false; }
    static const char magic[16] = {'A','P','K',' ','S','i','g',' ','B','l','o','c','k',' ','4','2'};
    if (memcmp(b.data() + z.cdStart - 16, magic, 16) != 0) { err = "no APK Signing Block magic"; return false; }
    const uint64_t size2 = rd64(b, z.cdStart - 24);
    if (size2 < 24 || size2 + 8 > z.cdStart) { err = "APK Signing Block size is out of range"; return false; }
    sbEnd = z.cdStart;
    sbStart = z.cdStart - (size_t)size2 - 8;
    if (rd64(b, sbStart) != size2) { err = "the two APK Signing Block size fields disagree"; return false; }
    return true;
}
static bool lpRead(const std::vector<uint8_t>& b, size_t p, size_t end, std::vector<uint8_t>& out, size_t& next) {
    if (p + 4 > end || p + 4 > b.size()) return false;
    const uint32_t n = rd32(b, p);
    if ((size_t)n > end - p - 4) return false;
    out.assign(b.begin() + (long)(p + 4), b.begin() + (long)(p + 4 + n));
    next = p + 4 + n;
    return true;
}
// Sequence of (uint64 length, uint32 ID, value) as the Signing Block writer
// emits it. The length prefix here is 64-bit -- unlike the uint32 one used for
// the pairs nested inside a v2 block -- and counts the ID plus the value.
static bool readPairs(const std::vector<uint8_t>& b,
                      std::vector<std::pair<uint32_t, std::vector<uint8_t>>>& out) {
    size_t p = 0;
    while (p < b.size()) {
        if (b.size() - p < 12) return false;                 // need len + id, and a pair is never empty
        const uint64_t pairLen = rd64(b, p);
        if (pairLen < 4 || pairLen > 0xFFFFFFFFull) return false;
        const size_t total = 8 + (size_t)pairLen;            // the length counts the ID and the value, not itself
        if (total > b.size() - p) return false;
        const uint32_t id = rd32(b, p + 8);
        out.push_back({id, std::vector<uint8_t>(b.begin() + (long)(p + 12), b.begin() + (long)(p + total))});
        p += total;
    }
    return true;
}
// The same idea one level down: the pairs nested inside a v2 block (digests,
// signatures) carry a 32-bit length, and their value is itself length-prefixed.
static bool readPairs32(const std::vector<uint8_t>& b,
                        std::vector<std::pair<uint32_t, std::vector<uint8_t>>>& out) {
    size_t p = 0;
    while (p < b.size()) {
        if (b.size() - p < 8) return false;
        const uint32_t len = rd32(b, p);
        if (len < 4 || (size_t)len > b.size() - p - 4) return false;
        out.push_back({rd32(b, p + 4),
                       std::vector<uint8_t>(b.begin() + (long)(p + 8), b.begin() + (long)(p + 4 + len))});
        p += 4 + (size_t)len;
    }
    return true;
}

struct Report {
    bool ok = true;
    std::ostream* log = nullptr;
    void pass(const std::string& m) { *log << "    OK:   " << m << "\n"; }
    void fail(const std::string& m) { ok = false; *log << "    FAIL: " << m << "\n"; }
};

// Every check, in order. Returns true only if all of them pass.
static bool verify(const std::vector<uint8_t>& b, std::ostream& log) {
    Report r; r.log = &log;

    *r.log << "[1] ZIP structure\n";
    Zip z;
    std::string err;
    if (!readZip(b, z, err)) { r.fail(err); return false; }
    r.pass("EOCD at " + std::to_string(z.eocdOff) + ": " + std::to_string(z.entries.size()) +
           " entries, central directory at " + std::to_string(z.cdStart));
    bool crcOk = true, compressed = false;
    for (const ZipEntry& e : z.entries) {
        if (e.method != 0) { compressed = true; continue; }
        if (crc32(b.data() + e.dataOff, e.compSize) != e.crc) { crcOk = false; r.fail("entry " + e.name + ": CRC-32 mismatch"); }
    }
    if (crcOk) r.pass("every stored entry's CRC-32 matches its central directory record");

    *r.log << "[2] v1 (JAR) signature\n";
    const ZipEntry *mfE = findEntry(z, "META-INF/MANIFEST.MF"),
                   *sfE = findEntry(z, "META-INF/CERT.SF"),
                   *rsaE = findEntry(z, "META-INF/CERT.RSA");
    if (!mfE || !sfE || !rsaE) { r.fail("META-INF/MANIFEST.MF, CERT.SF or CERT.RSA is missing"); return false; }
    if (mfE->method != 0 || sfE->method != 0 || rsaE->method != 0) {
        r.fail("the META-INF signature files are compressed; this verifier reads stored entries only");
        return false;
    }
    const std::vector<uint8_t> mf = entryData(b, *mfE), sf = entryData(b, *sfE), p7 = entryData(b, *rsaE);
    const std::string mfText(mf.begin(), mf.end()), sfText(sf.begin(), sf.end());
    const std::vector<JarSection> mfSecs = parseJarFile(mfText), sfSecs = parseJarFile(sfText);

    size_t checked = 0;
    for (const JarSection& s : mfSecs) {
        if (s.name.empty()) continue;
        const ZipEntry* target = findEntry(z, s.name);
        if (!target) { r.fail("MANIFEST.MF covers " + s.name + ", which is not in the archive"); continue; }
        if (target->method != 0) continue;
        auto it = s.attrs.find("SHA-256-Digest");
        if (it == s.attrs.end()) { r.fail("MANIFEST.MF section for " + s.name + " has no SHA-256-Digest"); continue; }
        SHA256 md; md.upd(b.data() + target->dataOff, target->compSize);
        if (b64decode(it->second) != md.fin()) { r.fail("MANIFEST.MF digest for " + s.name + " does not match the entry"); continue; }
        ++checked;
    }
    if (checked) r.pass("MANIFEST.MF: " + std::to_string(checked) + " entries, every SHA-256-Digest matches");

    bool manifestDigestOk = false;
    for (const JarSection& s : sfSecs)
        if (s.name.empty()) {
            auto it = s.attrs.find("SHA-256-Digest-Manifest");
            if (it != s.attrs.end()) {
                SHA256 md; md.upd(mf.data(), mf.size());
                manifestDigestOk = (b64decode(it->second) == md.fin());
            }
        }
    if (manifestDigestOk) r.pass("CERT.SF SHA-256-Digest-Manifest matches SHA-256(MANIFEST.MF)");
    else r.fail("CERT.SF has no SHA-256-Digest-Manifest matching SHA-256(MANIFEST.MF)");

    size_t sfChecked = 0;
    for (const JarSection& s : sfSecs) {
        if (s.name.empty()) continue;
        auto it = s.attrs.find("SHA-256-Digest");
        if (it == s.attrs.end()) continue;
        for (const JarSection& m : mfSecs)
            if (m.name == s.name) {
                SHA256 md; md.upd((const uint8_t*)m.raw.data(), m.raw.size());
                if (b64decode(it->second) != md.fin()) r.fail("CERT.SF digest for " + s.name + " does not match MANIFEST.MF");
                else ++sfChecked;
            }
    }
    if (sfChecked) r.pass("CERT.SF: " + std::to_string(sfChecked) + " per-entry digests match MANIFEST.MF");

    std::vector<uint8_t> v1Cert;
    if (pkcs7Verify(sf, p7, v1Cert, err)) r.pass("CERT.RSA PKCS#7 signature over CERT.SF verified (RSASSA-PKCS1-v1_5 / SHA-256)");
    else r.fail(err);

    *r.log << "[3] v2 (APK Signing Block) signature\n";
    size_t sbStart = 0, sbEnd = 0;
    bool v2Present = findSigningBlock(b, z, sbStart, sbEnd, err);
    if (!v2Present) { r.fail(err); return false; }
    r.pass("Signing Block at [" + std::to_string(sbStart) + ", " + std::to_string(sbEnd) + "): " +
           std::to_string(sbEnd - sbStart) + " bytes, size fields agree, central directory follows immediately");
    std::vector<std::pair<uint32_t, std::vector<uint8_t>>> pairs;
    if (!readPairs(std::vector<uint8_t>(b.begin() + (long)(sbStart + 8), b.begin() + (long)(sbEnd - 24)), pairs)) {
        r.fail("the Signing Block's ID-value pairs are malformed"); return false;
    }
    std::string ids;
    for (const auto& pr : pairs)
        ids += (ids.empty() ? "" : ", ") + std::string("0x") + [&] {
            char buf[16]; snprintf(buf, sizeof(buf), "%08x", pr.first); return std::string(buf);
        }();
    r.pass("ID-value pairs: " + ids);
    const std::vector<uint8_t>* v2Blob = nullptr;
    for (const auto& pr : pairs) if (pr.first == APKv2::kBlockId) v2Blob = &pr.second;
    if (!v2Blob) { r.fail("no v2 block (0x7109871a) in the Signing Block"); return false; }
    if (!compressed) {}   // unused here; kept for readability

    std::vector<uint8_t> signersBlob, signer, signedData, signatures, publicKey, digests, certificates;
    size_t q = 0;
    if (!lpRead(*v2Blob, 0, v2Blob->size(), signersBlob, q) ||
        !lpRead(signersBlob, 0, signersBlob.size(), signer, q) ||
        !lpRead(signer, 0, signer.size(), signedData, q) ||
        !lpRead(signer, q, signer.size(), signatures, q) ||
        !lpRead(signer, q, signer.size(), publicKey, q) ||
        !lpRead(signedData, 0, signedData.size(), digests, q) ||
        !lpRead(signedData, q, signedData.size(), certificates, q)) {
        r.fail("the v2 signer does not parse"); return false;
    }
    std::vector<std::pair<uint32_t, std::vector<uint8_t>>> digestPairs, sigPairs, digestRaw, sigRaw;
    std::vector<uint8_t> v2Cert;
    if (!readPairs32(digests, digestRaw) || !readPairs32(signatures, sigRaw) ||
        digestRaw.empty() || sigRaw.empty()) {
        r.fail("the v2 digests or signatures do not parse"); return false;
    }
    // Each pair's value is itself length-prefixed, so unwrap one layer before
    // comparing it with a digest or feeding it to the RSA verifier.
    auto unwrap = [](const std::vector<std::pair<uint32_t, std::vector<uint8_t>>>& in,
                     std::vector<std::pair<uint32_t, std::vector<uint8_t>>>& out) {
        for (const auto& pr : in) {
            std::vector<uint8_t> v; size_t nx = 0;
            if (!lpRead(pr.second, 0, pr.second.size(), v, nx) || nx != pr.second.size()) return false;
            out.push_back({pr.first, v});
        }
        return true;
    };
    if (!unwrap(digestRaw, digestPairs) || !unwrap(sigRaw, sigPairs)) {
        r.fail("the v2 digests or signatures are not length-prefixed properly"); return false;
    }
    { std::vector<uint8_t> first; size_t qq; lpRead(certificates, 0, certificates.size(), first, qq); v2Cert = first; }
    r.pass("v2 block parses: signed-data " + std::to_string(signedData.size()) + " B, public key " +
           std::to_string(publicKey.size()) + " B, 1 certificate");

    if (publicKey == certSubjectPublicKeyInfo(v2Cert))
        r.pass("the v2 public key is the certificate's SubjectPublicKeyInfo");
    else r.fail("the v2 public key does not match the certificate it carries");

    // Recompute the content digest exactly as apksig does: entries, central
    // directory, and an EOCD whose central-directory offset points at the
    // Signing Block instead of at the real central directory.
    std::vector<uint8_t> eocdForDigest(b.begin() + (long)z.eocdOff, b.end());
    for (int k = 0; k < 4; ++k) eocdForDigest[16 + k] = (uint8_t)((uint32_t)sbStart >> (k * 8));
    const std::vector<uint8_t> want = APKv2::contentDigest({
        {b.data(), sbStart},
        {b.data() + z.cdStart, z.cdSize},
        {eocdForDigest.data(), eocdForDigest.size()}});
    bool digestOk = false;
    for (const auto& pr : digestPairs) if (pr.first == APKv2::kAlgRsaPkcs1Sha256) digestOk = (pr.second == want);
    if (digestOk) r.pass("the v2 content digest recomputed over entries + central directory + EOCD matches");
    else r.fail("the v2 content digest does not match the APK as it stands on disk");

    std::vector<uint8_t> n, e;
    rsaPublicKey(publicKey, n, e, "the v2 public key");
    SHA256 sdHash; sdHash.upd(signedData.data(), signedData.size());
    bool sigOk = false;
    for (const auto& pr : sigPairs)
        if (pr.first == APKv2::kAlgRsaPkcs1Sha256) sigOk = rsaVerify(sdHash.fin(), pr.second, n, e);
    if (sigOk) r.pass("the v2 signature over signed-data verified (RSASSA-PKCS1-v1_5 / SHA-256)");
    else r.fail("the v2 signature over signed-data did not verify");

    *r.log << "[4] cross-scheme checks\n";
    if (v1Cert == v2Cert) r.pass("v1 and v2 were made with the same certificate");
    else r.fail("v1 and v2 carry different certificates");
    std::string declared;
    for (const JarSection& s : sfSecs)
        if (s.name.empty()) { auto it = s.attrs.find("X-Android-APK-Signed"); if (it != s.attrs.end()) declared = it->second; }
    if (declared.find("2") != std::string::npos)
        r.pass("CERT.SF declares X-Android-APK-Signed: " + declared + " -- deleting the v2 block is detectable");
    else r.fail("CERT.SF does not declare X-Android-APK-Signed: 2, so the v2 block could be stripped unnoticed");
    return r.ok;
}
} // namespace Verify

// --string NAME=VALUE: an extra string resource for the table. The name has to
// be one the resource system accepts — it becomes a key in resources.arsc, and
// a key with a space or a slash in it is not one AssetManager will ever match.
static bool validResourceName(const std::string& s) {
    if (s.empty()) return false;
    unsigned char c0 = (unsigned char)s[0];
    if (!(std::isalpha(c0) || s[0] == '_')) return false;
    for (char c : s) {
        unsigned char u = (unsigned char)c;
        if (!(std::isalnum(u) || c == '_' || c == '.')) return false;
    }
    return true;
}
static void addStringResource(const std::string& arg,
                              std::vector<std::pair<std::string,std::string>>& out,
                              const char* what) {
    size_t eq = arg.find('=');
    if (eq == std::string::npos || eq == 0)
        throw Error(std::string(what) + ": --string expects NAME=VALUE (got \"" + arg + "\")");
    std::string name = arg.substr(0, eq), value = arg.substr(eq + 1);
    if (!validResourceName(name))
        throw Error(std::string(what) + ": --string name is not a valid resource name (got \"" + name + "\"): "
                    "letters, digits, '_' and '.' only, starting with a letter or '_'");
    for (const auto& p : out) if (p.first == name)
        throw Error(std::string(what) + ": duplicate --string resource: " + name);
    out.push_back({name, value});
}
// ---------------------------------------------------------------- buildApk : assemble + sign the whole APK
static int buildApk(const std::string& out, const std::string& pkg, const std::string& libname,
                    const std::string& abi, const std::vector<uint8_t>& so, int minSdk, int targetSdk,
                    const std::string& label, int verCode, const std::string& verName,
                    const std::vector<std::pair<std::string,std::string>>& extraStrings,
                    const SigningKey& key, bool selfVerify, bool labelAsReference) {
    // The icon is part of the package rather than an option: a launcher entry
    // with no icon falls back to the system default, which is the thing this
    // exists to fix. res/drawable-nodpi keeps the bitmap exact — Android will
    // not pre-scale it for a density, and the launcher asks for the size it
    // wants anyway.
    //
    // The table is built by adding resources and asking it for the ids it gave
    // them, so the id a manifest attribute points at and the id in the table
    // cannot drift apart — there is only one place that assigns them.
    const std::string iconName = "ic_launcher";
    const std::string iconPath = "res/drawable-nodpi/" + iconName + ".png";
    ARSC::Table table;
    ARSC::Entry iconEntry; iconEntry.type="drawable"; iconEntry.name=iconName;
    iconEntry.value=iconPath; iconEntry.isFile=true;          // a path the AssetManager opens
    table.add(iconEntry);
    ARSC::Entry nameEntry; nameEntry.type="string"; nameEntry.name="app_name";
    nameEntry.value=label; nameEntry.isFile=false;            // the value itself, nothing to open
    table.add(nameEntry);
    for (const auto& s : extraStrings) {
        ARSC::Entry e; e.type="string"; e.name=s.first; e.value=s.second; table.add(e);
    }
    const uint32_t iconResId  = table.resId("drawable", iconName);    // 0x7f010000
    const uint32_t labelResId = table.resId("string",   "app_name");  // 0x7f020000
    std::vector<uint8_t> icon = PNG::build(192, 192);
    std::vector<uint8_t> arsc = ARSC::build(pkg, table);
    std::vector<uint8_t> manifest = AXML::nativeActivity(pkg, verCode, verName, minSdk, targetSdk,
                                                       libname, iconResId, labelResId,
                                                       labelAsReference ? std::string() : label);
    std::vector<ZIP::Entry> entries; std::vector<uint8_t> apk;
    auto append=[&](const std::string& name, const std::vector<uint8_t>& data, bool align){
        uint32_t crc=crc32(data.data(), data.size()); size_t off=apk.size();
        if (align) { size_t lh = 30 + name.size(); size_t pad = (4096 - ((off + lh) % 4096)) % 4096; if (pad) apk.insert(apk.end(), pad, 0); off = apk.size(); }
        auto lh=ZIP::localHeader(name, crc, data.size());
        apk.insert(apk.end(), lh.begin(), lh.end()); apk.insert(apk.end(), data.begin(), data.end());
        ZIP::Entry e; e.name=name; e.data=data; e.crc=crc; e.offset=off; entries.push_back(e);
    };
    append("AndroidManifest.xml", manifest, false);
    append(iconPath, icon, false);
    // The resource table is 4-byte aligned by construction, so it needs no
    // padding of its own; the loader reads it by mmap and asks for that.
    append("resources.arsc", arsc, false);
    std::string soname = "lib/" + abi + "/lib" + libname + ".so";
    append(soname, so, true);
    std::string mf = "Manifest-Version: 1.0\r\nCreated-By: Aster " + std::string(kVersion) + "\r\n\r\n";
    auto addMF=[&](const std::string& n, const std::vector<uint8_t>& d){ SHA256 s; s.upd(d.data(), d.size()); std::vector<uint8_t> h=s.fin(); mf += "Name: "+n+"\r\nSHA-256-Digest: "+b64(h)+"\r\n\r\n"; };
    addMF("AndroidManifest.xml", manifest); addMF(iconPath, icon);
    addMF("resources.arsc", arsc); addMF(soname, so);
    std::vector<uint8_t> mfBytes(mf.begin(), mf.end());
    std::string sf = "Signature-Version: 1.0\r\nCreated-By: Aster " + std::string(kVersion) + "\r\n";
    // Anti-stripping: Android rejects an APK whose v1 signature does not
    // declare the newer schemes it was also signed with, because otherwise a
    // v2/v3 block could simply be deleted and the APK downgraded to v1.
    sf += "X-Android-APK-Signed: 2\r\n";
    SHA256 dm; dm.upd(mfBytes.data(), mfBytes.size()); std::vector<uint8_t> dmh=dm.fin();
    sf += "SHA-256-Digest-Manifest: " + b64(dmh) + "\r\n\r\n";
    std::string mfStr=mf;
    for (auto& e : entries) {
        size_t p = mfStr.find("Name: " + e.name + "\r\n"); if (p==std::string::npos) continue;
        size_t end = mfStr.find("\r\n\r\n", p); std::string section = mfStr.substr(p, end - p + 2);
        SHA256 s; s.upd((const uint8_t*)section.data(), section.size()); std::vector<uint8_t> h=s.fin();
        sf += "Name: " + e.name + "\r\nSHA-256-Digest: " + b64(h) + "\r\n\r\n";
    }
    std::vector<uint8_t> sfBytes(sf.begin(), sf.end());
    // issuer + serial identify the signer inside the PKCS#7 blob, so they come
    // from the certificate actually in use instead of being constants.
    const std::vector<uint8_t>& cert = key.certDER;
    const std::vector<uint8_t>& issuer = key.issuerDER;
    const std::vector<uint8_t> serial = key.serial;
    const std::vector<uint8_t> sha256oid={0x60,0x86,0x48,0x01,0x65,0x03,0x04,0x02,0x01};
    const std::vector<uint8_t> rsaoid={0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x01,0x01};
    const std::vector<uint8_t> dataoid={0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x07,0x01};
    const std::vector<uint8_t> signedoid={0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x07,0x02};
    const std::vector<uint8_t> ctoid={0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x09,0x03};
    const std::vector<uint8_t> mdoid={0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x09,0x04};
    auto algId=[&](const std::vector<uint8_t>& oid){ return derSeq(concat(derOID(oid), std::vector<uint8_t>{0x05,0x00})); };
    std::vector<uint8_t> ctAttr=derSeq(concat(derOID(ctoid), derSet(derOID(dataoid))));
    SHA256 sm; sm.upd(sfBytes.data(), sfBytes.size()); std::vector<uint8_t> sfHash=sm.fin();
    std::vector<uint8_t> mdAttr=derSeq(concat(derOID(mdoid), derSet(derOctet(sfHash))));
    std::vector<uint8_t> authContent; authContent.insert(authContent.end(), ctAttr.begin(), ctAttr.end()); authContent.insert(authContent.end(), mdAttr.begin(), mdAttr.end());
    std::vector<uint8_t> authSet=derSet(authContent);
    SHA256 sa; sa.upd(authSet.data(), authSet.size()); std::vector<uint8_t> authHash=sa.fin();
    std::vector<uint8_t> sig=rsaSign(authHash, key);
    std::vector<uint8_t> issuerSerial=derSeq(concat(issuer, derInt(serial)));
    std::vector<uint8_t> A1 = concat(concat(derInt(1), issuerSerial), algId(sha256oid));
    std::vector<uint8_t> B1 = concat(std::vector<uint8_t>{0xA0}, concat(derLen(authContent.size()), authContent));
    std::vector<uint8_t> C1 = concat(algId(rsaoid), derOctet(sig));
    std::vector<uint8_t> signerInfo=derSeq(concat(concat(A1, B1), C1));
    std::vector<uint8_t> X1 = concat(derInt(1), derSet(algId(sha256oid)));
    std::vector<uint8_t> Y1 = derSeq(derOID(dataoid));
    std::vector<uint8_t> Z1 = concat(concat(std::vector<uint8_t>{0xA0}, concat(derLen(cert.size()), cert)), derSet(signerInfo));
    std::vector<uint8_t> signedData=derSeq(concat(concat(X1, Y1), Z1));
    std::vector<uint8_t> W1 = concat(concat(derOID(signedoid), std::vector<uint8_t>{0xA0}), concat(derLen(signedData.size()), signedData));
    std::vector<uint8_t> contentInfo=derSeq(W1);
    std::vector<uint8_t> certRsa=contentInfo;
    auto appendSig=[&](const std::string& name, const std::vector<uint8_t>& data){
        uint32_t crc=crc32(data.data(), data.size()); size_t off=apk.size();
        auto lh=ZIP::localHeader(name, crc, data.size()); apk.insert(apk.end(), lh.begin(), lh.end()); apk.insert(apk.end(), data.begin(), data.end());
        ZIP::Entry e; e.name=name; e.data=data; e.crc=crc; e.offset=off; entries.push_back(e);
    };
    appendSig("META-INF/MANIFEST.MF", mfBytes); appendSig("META-INF/CERT.SF", sfBytes); appendSig("META-INF/CERT.RSA", certRsa);
    std::vector<uint8_t> cd;
    for (auto& e : entries) { auto ch=ZIP::centralHeader(e.name, e.crc, e.data.size(), e.offset); cd.insert(cd.end(), ch.begin(), ch.end()); }
    size_t cdSize=cd.size();

    // The APK Signing Block sits between the last local entry and the Central
    // Directory, so the EOCD has to be built twice: once with its "offset of
    // start of central directory" field pointing at the Signing Block (that is
    // the record the v2 digest is computed over) and once with the offset the
    // Central Directory really lands at (that is what goes in the file).
    auto makeEocd=[&](uint32_t cdOffsetField){
        std::vector<uint8_t> e;
        auto u16e=[&](uint16_t v){ e.push_back(v&0xFF); e.push_back((v>>8)&0xFF); };
        auto u32e=[&](uint32_t v){ e.push_back(v&0xFF); e.push_back((v>>8)&0xFF); e.push_back((v>>16)&0xFF); e.push_back((v>>24)&0xFF); };
        u32e(0x06054b50); u16e(0); u16e(0);
        u16e((uint16_t)entries.size()); u16e((uint16_t)entries.size());
        u32e((uint32_t)cdSize); u32e(cdOffsetField); u16e(0);
        return e;
    };
    size_t sbStart = apk.size();
    std::vector<uint8_t> eocdForDigest = makeEocd((uint32_t)sbStart);
    std::vector<uint8_t> contentDigest = APKv2::contentDigest({
        {apk.data(), apk.size()}, {cd.data(), cd.size()}, {eocdForDigest.data(), eocdForDigest.size()}});
    std::vector<uint8_t> sb = APKv2::signingBlock(contentDigest, key);
    apk.insert(apk.end(), sb.begin(), sb.end());
    std::vector<uint8_t> eocd = makeEocd((uint32_t)(sbStart + sb.size()));
    apk.insert(apk.end(), cd.begin(), cd.end());
    apk.insert(apk.end(), eocd.begin(), eocd.end());
    // Signing bugs are invisible until a device refuses to install, which is
    // the worst possible time to find out. Verify what is about to be written
    // and refuse to write it if the check fails: an APK we cannot verify is
    // never better than no APK. --no-verify is the escape hatch for the case
    // where the verifier itself is what is wrong.
    if (selfVerify) {
        std::ostringstream log;
        if (!Verify::verify(apk, log)) {
            std::cerr << "aster: build-apk: the APK failed its own signature check; nothing was written\n"
                      << log.str();
            return 1;
        }
    }
    std::ofstream os(out, std::ios::binary);
    if (!os) { std::cerr << "aster: build-apk: cannot open " << out << " for writing\n"; return 1; }
    os.write((const char*)apk.data(), (std::streamsize)apk.size());
    return 0;
}

// The build-so pipeline, factored out of main() so that build-apk can compile a
// .ast source straight into an APK. Compilation/linking and packaging/signing
// stay separate concerns (and the .so stays a first-class, inspectable
// artifact); this only removes the manual two-command dance for the common
// "source -> installable APK" case.
static int buildSoFromSource(const std::string& src, const std::string& output,
                             const std::string& soname, const std::vector<std::string>& needed,
                             bool boundsCheck=false,
                             bool debugLine=false, const std::string& sourcePath=""){
    Parser p(src,false,dirNameOf(sourcePath));p.parse();auto funcs=compileProgram(p.functions,p.globals,true,false,boundsCheck,debugLine);
    if(funcs.empty())throw Error("shared object must define at least one function");
    ObjectLayout L=layoutObject(funcs,p.globals);
    std::vector<uint8_t> text=instructionBytes(L.ins);
    std::vector<LinkPending> pending;std::vector<SoExport> exports;
    for(const auto& f:funcs){auto it=L.functions.find(f.name);uint64_t at=it->second.first;
        for(const auto& r:f.relocs)pending.push_back({at+r.offset,r.symbol,0,r.type});
        exports.push_back({f.name,it->second.first,it->second.second});}
    int64_t initOffset=-1;auto initIt=L.functions.find(kInitSymbol);if(initIt!=L.functions.end())initOffset=(int64_t)initIt->second.first;
    // Split the still-undefined references into functions (PLT) and objects (GOT).
    SoDynSpec spec;spec.soname=soname;spec.needed=needed;spec.exports=exports;spec.globals=L.globals;
    spec.data=L.data;spec.rodata=L.rodata;spec.bssSize=L.bssSize;spec.initOffset=initOffset;
    std::set<std::string> defFuncs,defObjs,ifSeen,ioSeen,funcAddrSeen;
    for(const auto& e:exports)defFuncs.insert(e.name);
    for(const auto& g:L.globals)defObjs.insert(g.name);
    for(const auto& r:pending){
        if(r.type==Codegen::kRelCall26){
            if(r.symbol==kInitNextSymbol||defFuncs.count(r.symbol))continue;
            if(ifSeen.insert(r.symbol).second)spec.importFuncs.push_back(r.symbol);
        } else {
            if(r.symbol.compare(0,12,"__aster_gat_")!=0)throw Error("internal error: unexpected shared-object relocation symbol: "+r.symbol);
            const std::string base=r.symbol.substr(12);
            if(defObjs.count(base))continue;
            if(defFuncs.count(base)){ if(funcAddrSeen.insert(base).second) spec.funcAddrRefs.push_back(base); continue; }
            if(ioSeen.insert(base).second)spec.importObjects.push_back(base);
        }
    }
    // Auto-emit DT_NEEDED for extern NDK/system imports so the on-device
    // linker can resolve PLT/GOT stubs at dlopen() time. This is what keeps
    // a NativeActivity APK from crashing on launch ("cannot locate symbol").
    // User-supplied --needed entries are preserved and de-duplicated.
    // -g: one line program for the whole library. A shared object has no fixed
    // load address, but that is exactly what a line table stores anyway: the
    // addresses are offsets in the image and the debugger adds the slide.
    DebugLineBlob dl;
    if(debugLine){
        const size_t sl=sourcePath.find_last_of('/');
        dl=encodeDebugLine(L.lineRows,L.ins.size()*4,sl==std::string::npos?std::string():sourcePath.substr(0,sl),baseNameOf(sourcePath));
    }
    spec.debugLine=dl.bytes;
    for(uint64_t site:dl.patchSites)dbgPatchAddress(spec.debugLine,site,kSharedTextVaddr);
    // v0.23.32-dev: the same unit's names and types. Its addresses are left as
    // placeholders: a shared object's segment addresses are decided inside
    // writeSharedObjectDyn, which is where the patches are resolved.
    DebugInfoBlob di;
    if(debugLine){
        const size_t sl=sourcePath.find_last_of('/');
        di=encodeDebugInfo(L,funcs,p.functions,p.globals,sl==std::string::npos?std::string():sourcePath.substr(0,sl),baseNameOf(sourcePath));
    }
    spec.debugInfo=di.bytes;spec.debugAbbrev=di.abbrev;spec.debugInfoPatches=di.patches;
    // v0.23.33-dev: and the unit's unwind table. Its FDEs stay placeholders for
    // the same reason — a displacement is written against the section's own
    // address, which only the writer knows.
    EhFrameBlob ef;
    if(debugLine)ef=encodeEhFrame(L,funcs);
    spec.ehFrame=ef.bytes;spec.ehFramePatches=ef.patches;spec.ehFrameFdes=ehFrameFdeList(ef);
    {
        std::set<std::string> have(spec.needed.begin(), spec.needed.end());
        auto addNeeded=[&](const std::string& lib){ if(have.insert(lib).second) spec.needed.push_back(lib); };
        for (const auto& s : spec.importFuncs) addNeeded(ndkLibraryFor(s));
        for (const auto& s : spec.importObjects) addNeeded(ndkLibraryFor(s));
    }
    const bool dynamic=!spec.importFuncs.empty()||!spec.importObjects.empty()||!spec.needed.empty()||!soname.empty()||!spec.rodata.empty();
    if(dynamic){
        if(spec.soname.empty())spec.soname=baseNameOf(output);
        writeSharedObjectDyn(output,text,pending,spec);
        std::cout<<"Aster v"<<kVersion<<": emitted AArch64 ELF64 ET_DYN shared object ("<<L.ins.size()<<" instructions, "<<exports.size()<<" exported functions, "
            <<L.globals.size()<<" globals, "<<spec.importFuncs.size()<<" PLT imports, "<<spec.importObjects.size()<<" GOT imports, SONAME "<<spec.soname<<"): "<<output<<"\n";
    } else {
        writeSharedObject(output,text,pending,exports,L.data,L.bssSize,L.globals,initOffset,dl,di,
                          ef.bytes,ef.patches,ehFrameFdeList(ef));
        std::cout<<"Aster v"<<kVersion<<": emitted AArch64 ELF64 ET_DYN shared object ("<<L.ins.size()<<" instructions, "<<exports.size()<<" exported functions, "<<L.globals.size()<<" globals, "<<L.data.size()<<" data bytes, "<<L.bssSize<<" bss bytes): "<<output<<"\n";
    }
    return 0;
}

int main(int argc,char**argv){
    const std::string cmd=argc>1?argv[1]:"";
    std::string output,soname;std::vector<std::string> needed,sources;bool pic=false,haveOutput=false,haveSoname=false,boundsCheck=false,debugLine=false;
    // Where @embed("...") and `include "..."` resolve their relative paths:
    // --embed-dir / --include-dir when given, otherwise the directory the file
    // that wrote the path lives in.
    std::string embedDir;
    std::string includeDir;   // v0.23.13-dev (P3.4)
    // Path resolution is build-wide, so the two directories are published once
    // and every file (the top-level source and each file it includes) resolves
    // its relative paths by the same rule. It has to happen *after* the
    // arguments are read: publishing before the parse is how --embed-dir and
    // --include-dir would both silently do nothing.
    auto publishPathOpts=[&](){ g_srcPathOpts.embedDir=embedDir;g_srcPathOpts.includeDir=includeDir; };
    auto parseArgs=[&](int from)->bool{
        for(int i=from;i<argc;++i){const std::string a=argv[i];
            if(a=="-o"){if(i+1>=argc)return false;output=argv[++i];haveOutput=true;}
            else if(a=="--pic")pic=true;
            else if(a=="--bounds-check")boundsCheck=true;
            else if(a=="-g"||a=="--debug-line")debugLine=true;
            else if(a=="--soname"){if(i+1>=argc)return false;soname=argv[++i];haveSoname=true;}
            else if(a=="--needed"){if(i+1>=argc)return false;needed.emplace_back(argv[++i]);}
            else if(a.rfind("--soname=",0)==0){soname=a.substr(9);haveSoname=true;}
            else if(a.rfind("--needed=",0)==0)needed.emplace_back(a.substr(9));
            else if(a=="--embed-dir"){if(i+1>=argc)return false;embedDir=argv[++i];}
            else if(a.rfind("--embed-dir=",0)==0)embedDir=a.substr(12);
            else if(a=="--include-dir"){if(i+1>=argc)return false;includeDir=argv[++i];}
            else if(a.rfind("--include-dir=",0)==0)includeDir=a.substr(14);
            else if(!a.empty()&&a[0]=='-')return false;
            else sources.push_back(a);
        }
        if(haveSoname&&soname.empty()){std::cerr<<"Aster: --soname requires a non-empty library name\n";return false;}
        for(const auto& lib:needed)if(lib.empty()){std::cerr<<"Aster: --needed requires a non-empty library name\n";return false;}
        publishPathOpts();
        return haveOutput;
    };
    try{
        if(cmd=="build-apk"){
            std::string inSo, package, libname, abi="arm64-v8a", label="AsterApp", verName="1.0", emitSo, soSoname;
            std::string signMode="debug", keystore, cert, keystoreDir;
            int minSdk=21, targetSdk=30, verCode=1, keyBits=2048; bool havePkg=false, selfVerify=true;
            bool labelAsReference=false;
            std::vector<std::pair<std::string,std::string>> extraStrings;
            for(int i=2;i<argc;++i){const std::string a=argv[i];
                auto next=[&]()->const char*{ return (i+1<argc)?argv[++i]:nullptr; };
                if(a=="-o"){const char* v=next(); if(!v){std::cerr<<"aster: build-apk: -o requires an argument\n";return 2;} output=v; haveOutput=true;}
                else if(a=="--package"){const char* v=next(); if(!v){std::cerr<<"aster: build-apk: --package requires an argument\n";return 2;} package=v; havePkg=true;}
                else if(a=="--libname"){const char* v=next(); if(!v){std::cerr<<"aster: build-apk: --libname requires an argument\n";return 2;} libname=v;}
                else if(a=="--abi"){const char* v=next(); if(!v){std::cerr<<"aster: build-apk: --abi requires an argument\n";return 2;} abi=v;}
                else if(a=="--label"){const char* v=next(); if(!v){std::cerr<<"aster: build-apk: --label requires an argument\n";return 2;} label=v;}
                else if(a=="--string"){const char* v=next(); if(!v){std::cerr<<"aster: build-apk: --string requires an argument\n";return 2;} addStringResource(v,extraStrings,"aster: build-apk");}
                else if(a=="--label-as-reference")labelAsReference=true;
                else if(a.rfind("--string=",0)==0)addStringResource(a.substr(9),extraStrings,"aster: build-apk");
                else if(a=="--embed-dir"){const char* v=next(); if(!v){std::cerr<<"aster: build-apk: --embed-dir requires an argument\n";return 2;} embedDir=v;}
                else if(a.rfind("--embed-dir=",0)==0)embedDir=a.substr(12);
                else if(a=="--include-dir"){const char* v=next(); if(!v){std::cerr<<"aster: build-apk: --include-dir requires an argument\n";return 2;} includeDir=v;}
                else if(a.rfind("--include-dir=",0)==0)includeDir=a.substr(14);
                else if(a=="--version-name"){const char* v=next(); if(!v){std::cerr<<"aster: build-apk: --version-name requires an argument\n";return 2;} verName=v;}
                else if(a=="--min-sdk"){const char* v=next(); if(!v){std::cerr<<"aster: build-apk: --min-sdk requires an argument\n";return 2;} minSdk=atoi(v);}
                else if(a=="--target-sdk"){const char* v=next(); if(!v){std::cerr<<"aster: build-apk: --target-sdk requires an argument\n";return 2;} targetSdk=atoi(v);}
                else if(a=="--version-code"){const char* v=next(); if(!v){std::cerr<<"aster: build-apk: --version-code requires an argument\n";return 2;} verCode=atoi(v);}
                // --emit-so keeps the intermediate shared object when compiling
                // from .ast input (the inspection artifact objdump/readelf/qemu
                // all want); without it the intermediate is built and discarded.
                else if(a=="--emit-so"){const char* v=next(); if(!v){std::cerr<<"aster: build-apk: --emit-so requires an argument\n";return 2;} emitSo=v;}
                // --soname only affects .ast input (the DT_SONAME of the library
                // compiled on the fly); a prebuilt .so keeps its own.
                else if(a=="--soname"){const char* v=next(); if(!v){std::cerr<<"aster: build-apk: --soname requires an argument\n";return 2;} soSoname=v;}
                // --- signing: which key signs the APK, and where it comes from
                else if(a=="--sign-mode"){const char* v=next(); if(!v){std::cerr<<"aster: build-apk: --sign-mode requires an argument\n";return 2;} signMode=v;}
                else if(a=="--keystore"){const char* v=next(); if(!v){std::cerr<<"aster: build-apk: --keystore requires an argument\n";return 2;} keystore=v;}
                else if(a=="--cert"){const char* v=next(); if(!v){std::cerr<<"aster: build-apk: --cert requires an argument\n";return 2;} cert=v;}
                else if(a=="--keystore-dir"){const char* v=next(); if(!v){std::cerr<<"aster: build-apk: --keystore-dir requires an argument\n";return 2;} keystoreDir=v;}
                else if(a=="--key-bits"){const char* v=next(); if(!v){std::cerr<<"aster: build-apk: --key-bits requires an argument\n";return 2;} keyBits=atoi(v);}
                else if(a.rfind("--sign-mode=",0)==0)signMode=a.substr(12);
                else if(a.rfind("--keystore-dir=",0)==0)keystoreDir=a.substr(15);
                else if(a.rfind("--keystore=",0)==0)keystore=a.substr(11);
                else if(a.rfind("--cert=",0)==0)cert=a.substr(7);
                else if(a.rfind("--key-bits=",0)==0)keyBits=atoi(a.substr(11).c_str());
                // --no-verify is an escape hatch for the (rare) case where the
                // built APK has to be inspected precisely because signing went
                // wrong. It never changes what is signed, only whether Aster
                // checks its own work before writing.
                else if(a=="--no-verify")selfVerify=false;
                else if(a=="--bounds-check")boundsCheck=true;
                else if(a=="-g"||a=="--debug-line")debugLine=true;
                else if(a.rfind("--soname=",0)==0){soSoname=a.substr(9);}
                else if(!a.empty()&&a[0]=='-'){std::cerr<<"aster: build-apk: unknown option "<<a<<"\n";return 2;}
                else if(inSo.empty()) inSo=a;
                else {std::cerr<<"aster: build-apk: only one input file is allowed\n";return 2;}
            }
            if(!haveOutput){std::cerr<<"aster: build-apk: missing -o <output.apk>\n";return 2;}
            if(!havePkg){std::cerr<<"aster: build-apk: missing --package <android.package.name>\n";return 2;}
            if(inSo.empty()){std::cerr<<"aster: build-apk: missing input .so or .ast file\n";return 2;}
            if(libname.empty()){libname=baseNameOf(output); size_t dp=libname.rfind(".apk"); if(dp==libname.size()-4) libname=libname.substr(0,dp);}
            if(!emitSo.empty()&&emitSo==output){std::cerr<<"aster: build-apk: --emit-so must differ from -o\n";return 2;}
            if(signMode!="debug"&&signMode!="release"){
                std::cerr<<"aster: build-apk: --sign-mode must be debug or release (got \""<<signMode<<"\")\n";return 2;}
            if(signMode=="debug"&&(!keystore.empty()||!cert.empty())){
                std::cerr<<"aster: build-apk: --keystore/--cert are release options; for a debug build put the key in\n"
                         <<"aster: build-apk: <keystore-dir>/.aster/ (see --keystore-dir) or use --sign-mode release\n";return 2;}
            if(keyBits!=2048&&keyBits!=3072&&keyBits!=4096){
                std::cerr<<"aster: build-apk: --key-bits must be 2048, 3072 or 4096 (got "<<keyBits<<")\n";return 2;}
            // Resolve the key before doing any work: a missing release key must
            // cost one failed command, not a compiled library and a dead end.
            const SigningKey key = (signMode=="release")
                ? releaseKey(keystore, cert)
                : debugKeyFor(projectKeyDir(keystoreDir), keyBits);
            // build-apk reads its own argv (a different set of options), so the
            // path options are published here rather than by parseArgs above.
            publishPathOpts();
            std::vector<uint8_t> so;
            if(inSo.size()>4&&inSo.compare(inSo.size()-4,4,".ast")==0){
                // Convenience path: compile the Aster source into the packaged
                // library with the very same build-so pipeline (kept on disk
                // when --emit-so is given, otherwise a temp file is removed).
                std::string src=readFile(inSo);
                setSourceCache(inSo, src);
                std::string soPath=emitSo.empty()?(output+".aster-tmp.so"):emitSo;
                try{ buildSoFromSource(src,soPath,soSoname.empty()?("lib"+libname+".so"):soSoname,{},boundsCheck,debugLine,inSo); }
                catch(...){ if(emitSo.empty())std::remove(soPath.c_str()); throw; }
                std::string soText=readFile(soPath); so.assign(soText.begin(),soText.end());
                if(emitSo.empty())std::remove(soPath.c_str());
            } else {
                std::string soText=readFile(inSo); so.assign(soText.begin(),soText.end());
                if(so.size()<4||so[0]!=0x7f||so[1]!='E'||so[2]!='L'||so[3]!='F'){
                    std::cerr<<"aster: build-apk: input is not an ELF shared object (expected a .so or a .ast): "<<inSo<<"\n";return 2;
                }
            }
            int r=buildApk(output,package,libname,abi,so,minSdk,targetSdk,label,verCode,verName,extraStrings,key,selfVerify,labelAsReference);
            if(r==0)std::cout<<"Aster v"<<kVersion<<": built APK (NativeActivity, v1+v2 dual-signed, "
                <<(signMode=="release"?"release":"debug")<<" key from "<<key.source<<"): "<<output<<"\n";
            return r;
        }
        // keygen writes the project's debug key without building anything, so
        // that "make me a key" and "build me an APK" stay separate decisions.
        if(cmd=="keygen"){
            std::string dir; int bits=2048; bool force=false;
            for(int i=2;i<argc;++i){const std::string a=argv[i];
                auto next=[&]()->const char*{ return (i+1<argc)?argv[++i]:nullptr; };
                if(a=="--dir"){const char* v=next(); if(!v){std::cerr<<"aster: keygen: --dir requires an argument\n";return 2;} dir=v;}
                else if(a=="--bits"){const char* v=next(); if(!v){std::cerr<<"aster: keygen: --bits requires an argument\n";return 2;} bits=atoi(v);}
                else if(a.rfind("--dir=",0)==0)dir=a.substr(6);
                else if(a.rfind("--bits=",0)==0)bits=atoi(a.substr(7).c_str());
                else if(a=="--force")force=true;
                else {std::cerr<<"aster: keygen: unknown option "<<a<<"\naster: keygen usage: aster keygen [--dir DIR] [--bits 2048] [--force]\n";return 2;}
            }
            if(bits!=2048&&bits!=3072&&bits!=4096){
                std::cerr<<"aster: keygen: --bits must be 2048, 3072 or 4096 (got "<<bits<<")\n";return 2;}
            return keygenCommand(projectKeyDir(dir),bits,force);
        }
        // verify-apk answers the question an installer asks: is this APK's
        // signature intact, and does it cover the bytes actually in the file.
        if(cmd=="verify-apk"){
            if(argc!=3){std::cerr<<"aster: verify-apk usage: aster verify-apk <app.apk>\n";return 2;}
            std::string apkText=readFile(argv[2]);
            std::vector<uint8_t> apk(apkText.begin(),apkText.end());
            std::ostringstream log;
            const bool ok=Verify::verify(apk,log);
            std::cout<<log.str();
            if(!ok){std::cerr<<"aster: verify-apk: "<<argv[2]<<": signature verification FAILED\n";return 1;}
            std::cout<<"aster: verify-apk: "<<argv[2]<<": OK (v1 + v2 signatures verified)\n";
            return 0;
        }
        if(cmd=="link-obj"||cmd=="link-pie"){
            if(!parseArgs(2)||sources.empty()||pic||boundsCheck||!soname.empty()||!needed.empty()){std::cerr<<kUsage;return 2;}
            if(cmd=="link-obj")linkObjects(sources,output);else linkObjects(sources,output,0,3);
            return 0;
        }
        if(cmd=="link-so"){
            if(!parseArgs(2)||sources.empty()||pic||boundsCheck){std::cerr<<kUsage;return 2;}
            linkSharedObjects(sources,output,soname,needed);
            return 0;
        }
        if(cmd!="build-elf"&&cmd!="build-pie"&&cmd!="build-obj"&&cmd!="build-so"){std::cerr<<kUsage;return 2;}
        if(!parseArgs(2)||sources.size()!=1){std::cerr<<kUsage;return 2;}
        if(pic&&cmd!="build-obj"){std::cerr<<kUsage;return 2;}
        if((!soname.empty()||!needed.empty())&&cmd!="build-so"){std::cerr<<kUsage;return 2;}
        auto src=readFile(sources[0]);
        setSourceCache(sources[0], src);
        if(cmd=="build-so") return buildSoFromSource(src,output,soname,needed,boundsCheck,debugLine,sources[0]);
        Parser p(src,true,dirNameOf(sources[0]));p.parse();auto funcs=compileProgram(p.functions,p.globals,pic,true,boundsCheck,debugLine);
        // -g: one DWARF line program for this translation unit, from the rows
        // codegen collected. Its addresses stay relative to the object's own
        // .text until the object is linked (or stand as-is for build-obj).
        auto makeDebugLine=[&]()->DebugLineBlob{
            if(!debugLine)return DebugLineBlob{};
            ObjectLayout L=layoutObject(funcs,p.globals);
            const std::string& sp=sources[0];const size_t sl=sp.find_last_of('/');
            return encodeDebugLine(L.lineRows,L.ins.size()*4,sl==std::string::npos?std::string():sp.substr(0,sl),baseNameOf(sp));
        };
        // v0.23.32-dev: and the unit's names and types — the same source file,
        // the same one unit per object, and the same placeholder addresses.
        auto makeDebugInfo=[&]()->DebugInfoBlob{
            if(!debugLine)return DebugInfoBlob{};
            ObjectLayout L=layoutObject(funcs,p.globals);
            const std::string& sp=sources[0];const size_t sl=sp.find_last_of('/');
            return encodeDebugInfo(L,funcs,p.functions,p.globals,sl==std::string::npos?std::string():sp.substr(0,sl),baseNameOf(sp));
        };
        // v0.23.33-dev: and the frame's shape — one CIE and one FDE per
        // function, whose addresses are placeholders for exactly the same
        // reason: only the linker knows where this unit's text will land.
        auto makeEhFrame=[&]()->EhFrameBlob{
            if(!debugLine)return EhFrameBlob{};
            ObjectLayout L=layoutObject(funcs,p.globals);
            return encodeEhFrame(L,funcs);
        };
        if(cmd=="build-obj"){writeObject(output,funcs,p.globals,pic,makeDebugLine(),makeDebugInfo(),makeEhFrame());size_t n=0;for(const auto&f:funcs)n+=f.code.size();size_t g=0;for(const auto&x:p.globals)if(!x.external)++g;std::cout<<"Aster v"<<kVersion<<": emitted AArch64 ELF64 ET_REL object"<<" ("<<n<<" instructions, "<<funcs.size()<<" functions, "<<g<<" globals"<<(pic?", PIC":"")<<(debugLine?", with .debug_line":"")<<"): "<<output<<"\n";}
        else {std::string temp=output+".aster-tmp.o";writeObject(temp,funcs,p.globals,false,makeDebugLine(),makeDebugInfo(),makeEhFrame());try{if(cmd=="build-pie")linkObjects({temp},output,0,3);else linkObjects({temp},output);}catch(...){std::remove(temp.c_str());throw;}std::remove(temp.c_str());}
        return 0;
    }catch(const std::exception&e){reportError(e.what());return 1;}
}
