#include "cn_parser.hpp"
#include "cn_diagnostics.hpp"

#include <algorithm>
#include <initializer_list>
#include <set>
#include <sstream>
#include <stdexcept>
#include <utility>

namespace aster_cn {
namespace {

std::string quoted(const std::string& value) {
    std::string out = "\"";
    for (char ch : value) {
        if (ch == '\\') out += "\\\\";
        else if (ch == '"') out += "\\\"";
        else if (ch == '\n') out += "\\n";
        else if (ch == '\r') out += "\\r";
        else if (ch == '\t') out += "\\t";
        else out.push_back(ch);
    }
    out.push_back('"');
    return out;
}

std::string astVisibility(const std::string& visibility) {
    if (visibility == "hidden" || visibility == "restricted") return "private";
    if (visibility == "restricted_class") return "protected";
    return visibility;
}

std::string canonicalType(const Token& token) {
    if (token.kind == "I8") return "i8";
    if (token.kind == "U8") return "u8";
    if (token.kind == "I16") return "i16";
    if (token.kind == "U16") return "u16";
    if (token.kind == "I32") return "i32";
    if (token.kind == "U32") return "u32";
    if (token.kind == "I64") return "i64";
    if (token.kind == "U64") return "u64";
    if (token.kind == "F32") return "f32";
    if (token.kind == "F64") return "f64";
    if (token.kind == "Bool") return "bool";
    if (token.kind == "CharType") return "char";
    if (token.kind == "String") return "string";
    if (token.kind == "StringView") return "string_view";
    if (token.kind == "Ptr") return "ptr";
    if (token.kind == "VoidKw" || token.kind == "Empty") return "void";
    if (token.kind == "Identifier") return token.text;
    throw std::runtime_error("expected a type name at " + std::to_string(token.line) + ":" +
                             std::to_string(token.column));
}

bool isBuiltinTypeSpelling(const std::string& spelling) {
    static const std::set<std::string> names = {
        "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64",
        "f32", "f64", "bool", "char", "string", "string_view", "ptr", "void"
    };
    return names.count(spelling) != 0;
}

class Parser {
public:
    Parser(std::vector<Token> tokens, Language language, std::string sourceFile)
        : tokens_(std::move(tokens)), language_(language), sourceFile_(std::move(sourceFile)) {}

    // P0-4: recursion depth guard, mirroring the mainline parser's
    // DepthGuard(256) on expr()/statement()/parseType. Without it a hostile
    // input such as 10000 nested parentheses drove the recursive-descent
    // parser off the C stack (segfault, exit 139). Each guarded function has
    // its own counter so one construct nests 256 deep before the guard trips;
    // the counters are per-Parser, so sequential siblings do not accumulate.
    // The message starts with "expected " so classifyDiagnostic() reports it
    // as A-011, and parseProgram()'s decorateDiagnostic() keeps it a single
    // clean diagnostic. This lives in cn_parser.cpp (not aster.cpp) because
    // this file is also compiled standalone by cn_parse_main.cpp, where the
    // mainline RecursionGuard/DepthGuard do not exist.
    static constexpr unsigned kMaxNestingDepth = 256;
    struct DepthGuard {
        unsigned& d;
        DepthGuard(unsigned& depth, const char* what, const Token& token) : d(depth) {
            if (++d > kMaxNestingDepth) {
                --d;
                throw std::runtime_error(std::string("expected ") + what +
                    " nesting within 256 levels at " + std::to_string(token.line) +
                    ":" + std::to_string(token.column));
            }
        }
        ~DepthGuard() { --d; }
    };

    std::vector<std::string> readPackageHeader() {
        skipNewlines();
        if (!eat("PackageKw")) return {};
        auto parsePackageName = [&]() {
            std::string name = parseName();
            while (eat("Dot")) name += "." + parseName();
            return name;
        };
        std::vector<std::string> names{parsePackageName()};
        while (eat("Eq")) {
            const std::string alias = parsePackageName();
            if (std::find(names.begin(), names.end(), alias) != names.end())
                fail("duplicate package name or alias");
            names.push_back(alias);
        }
        requireTerminator();
        return names;
    }

    Program run() {
        Program program;
        program.sourceFile = sourceFile_;
        program.language = language_;
        const std::vector<std::string> packageNames = readPackageHeader();
        if (!packageNames.empty()) {
            program.packageName = packageNames.front();
            program.packageAliases.assign(packageNames.begin() + 1, packageNames.end());
        }
        skipNewlines();
        // P1-4: pre-scan so struct literals and class constructions do not
        // depend on declaration order (see collectDeclaredTypeNames).
        collectDeclaredTypeNames();
        while (!at("End")) {
            if (at("PackageKw")) {
                fail("a package declaration must be the first declaration in the source file");
            } else if (at("At")) {
                const TopLevelAnnotations annotations = parseTopLevelAnnotations(program);
                if (annotations.hasVisibility) {
                    if (at("End")) fail("an annotation must precede a declaration");
                    if (at("Extern") && externalGlobalAhead()) {
                        Statement global = parseExternalGlobal();
                        global.visibility = annotations.visibility;
                        program.globals.push_back(std::move(global));
                    } else if (at("Method") || at("Extern")) {
                        MethodDeclaration method = parseMethod(at("Extern"));
                        method.visibility = annotations.visibility;
                        program.methods.push_back(std::move(method));
                    } else if (at("VarDecl") || at("ConstDecl")) {
                        Statement global = parseVariable(at("ConstDecl"));
                        global.visibility = annotations.visibility;
                        program.globals.push_back(std::move(global));
                    } else if (at("StructKw")) {
                        StructDeclaration declaration = parseStruct();
                        declaration.visibility = annotations.visibility;
                        program.structures.push_back(std::move(declaration));
                    } else if (at("EnumKw")) {
                        EnumDeclaration declaration = parseEnum();
                        declaration.visibility = annotations.visibility;
                        program.enums.push_back(std::move(declaration));
                    } else if (at("Class")) {
                        ClassDeclaration declaration = parseClass();
                        declaration.visibility = annotations.visibility;
                        program.classes.push_back(std::move(declaration));
                    } else if (at("InterfaceClass")) {
                        InterfaceClassDeclaration declaration = parseInterfaceClass();
                        declaration.visibility = annotations.visibility;
                        program.interfaceClasses.push_back(std::move(declaration));
                    } else if (at("LayoutKw")) {
                        LayoutDeclaration declaration = parseLayout();
                        declaration.visibility = annotations.visibility;
                        program.layouts.push_back(std::move(declaration));
                    } else if (eventBlockAhead()) {
                        EventBlockDeclaration declaration = parseEventBlock();
                        declaration.visibility = annotations.visibility;
                        program.events.push_back(std::move(declaration));
                    } else {
                        fail("top-level visibility annotations require a declaration");
                    }
                } else if (at("End")) {
                    break;
                } else if (at("TypeAlias")) program.aliases.push_back(parseTypeAlias());
                else if (at("IncludeKw")) program.fileImports.push_back(parseFileImport());
                else if (at("StructKw")) program.structures.push_back(parseStruct());
                else if (at("EnumKw")) program.enums.push_back(parseEnum());
                else if (at("Class")) program.classes.push_back(parseClass());
                else if (at("InterfaceClass"))
                    program.interfaceClasses.push_back(parseInterfaceClass());
                else if (at("LayoutKw")) program.layouts.push_back(parseLayout());
                else if (eventBlockAhead()) program.events.push_back(parseEventBlock());
                else if (at("VarDecl") || at("ConstDecl"))
                    program.globals.push_back(parseVariable(at("ConstDecl")));
                else if (at("Extern") && externalGlobalAhead())
                    program.globals.push_back(parseExternalGlobal());
                else if (at("Method") || at("Extern"))
                    program.methods.push_back(parseMethod(at("Extern")));
                else fail("expected a method, structure, enum, class, interface class, layout, event block, or global declaration");
            } else if (at("TypeAlias")) program.aliases.push_back(parseTypeAlias());
            else if (at("IncludeKw")) program.fileImports.push_back(parseFileImport());
            else if (at("StructKw")) program.structures.push_back(parseStruct());
            else if (at("EnumKw")) program.enums.push_back(parseEnum());
            else if (at("Class")) program.classes.push_back(parseClass());
            else if (at("InterfaceClass"))
                program.interfaceClasses.push_back(parseInterfaceClass());
            else if (at("LayoutKw")) program.layouts.push_back(parseLayout());
            else if (eventBlockAhead()) program.events.push_back(parseEventBlock());
            else if (at("VarDecl") || at("ConstDecl"))
                program.globals.push_back(parseVariable(at("ConstDecl")));
            else if (at("Extern") && externalGlobalAhead())
                program.globals.push_back(parseExternalGlobal());
            else if (at("Method") || at("Extern"))
                program.methods.push_back(parseMethod(at("Extern")));
            else fail("expected a method, structure, enum, class, interface class, layout, event block, or global declaration");
            skipNewlines();
        }
        return program;
    }

private:
    struct ClassMemberAnnotations {
        std::string visibility = "public";
        bool hasVisibility = false;
        bool isStatic = false;
        bool isConstructor = false;
        bool isOverride = false;
    };

    struct TopLevelAnnotations {
        std::string visibility = "public";
        bool hasVisibility = false;
    };

    std::vector<Token> tokens_;
    Language language_;
    std::string sourceFile_;
    std::size_t position_ = 0;
    // P0-4: one depth counter per guarded recursive function (see DepthGuard).
    unsigned exprDepth_ = 0;
    unsigned unaryDepth_ = 0;
    unsigned primaryDepth_ = 0;
    unsigned stmtDepth_ = 0;
    unsigned stmtsUntilDepth_ = 0;
    unsigned blockDepth_ = 0;
    unsigned ifDepth_ = 0;
    unsigned typeDepth_ = 0;
    unsigned closureTypeDepth_ = 0;
    unsigned functionTypeDepth_ = 0;
    // D-2a: >0 while parsing a layout body (including its `如果` branches
    // and node-row child blocks), so parseStatement() accepts node rows
    // there and rejects them anywhere else.
    unsigned layoutDepth_ = 0;
    std::set<std::string> structureNames_;
    std::set<std::string> classNames_;
    std::set<std::string> interfaceClassNames_;
    std::set<std::string> aliasNames_;
    // P1-4: duplicate-declaration checks use these sets, not the pre-scanned
    // ones above: collectDeclaredTypeNames() fills the use-site sets before
    // parsing, so an `insert().second` check on them would false-trip on the
    // first real declaration.
    std::set<std::string> declaredStructureNames_;
    std::set<std::string> declaredClassNames_;
    std::set<std::string> declaredInterfaceClassNames_;

    // P1-4: a struct literal (`点{...}`) or a class construction
    // (`Point(...)`) must not depend on whether the declaration textually
    // precedes the use: the EBNF puts no such restriction on them (only a
    // class *base* must be declared first, design §2.9 D-16). Pre-scan the
    // token stream for the top-level declarations so the use-site sets are
    // complete before any statement is parsed. `结构`/`类`/`接口类` only
    // occur as declaration heads, so a flat token scan is exact.
    void collectDeclaredTypeNames() {
        for (std::size_t i = 0; i < tokens_.size(); ++i) {
            const Token& token = tokens_[i];
            std::set<std::string>* names = nullptr;
            if (token.kind == "StructKw") names = &structureNames_;
            else if (token.kind == "Class") names = &classNames_;
            else if (token.kind == "InterfaceClass") names = &interfaceClassNames_;
            else continue;
            if (i + 1 >= tokens_.size()) continue;
            const Token& name = tokens_[i + 1];
            if (name.kind == "Identifier" || name.kind == "Main") names->insert(name.text);
            else if (name.kind == "StartMethod") names->insert("main");
        }
    }

    const Token& current() const { return tokens_[position_]; }
    bool at(const char* kind) const { return current().kind == kind; }
    bool atWord(const char* word) const {
        return at("Identifier") && current().text == word;
    }
    bool wordAhead(std::size_t offset, const char* word) const {
        const std::size_t index = position_ + offset;
        return index < tokens_.size() && tokens_[index].kind == "Identifier" &&
               tokens_[index].text == word;
    }
    bool eat(const char* kind) {
        if (!at(kind)) return false;
        ++position_;
        return true;
    }
    const Token& expect(const char* kind, const char* message) {
        if (!at(kind)) fail(message);
        return tokens_[position_++];
    }
    [[noreturn]] void fail(const std::string& message) const {
        const Token& token = current();
        throw std::runtime_error(message + " at " + std::to_string(token.line) + ":" +
                                 std::to_string(token.column));
    }
    void skipNewlines() {
        while (eat("Newline")) {}
    }
    std::string parseName() {
        if (eat("StartMethod")) return "main";
        if (at("Identifier") || at("Main")) {
            // D-3 (i): `__aster_cn_` is the CN runtime's own namespace: the
            // bilingual stdlib defines the string helpers the lowering
            // itself calls (`__aster_cn_str_order`, `__aster_cn_str_concat`,
            // `__aster_cn_string_from_view`), and the mainline accepts
            // those definitions. Other `__aster_` prefixes stay reserved
            // so user code cannot collide with compiler-generated symbols
            // (`__aster_cn_new_class_*`, `__aster_cn_method_*`, ...).
            if (current().text.rfind("__aster_", 0) == 0 &&
                current().text.rfind("__aster_cn_", 0) != 0)
                fail("identifier prefix '__aster_' is reserved");
            return tokens_[position_++].text;
        }
        fail("expected an identifier");
    }
    std::string parseMemberName() {
        // P1-2: `.type` is a member name, not a keyword position: spell it
        // in the file's own language instead of hard-coding Chinese.
        if (at("TypeAlias")) {
            ++position_;
            return language_ == Language::Zh ? "类型" : "type";
        }
        return parseName();
    }
    std::string parseAnnotationName() {
        if (at("Identifier") || at("IncludeKw")) return tokens_[position_++].text;
        fail("expected an annotation name after '@'");
    }
    static bool isImportIdentifier(const std::string& name, Language language) {
        try {
            const std::vector<Token> parsed = lex(name, language);
            // D-3 (i): same `__aster_cn_` carve-out as parseName.
            return (name.rfind("__aster_", 0) != 0 ||
                    name.rfind("__aster_cn_", 0) == 0) && parsed.size() == 2 &&
                parsed[0].text == name &&
                (parsed[0].kind == "Identifier" || parsed[0].kind == "Main");
        } catch (const std::exception&) {
            return false;
        }
    }
    static bool isPackageName(const std::string& name) {
        std::size_t start = 0;
        while (true) {
            const std::size_t dot = name.find('.', start);
            const std::string part = name.substr(start, dot == std::string::npos ? dot : dot - start);
            if (!isImportIdentifier(part, Language::Zh) && !isImportIdentifier(part, Language::En))
                return false;
            if (dot == std::string::npos) return true;
            start = dot + 1;
        }
    }
    TopLevelAnnotations parseTopLevelAnnotations(Program& program) {
        // P1-8: annotations are per-language closed tables (EBNF:
        // zh top-level visibility is 隐藏|受限, en is @private only;
        // the import annotation is @导入 in zh, @import in en).
        // Cross-language spellings are rejected. Mapping verdict: `private`
        // maps to `restricted` here and to `hidden` in class members, and
        // both are correct — design D-13 says the top-level file-private
        // annotation is also written `@private`, "按声明位置区分", and D-12
        // defines top-level `@受限` as file-scoped, while class-member
        // `@private` means visible only inside the declaring class.
        const bool zh = language_ == Language::Zh;
        TopLevelAnnotations annotations;
        while (eat("At")) {
            const Token atToken = tokens_[position_ - 1];
            const std::string name = parseAnnotationName();
            if ((zh && name == "导入") || (!zh && name == "import")) {
                if (annotations.hasVisibility)
                    fail("an import annotation cannot share a declaration with a visibility annotation");
                expect("LParen", "expected '(' after '@import'");
                const Token module = expect("String", "expected a string module name after '@import('");
                ImportDeclaration import;
                if (module.text.size() < 2 || module.text.front() != '"' || module.text.back() != '"' ||
                    module.text.find('\\') != std::string::npos)
                    fail("package name must be a plain string literal without escapes");
                import.moduleName = module.text.substr(1, module.text.size() - 2);
                import.line = atToken.line;
                import.column = atToken.column;
                expect("RParen", "expected ')' after the module import");
                if (eat("Dot")) {
                    const std::string option = parseAnnotationName();
                    if ((zh && option != "别名") || (!zh && option != "alias"))
                        fail("expected '.别名(...)' after the module import");
                    expect("LParen", "expected '(' after '.别名'");
                    const Token alias = expect("String", "expected a string alias after '.别名('");
                    if (alias.text.size() < 2 || alias.text.front() != '"' ||
                        alias.text.back() != '"' || alias.text.find('\\') != std::string::npos)
                        fail("import alias must be a plain string literal without escapes");
                    import.alias = alias.text.substr(1, alias.text.size() - 2);
                    expect("RParen", "expected ')' after the import alias");
                } else {
                    const std::size_t dot = import.moduleName.find_last_of('.');
                    import.alias = import.moduleName.substr(dot == std::string::npos ? 0 : dot + 1);
                }
                if (!isPackageName(import.moduleName))
                    throw std::runtime_error("expected a dot-separated package name at " +
                        std::to_string(atToken.line) + ":" + std::to_string(atToken.column));
                if (!isImportIdentifier(import.alias, language_))
                    throw std::runtime_error("import alias must be an identifier at " +
                        std::to_string(atToken.line) + ":" + std::to_string(atToken.column));
                program.imports.push_back(std::move(import));
            } else if ((zh && name == "隐藏") || (zh && name == "受限") ||
                       (!zh && name == "private")) {
                if (annotations.hasVisibility)
                    throw std::runtime_error("top-level visibility annotations are mutually exclusive at " +
                        std::to_string(atToken.line) + ":" + std::to_string(atToken.column));
                annotations.hasVisibility = true;
                annotations.visibility = (name == "隐藏") ? "hidden" : "restricted";
            } else if ((zh && name == "静态") || (!zh && name == "static")) {
                throw std::runtime_error("'@static' can only annotate a class method at " +
                    std::to_string(atToken.line) + ":" + std::to_string(atToken.column));
            } else if ((zh && name == "构造") || (!zh && name == "constructor")) {
                throw std::runtime_error("'@constructor' can only annotate a class method at " +
                    std::to_string(atToken.line) + ":" + std::to_string(atToken.column));
            } else if ((zh && name == "重写") || (!zh && name == "override")) {
                throw std::runtime_error("'@override' can only annotate a class method at " +
                    std::to_string(atToken.line) + ":" + std::to_string(atToken.column));
            } else {
                throw std::runtime_error("unknown top-level annotation '@" + name + "' at " +
                    std::to_string(atToken.line) + ":" + std::to_string(atToken.column));
            }
            skipNewlines();
        }
        return annotations;
    }
    ClassMemberAnnotations parseClassMemberAnnotations() {
        // P1-8: per-language closed tables (EBNF: zh 隐藏|受限|受限.类|
        // 静态|构造|重写, en private|protected|static|constructor|override).
        // `@hidden` and `@protected.class` are not in the en table and are
        // rejected, as are all cross-language spellings.
        const bool zh = language_ == Language::Zh;
        ClassMemberAnnotations annotations;
        while (eat("At")) {
            const Token annotation = current();
            const std::string name = parseAnnotationName();
            if ((zh && name == "隐藏") || (!zh && name == "private") ||
                (zh && name == "受限") || (!zh && name == "protected")) {
                if (annotations.hasVisibility)
                    throw std::runtime_error("class member visibility annotations are mutually exclusive at " +
                        std::to_string(annotation.line) + ":" + std::to_string(annotation.column));
                annotations.hasVisibility = true;
                annotations.visibility = ((zh && name == "隐藏") || (!zh && name == "private"))
                    ? "hidden" : "restricted_class";
                if (zh && name == "受限" && eat("Dot")) {
                    if (!at("Class") &&
                        (!at("Identifier") || current().text != "类"))
                        fail("expected '类' after a restricted annotation");
                    ++position_;
                }
            } else if ((zh && name == "静态") || (!zh && name == "static")) {
                if (annotations.isStatic)
                    throw std::runtime_error("duplicate '@静态' annotation at " +
                        std::to_string(annotation.line) + ":" + std::to_string(annotation.column));
                annotations.isStatic = true;
            } else if ((zh && name == "构造") || (!zh && name == "constructor")) {
                if (annotations.isConstructor)
                    throw std::runtime_error("duplicate '@构造' annotation at " +
                        std::to_string(annotation.line) + ":" +
                        std::to_string(annotation.column));
                annotations.isConstructor = true;
            } else if ((zh && name == "重写") || (!zh && name == "override")) {
                if (annotations.isOverride)
                    throw std::runtime_error("duplicate '@override' annotation at " +
                        std::to_string(annotation.line) + ":" +
                        std::to_string(annotation.column));
                annotations.isOverride = true;
            } else {
                throw std::runtime_error("unknown class member annotation '@" + name +
                    "' at " + std::to_string(annotation.line) + ":" +
                    std::to_string(annotation.column));
            }
            skipNewlines();
        }
        return annotations;
    }
    std::string parseClosureType() {
        DepthGuard guard(closureTypeDepth_, "closure type", current());
        expect("Closure", "expected a closure type");
        expect("LParen", "expected '(' after closure");
        skipNewlines();
        std::vector<std::string> parameters;
        if (!at("RParen")) {
            while (true) {
                parameters.push_back(parseType());
                skipNewlines();
                if (!eat("Comma")) break;
                skipNewlines();
            }
        }
        expect("RParen", "expected ')' after closure parameter types");
        // #8 (divergence): closure types accept both `->` (design §2.14
        // canonical: `闭包(P) -> R` / `closure(P) -> R`) and `:` (compat,
        // same dual-accept as `fn` types in parseFunctionType, C-1 P9).
        // The internal type string stays `closure(…):…` either way.
        if (!eat("Colon") && !eat("Arrow"))
            fail("expected ':' or '->' after closure parameter types");
        const std::string result = parseType();
        std::string type = "closure(";
        for (size_t i = 0; i < parameters.size(); ++i) {
            if (i != 0) type += ',';
            type += parameters[i];
        }
        return type + "):" + result;
    }
    std::string parseFunctionType() {
        DepthGuard guard(functionTypeDepth_, "function type", current());
        expect("Method", "expected a function type");
        expect("LParen", "expected '(' after the function type");
        skipNewlines();
        std::vector<std::string> parameters;
        if (!at("RParen")) {
            while (true) {
                parameters.push_back(parseType());
                skipNewlines();
                if (!eat("Comma")) break;
                skipNewlines();
            }
        }
        expect("RParen", "expected ')' after function type parameters");
        // C-1 (P9): English function types accept the mainline `->`
        // (`fn(i32) -> i32`) as well as the colon form (`fn(i32): i32`).
        std::string result;
        if (eat("Colon")) {
            result = parseType();
        } else if (language_ == Language::En && eat("Arrow")) {
            result = parseType();
        } else {
            fail("expected ':' after function type parameters");
        }
        std::string type = "fn(";
        for (size_t i = 0; i < parameters.size(); ++i) {
            if (i != 0) type += ',';
            type += parameters[i];
        }
        return type + "):" + result;
    }
    std::string parseType() {
        DepthGuard guard(typeDepth_, "type", current());
        if (at("Closure")) return parseClosureType();
        if (at("Method")) return parseFunctionType();
        const Token token = current();
        if (token.kind == "Identifier" || token.kind == "I8" || token.kind == "U8" ||
            token.kind == "I16" || token.kind == "U16" || token.kind == "I32" ||
            token.kind == "U32" || token.kind == "I64" || token.kind == "U64" ||
            token.kind == "F32" || token.kind == "F64" || token.kind == "Bool" ||
            token.kind == "CharType" || token.kind == "String" || token.kind == "StringView" ||
            token.kind == "Ptr" || token.kind == "VoidKw" || token.kind == "Empty") {
            ++position_;
            std::string type = canonicalType(token);
            // D-3 (i): generic pointer `ptr<T>` (the framework surface:
            // `ptr<u8>`, `ptr<AuiNode>`, ...). Type position only, so `<`
            // is unambiguous here; nested `ptr<ptr<u8>>` recurses.
            if (type == "ptr" && at("Lt")) {
                ++position_;
                type += "<" + parseType() + ">";
                expect("Gt", "expected '>' after the pointer element type");
            }
            while (eat("Dot")) type += "." + parseName();
            return type;
        }
        fail("expected a type name");
    }
    void parseParameterType(Parameter& parameter) {
        parameter.typeName = parseType();
        // P1-7: one dimension only (EBNF `parameter` has no dimension at
        // all; design S4 allows one-dimensional fixed arrays). The message
        // keeps the lowering's wording so the existing rejection test in
        // cn-backend-checks.sh still matches.
        if (eat("LBracket")) {
            parameter.arrayDimensions.push_back(
                expect("Number", "expected a fixed array length").text);
            expect("RBracket", "expected ']' after the array length");
            if (at("LBracket"))
                fail("the current compiler backend supports one-dimensional array parameters");
        }
    }
    void requireTerminator() {
        if (language_ == Language::Zh) {
            if (!eat("Newline") && !eat("Semi")) fail("expected a newline or ';' after the statement");
            skipNewlines();
            return;
        }
        if (!eat("Semi")) fail("expected ';' after the statement");
        skipNewlines();
    }
    void requireBlockLine() {
        if (!eat("Newline")) fail("expected a newline before the block body");
        skipNewlines();
    }
    bool externalGlobalAhead() const {
        if (!at("Extern")) return false;
        std::size_t index = position_ + 1;
        if (language_ == Language::Zh) {
            if (index >= tokens_.size() || tokens_[index].kind != "LParen") return false;
            while (index < tokens_.size() && tokens_[index].kind != "RParen") ++index;
            if (index >= tokens_.size()) return false;
            ++index;
        }
        return index < tokens_.size() && tokens_[index].kind == "VarDecl";
    }
    // D-2a fix: `event`/`事件` are contextual keywords, not reserved
    // keywords — the framework's NDK declarations use `event` as a
    // parameter name (e.g. aui_impl.ast:1329 `event: ptr`), so the lexer
    // must not turn it into a keyword token. An event block is `event` /
    // `事件` followed by an identifier (the node name) and a colon; any
    // other use of `event` is an ordinary identifier.
    bool eventBlockAhead() const {
        if (!at("Identifier")) return false;
        if (current().text != "event" && current().text != "事件") return false;
        if (position_ + 2 >= tokens_.size()) return false;
        return tokens_[position_ + 1].kind == "Identifier" &&
               tokens_[position_ + 2].kind == "Colon";
    }
    // D-2a: a node row starts with two identifiers in a row — the node
    // kind, then the node name (`列 主列, ...` / `Column MainCol, ...`).
    // A kind followed directly by a comma is a node row missing its name
    // (`列 , ...`), so it counts too, and parseNodeRow reports the missing
    // name. Ordinary statements never do that: a call is `name(`, an
    // assignment is `name =` / `name.`, so the lookahead is exact. (`name
    // {` is deliberately NOT a row: it is a struct literal statement.)
    bool nodeRowAhead() const {
        if (!at("Identifier")) return false;
        if (position_ + 1 >= tokens_.size()) return false;
        const Token& next = tokens_[position_ + 1];
        return next.kind == "Identifier" || next.kind == "Main" || next.kind == "Comma";
    }
    // D-2a (W-1): `布局 名(参数): 视图 { ... }` /
    // `layout name(params) -> View { ... }`. The body uses braces in both
    // languages (W-O1); the `如果` inside still closes with `结束 如果`.
    // `视图`/`View` needs no keyword: parseType() accepts any identifier
    // as a type name, and the lowering treats it as i32.
    LayoutDeclaration parseLayout() {
        const Token start = expect("LayoutKw", "expected a layout declaration");
        LayoutDeclaration layout;
        layout.line = start.line;
        layout.column = start.column;
        layout.sourceFile = sourceFile_;
        layout.name = parseName();
        expect("LParen", "expected '(' after the layout name");
        skipNewlines();
        if (!at("RParen")) {
            while (true) {
                Parameter parameter;
                parameter.name = parseName();
                expect("Colon", "expected ':' after a layout parameter name");
                parseParameterType(parameter);
                layout.parameters.push_back(std::move(parameter));
                skipNewlines();
                if (!eat("Comma")) break;
                skipNewlines();
            }
        }
        expect("RParen", "expected ')' after layout parameters");
        if (eat("Colon")) layout.returnType = parseType();
        else if (language_ == Language::En && eat("Arrow")) layout.returnType = parseType();
        else fail("expected ':' (or '->' in English) and a return type after layout parameters");
        skipNewlines();
        expect("LBrace", "expected '{' to open the layout body");
        ++layoutDepth_;
        layout.body = parseStatementsUntil({"RBrace"});
        --layoutDepth_;
        expect("RBrace", "expected '}' to close the layout body");
        return layout;
    }
    // D-2a (W-4): `事件 名:事件种() { ... }` / `event Name:kind() { ... }`.
    // `event`/`事件` is a contextual keyword: parseEventBlock consumes
    // the leading identifier itself (no EventKw token exists any more).
    // The body holds ordinary statements only (no node rows: layoutDepth_
    // stays 0 here).
    EventBlockDeclaration parseEventBlock() {
        const Token start = current();
        if (!eventBlockAhead())
            fail("expected an event block");
        ++position_;
        EventBlockDeclaration event;
        event.line = start.line;
        event.column = start.column;
        event.sourceFile = sourceFile_;
        event.nodeName = parseName();
        if (!eat("Colon"))
            fail("an event block needs an event kind after the node name, e.g. '事件 名:被单击()' or 'event Name:tap()'");
        if (!at("Identifier"))
            fail("expected an event kind after ':' in the event block header");
        event.eventKind = tokens_[position_++].text;
        skipNewlines();
        expect("LParen", "expected '(' after the event kind");
        skipNewlines();
        if (!eat("RParen"))
            fail("an event block takes no parameters; expected ')' after the event kind");
        skipNewlines();
        expect("LBrace", "expected '{' to open the event block body");
        event.body = parseStatementsUntil({"RBrace"});
        expect("RBrace", "expected '}' to close the event block body");
        return event;
    }
    // D-2a (W-2/W-8): `种名 节点名, 项..., { 子节点行... }`. Every
    // comma-separated item is parsed as an expression and collected into
    // `children` (modifier calls included; the lowering classifies them by
    // the modifier table, so this parser needs no schema table). `键 = N` /
    // `key = N` is the explicit key override, not a position argument and
    // not a modifier. A child block holds layout-body statements (node
    // rows, `如果`, `变量`, ...), in source order, in `childStatements`.
    Expression parseNodeRow() {
        const Token kindToken = current();
        Expression row;
        row.kind = "NodeRow";
        row.value = parseName();
        row.line = kindToken.line;
        row.column = kindToken.column;
        row.sourceFile = sourceFile_;
        if (!at("Identifier") && !at("Main"))
            fail("a node row needs a node name after the node kind '" + row.value + "'");
        row.nodeName = parseName();
        while (eat("Comma")) {
            skipNewlines();
            if (at("Identifier") && (current().text == "键" || current().text == "key") &&
                position_ + 1 < tokens_.size() && tokens_[position_ + 1].kind == "Eq") {
                if (row.hasKeyOverride)
                    fail("duplicate '键 = N' key override in a node row for '" + row.nodeName + "'");
                ++position_;
                ++position_;
                const Token number = current();
                if (!eat("Number"))
                    fail("expected an integer after '键 =' in a node row for '" + row.nodeName + "'");
                try {
                    row.keyOverride = std::stoll(number.text, nullptr, 0);
                } catch (const std::exception&) {
                    fail("expected an integer after '键 =' in a node row for '" + row.nodeName + "'");
                }
                row.hasKeyOverride = true;
                continue;
            }
            row.children.push_back(parseExpression());
            skipNewlines();
        }
        skipNewlines();
        if (eat("LBrace")) {
            // D-2a: a child block is a layout-body statement list, not
            // rows only — the drafts put `如果`/`变量` in child blocks
            // (counter-zh:52, tab-input-zh:69; design §1.1 anticipated
            // relaxing this). layoutDepth_ is still raised, so node rows
            // inside parse through parseStatement; `如果`/`变量` reuse the
            // ordinary statement parsing.
            skipNewlines();
            row.childStatements = parseStatementsUntil({"RBrace"});
            expect("RBrace", "expected '}' to close the node row child block");
            for (const auto& childStatement : row.childStatements)
                if (childStatement.kind == "ExpressionStatement" &&
                    childStatement.expression.kind == "NodeRow")
                    row.childRows.push_back(childStatement.expression);
        }
        return row;
    }
    Statement parseNodeRowStatement() {
        Expression row = parseNodeRow();
        Statement statement;
        statement.line = row.line;
        statement.column = row.column;
        statement.sourceFile = sourceFile_;
        statement.kind = "ExpressionStatement";
        statement.expression = std::move(row);
        statement.hasExpression = true;
        skipNewlines();
        return statement;
    }
    MethodDeclaration parseMethod(bool external = false) {
        const Token methodStart = current();
        if (external) expect("Extern", "expected 'extern' before an external method");
        std::string externalName;
        if (external && language_ == Language::Zh) {
            expect("LParen", "expected '(' after '外部'");
            const Token symbol = expect("String", "expected a string ASCII symbol name after '外部('");
            if (symbol.text.size() < 2 || symbol.text.front() != '"' ||
                symbol.text.back() != '"' || symbol.text.find('\\') != std::string::npos)
                fail("external symbol name must be a plain string literal without escapes");
            externalName = symbol.text.substr(1, symbol.text.size() - 2);
            if (externalName.empty())
                fail("external symbol name must not be empty");
            // C-IMP-4 (§3.6): a non-ASCII name here is an Aster source name,
            // not a C symbol — the lowering mangles it to its ASCII ABI
            // symbol (`__aster_cn_<hex>`), so it is not rejected.
            expect("RParen", "expected ')' after the external symbol name");
        }
        expect("Method", "expected a method declaration");
        MethodDeclaration method;
        method.line = methodStart.line;
        method.column = methodStart.column;
        method.sourceFile = sourceFile_;
        method.isExternal = external;
        method.externalName = externalName;
        if (language_ == Language::Zh && at("Identifier") && current().text == "main")
            fail("中文入口方法应命名为“启动方法”，不能使用“main”");
        method.name = parseName();
        expect("LParen", "expected '(' after the method name");
        skipNewlines();
        if (!at("RParen")) {
            while (true) {
                Parameter parameter;
                parameter.name = parseName();
                expect("Colon", "expected ':' after a parameter name");
                parseParameterType(parameter);
                method.parameters.push_back(std::move(parameter));
                skipNewlines();
                if (!eat("Comma")) break;
                skipNewlines();
            }
        }
        expect("RParen", "expected ')' after method parameters");
        // C-1 (P9): an English file in a bilingual project must accept the
        // mainline English spelling `fn f(...) -> T` as well as the colon
        // form `fn f(...): T` the bilingual design settled on (D-16). The
        // arrow is only accepted in En mode; zh keeps the colon alone.
        if (eat("Colon")) method.returnType = parseType();
        else if (language_ == Language::En && eat("Arrow")) method.returnType = parseType();
        else method.returnType = "void";
        if (external) {
            if (method.externalName.empty()) method.externalName = method.name;
            if (language_ == Language::En) {
                for (unsigned char byte : method.externalName)
                    if (byte >= 0x80)
                        fail("external method names must use ASCII for the C ABI");
            }
            requireTerminator();
            return method;
        }
        method.body = parseBlock("Method");
        return method;
    }
    // P1-3: `类型 别名 = 类型` / `type Alias = Type;` (EBNF `alias`,
    // design §2.9). The alias name is registered so a later duplicate is a
    // parse error, like a duplicate structure or class; the type itself is
    // resolved by the lowering, which needs the program's structures
    // registered first.
    TypeAliasDeclaration parseTypeAlias() {
        const Token start = expect("TypeAlias", "expected a type alias declaration");
        TypeAliasDeclaration alias;
        alias.line = start.line;
        alias.column = start.column;
        alias.sourceFile = sourceFile_;
        alias.name = parseName();
        if (!aliasNames_.insert(alias.name).second)
            throw std::runtime_error("duplicate type alias declaration: " + alias.name + " at " +
                std::to_string(alias.line) + ":" + std::to_string(alias.column));
        expect("Eq", "expected '=' after a type alias name");
        alias.typeName = parseType();
        requireTerminator();
        return alias;
    }
    // P1-3: `导入 "文件.ast"` / `include "file.ast";` (EBNF `include`,
    // design §2.10: file-level sharing, as opposed to the logical-module
    // `@导入`. The path is resolved relative to the importing file by
    // cnResolvePackageImports; the parser only records it.
    FileImportDeclaration parseFileImport() {
        const Token start = expect("IncludeKw", "expected a file import");
        const Token file = expect("String", "expected a string file name after the import keyword");
        if (file.text.size() < 2 || file.text.front() != '"' ||
            file.text.back() != '"' || file.text.find('\\') != std::string::npos)
            fail("import file name must be a plain string literal without escapes");
        FileImportDeclaration import;
        import.line = start.line;
        import.column = start.column;
        import.sourceFile = sourceFile_;
        import.path = file.text.substr(1, file.text.size() - 2);
        if (import.path.empty()) fail("import file name must not be empty");
        requireTerminator();
        return import;
    }
    Statement parseExternalGlobal() {
        const Token start = expect("Extern", "expected 'extern' before an external global");
        std::string externalName;
        if (language_ == Language::Zh) {
            expect("LParen", "expected '(' after '外部'");
            const Token symbol = expect("String", "expected an ASCII symbol name after '外部('");
            if (symbol.text.size() < 2 || symbol.text.front() != '"' ||
                symbol.text.back() != '"' || symbol.text.find('\\') != std::string::npos)
                fail("external symbol name must be a plain string literal without escapes");
            externalName = symbol.text.substr(1, symbol.text.size() - 2);
            if (externalName.empty()) fail("external symbol name must not be empty");
            // C-IMP-4 (§3.6): same as methods — a non-ASCII name is an Aster
            // source name, mangled by the lowering to its ASCII ABI symbol.
            expect("RParen", "expected ')' after the external symbol name");
        }
        Statement global = parseVariable(false);
        global.line = start.line;
        global.column = start.column;
        global.isExternal = true;
        global.externalName = externalName.empty() ? global.name : externalName;
        if (global.hasExpression)
            throw std::runtime_error("external global declarations cannot have an initializer at " +
                std::to_string(global.line) + ":" + std::to_string(global.column));
        if (global.typeName.empty())
            throw std::runtime_error("external global declarations need an explicit type at " +
                std::to_string(global.line) + ":" + std::to_string(global.column));
        return global;
    }
    Expression parseClosure() {
        const Token start = expect("Method", "expected an anonymous method");
        auto closure = std::make_shared<ClosureDeclaration>();
        closure->line = start.line;
        closure->column = start.column;
        if (eat("LBracket")) {
            std::set<std::string> seenCaptures;
            skipNewlines();
            if (!at("RBracket")) {
                while (true) {
                    if (eat("Amp"))
                        fail(language_ == Language::Zh
                            ? "闭包只支持按值捕获"
                            : "closures only support by-value captures");
                    const std::string capture = eat("ThisKw") ? "this" : parseName();
                    if (!seenCaptures.insert(capture).second)
                        fail(language_ == Language::Zh
                            ? "闭包捕获项重复: " + capture
                            : "duplicate closure capture: " + capture);
                    closure->captures.push_back(capture);
                    skipNewlines();
                    if (!eat("Comma")) break;
                    skipNewlines();
                }
            }
            expect("RBracket", "expected ']' after the capture list");
        }
        expect("LParen", "expected '(' after the closure capture list");
        skipNewlines();
        if (!at("RParen")) {
            while (true) {
                Parameter parameter;
                parameter.name = parseName();
                expect("Colon", "expected ':' after a closure parameter name");
                parseParameterType(parameter);
                closure->parameters.push_back(std::move(parameter));
                skipNewlines();
                if (!eat("Comma")) break;
                skipNewlines();
            }
        }
        expect("RParen", "expected ')' after closure parameters");
        if (eat("Colon")) closure->returnType = parseType();
        // C-1 (P9): English closures accept `->` for the return type, as
        // English method declarations do (`fn[x](...) -> T`).
        else if (language_ == Language::En && eat("Arrow")) closure->returnType = parseType();
        else closure->returnType = "void";
        closure->body = parseBlock("Method");
        Expression expression;
        expression.kind = "ClosureExpression";
        expression.closure = std::move(closure);
        expression.line = start.line;
        expression.column = start.column;
        return expression;
    }
    // P1-23 (design §2.9 D-10): `字段` must not be used as an ordinary
    // field name in a structure or class. It stays an ordinary identifier
    // everywhere else (notably as an enum-loop binding), so the check is a
    // spelling check on the field name, not a keyword: registering it as a
    // keyword would reject every other identifier use.
    std::string parseFieldName() {
        const std::string name = parseName();
        if (name == "字段")
            fail(language_ == Language::Zh
                ? "“字段”是保留字，不能用作字段名"
                : "'字段' is a reserved word and cannot be used as a field name");
        return name;
    }
    StructDeclaration parseStruct() {
        const Token start = expect("StructKw", "expected a structure declaration");
        StructDeclaration structure;
        structure.line = start.line;
        structure.column = start.column;
        structure.sourceFile = sourceFile_;
        structure.name = parseName();
        if (!declaredStructureNames_.insert(structure.name).second)
            throw std::runtime_error("duplicate structure declaration: " + structure.name + " at " +
                std::to_string(structure.line) + ":" + std::to_string(structure.column));
        structureNames_.insert(structure.name);
        if (language_ == Language::En) {
            skipNewlines();
            expect("LBrace", "expected '{' after the structure name");
            skipNewlines();
            while (!at("RBrace")) {
                if (at("End")) fail("unexpected end of file inside a structure declaration");
                const Token fieldStart = current();
                StructFieldDeclaration field;
                field.line = fieldStart.line;
                field.column = fieldStart.column;
                field.sourceFile = sourceFile_;
                field.name = parseFieldName();
                expect("Colon", "expected ':' after a field name");
                field.typeName = parseType();
                if (eat("LBracket")) {
                    field.arrayDimensions.push_back(expect("Number", "expected a fixed array length").text);
                    expect("RBracket", "expected ']' after the array length");
                    if (at("LBracket")) fail("the current compiler backend supports one-dimensional structure array fields");
                }
                structure.fields.push_back(std::move(field));
                if (eat("Comma")) skipNewlines();
                else if (eat("Newline")) skipNewlines();
                else if (!at("RBrace")) fail("expected ',' or a newline between structure fields");
            }
            expect("RBrace", "expected '}' after the structure fields");
        } else {
            requireBlockLine();
            while (!at("EndKw")) {
                skipNewlines();
                if (at("EndKw")) break;
                if (at("End")) fail("unexpected end of file inside a structure declaration");
                const Token fieldStart = current();
                StructFieldDeclaration field;
                field.line = fieldStart.line;
                field.column = fieldStart.column;
                field.sourceFile = sourceFile_;
                field.name = parseFieldName();
                expect("Colon", "expected ':' after a field name");
                field.typeName = parseType();
                if (eat("LBracket")) {
                    field.arrayDimensions.push_back(expect("Number", "expected a fixed array length").text);
                    expect("RBracket", "expected ']' after the array length");
                    if (at("LBracket")) fail("the current compiler backend supports one-dimensional structure array fields");
                }
                structure.fields.push_back(std::move(field));
                requireTerminator();
            }
            expect("EndKw", "expected '结束' to close the structure");
            if (!eat("StructKw")) fail("mismatched block close; expected '结构'");
        }
        // P1-9: an empty structure is allowed by the EBNF (`{ field }` is
        // zero or more); whether it means anything is for the semantic phase.
        return structure;
    }
    ClassDeclaration parseClass() {
        const Token start = expect("Class", "expected a class declaration");
        ClassDeclaration declaration;
        declaration.line = start.line;
        declaration.column = start.column;
        declaration.sourceFile = sourceFile_;
        declaration.name = parseName();
        if (!declaredClassNames_.insert(declaration.name).second)
            throw std::runtime_error("duplicate class declaration: " + declaration.name + " at " +
                std::to_string(declaration.line) + ":" + std::to_string(declaration.column));
        classNames_.insert(declaration.name);
        if (eat("Colon")) {
            declaration.baseName = parseName();
            if (eat("Dot")) declaration.baseName += "." + parseName();
            if (at("Comma")) fail("multiple class bases are not supported");
        }
        auto parseMember = [&]() {
            const ClassMemberAnnotations annotations = parseClassMemberAnnotations();
            if (at("Method")) {
                MethodDeclaration method = parseMethod();
                if (annotations.isConstructor && annotations.isStatic)
                    fail("a constructor cannot be static");
                method.visibility = annotations.visibility;
                method.isStatic = annotations.isStatic;
                method.isConstructor = annotations.isConstructor;
                method.isOverride = annotations.isOverride;
                declaration.methods.push_back(std::move(method));
                return;
            }
            if (!at("VarDecl"))
                fail("class bodies only allow fields and methods");
            if (annotations.isConstructor)
                fail("'@构造' can only annotate class methods");
            if (annotations.isOverride)
                fail("'@重写' can only annotate class methods");
            // P1-23: `字段` as a class field name is rejected by the
            // spelling check after parsing (it stays an ordinary identifier
            // elsewhere, so it is not a keyword).
            const Statement field = parseVariable(false);
            if (field.name == "字段")
                fail(language_ == Language::Zh
                    ? "“字段”是保留字，不能用作字段名"
                    : "'字段' is a reserved word and cannot be used as a field name");
            if (field.typeName.empty())
                throw std::runtime_error("class field needs an explicit type at " +
                    std::to_string(field.line) + ":" + std::to_string(field.column));
            if (field.arrayDimensions.size() > 1)
                throw std::runtime_error("the current compiler backend supports one-dimensional class array fields at " +
                    std::to_string(field.line) + ":" + std::to_string(field.column));
            StructFieldDeclaration converted;
            converted.name = field.name;
            converted.typeName = field.typeName;
            converted.arrayDimensions = field.arrayDimensions;
            converted.isStatic = annotations.isStatic;
            converted.hasInitializer = field.hasExpression;
            if (field.hasExpression) converted.initializer = field.expression;
            converted.visibility = annotations.visibility;
            converted.line = field.line;
            converted.column = field.column;
            converted.sourceFile = sourceFile_;
            converted.sourceLanguage = language_;
            declaration.fields.push_back(std::move(converted));
        };
        if (language_ == Language::En) {
            skipNewlines();
            expect("LBrace", "expected '{' after the class header");
            skipNewlines();
            while (!at("RBrace")) {
                if (at("End")) fail("unexpected end of file inside a class declaration");
                parseMember();
                skipNewlines();
            }
            expect("RBrace", "expected '}' after the class body");
        } else {
            requireBlockLine();
            while (!at("EndKw")) {
                skipNewlines();
                if (at("EndKw")) break;
                if (at("End")) fail("unexpected end of file inside a class declaration");
                parseMember();
            }
            expect("EndKw", "expected '结束' to close the class");
            if (!eat("Class")) fail("mismatched block close; expected '类'");
        }
        return declaration;
    }
    InterfaceMethodSignature parseMethodSignature() {
        const Token methodStart = expect("Method", "expected a method signature");
        InterfaceMethodSignature method;
        method.line = methodStart.line;
        method.column = methodStart.column;
        method.name = parseName();
        expect("LParen", "expected '(' after the method name");
        skipNewlines();
        if (!at("RParen")) {
            while (true) {
                Parameter parameter;
                parameter.name = parseName();
                expect("Colon", "expected ':' after a parameter name");
                parseParameterType(parameter);
                method.parameters.push_back(std::move(parameter));
                skipNewlines();
                if (!eat("Comma")) break;
                skipNewlines();
            }
        }
        expect("RParen", "expected ')' after method parameters");
        // C-1 (P9): same `->` acceptance as parseMethod, for English
        // interface method signatures (`fn f(...) -> T;`).
        if (eat("Colon")) method.returnType = parseType();
        else if (language_ == Language::En && eat("Arrow")) method.returnType = parseType();
        else method.returnType = "void";
        requireTerminator();
        return method;
    }
    InterfaceClassDeclaration parseInterfaceClass() {
        const Token start = expect("InterfaceClass", "expected an interface class declaration");
        InterfaceClassDeclaration declaration;
        declaration.line = start.line;
        declaration.column = start.column;
        declaration.sourceFile = sourceFile_;
        declaration.name = parseName();
        if (!declaredInterfaceClassNames_.insert(declaration.name).second)
            throw std::runtime_error("duplicate interface class declaration: " + declaration.name +
                " at " + std::to_string(declaration.line) + ":" +
                std::to_string(declaration.column));
        interfaceClassNames_.insert(declaration.name);
        if (eat("Colon")) {
            declaration.baseName = parseName();
            if (eat("Dot")) declaration.baseName += "." + parseName();
        }
        auto parseSignature = [&]() {
            if (!at("Method"))
                fail("interface class bodies only allow method signatures");
            declaration.methods.push_back(parseMethodSignature());
        };
        if (language_ == Language::En) {
            skipNewlines();
            expect("LBrace", "expected '{' after the interface class name");
            skipNewlines();
            while (!at("RBrace")) {
                if (at("End")) fail("unexpected end of file inside an interface class declaration");
                parseSignature();
                skipNewlines();
            }
            expect("RBrace", "expected '}' after the interface class body");
        } else {
            requireBlockLine();
            while (!at("EndKw")) {
                skipNewlines();
                if (at("EndKw")) break;
                if (at("End")) fail("unexpected end of file inside an interface class declaration");
                parseSignature();
            }
            expect("EndKw", "expected '结束' to close the interface class");
            if (!eat("InterfaceClass")) fail("mismatched block close; expected '接口类'");
        }
        return declaration;
    }
    EnumDeclaration parseEnum() {
        const Token start = expect("EnumKw", "expected an enum declaration");
        EnumDeclaration enumeration;
        enumeration.line = start.line;
        enumeration.column = start.column;
        enumeration.sourceFile = sourceFile_;
        enumeration.name = parseName();
        auto parseMember = [&]() {
            const Token memberStart = current();
            EnumMemberDeclaration member;
            member.line = memberStart.line;
            member.column = memberStart.column;
            member.name = parseName();
            if (eat("Eq")) {
                member.hasExpression = true;
                member.expression = parseExpression();
            }
            enumeration.members.push_back(std::move(member));
        };
        if (language_ == Language::En) {
            skipNewlines();
            expect("LBrace", "expected '{' after the enum name");
            skipNewlines();
            while (!at("RBrace")) {
                if (at("End")) fail("unexpected end of file inside an enum declaration");
                parseMember();
                if (eat("Comma")) skipNewlines();
                else if (eat("Newline")) skipNewlines();
                else if (!at("RBrace")) fail("expected ',' or a newline between enum members");
            }
            expect("RBrace", "expected '}' after enum members");
        } else {
            requireBlockLine();
            while (!at("EndKw")) {
                skipNewlines();
                if (at("EndKw")) break;
                if (at("End")) fail("unexpected end of file inside an enum declaration");
                parseMember();
                eat("Comma");
                requireTerminator();
            }
            expect("EndKw", "expected '结束' to close the enum");
            if (!eat("EnumKw")) fail("mismatched block close; expected '枚举'");
        }
        if (enumeration.members.empty())
            throw std::runtime_error("enum '" + enumeration.name + "' must declare at least one member at " +
                std::to_string(enumeration.line) + ":" + std::to_string(enumeration.column));
        return enumeration;
    }
    std::vector<Statement> parseBlock(const char* expectedEndKind) {
        DepthGuard guard(blockDepth_, "block", current());
        if (language_ == Language::En) {
            skipNewlines();
            expect("LBrace", "expected '{' to open a block");
            std::vector<Statement> body = parseStatementsUntil({"RBrace"});
            expect("RBrace", "expected '}' to close the block");
            return body;
        }
        requireBlockLine();
        std::vector<Statement> body = parseStatementsUntil({"EndKw"});
        expect("EndKw", "expected '结束' to close the block");
        if (!eat(expectedEndKind))
            fail(std::string("mismatched block close; expected '") + expectedEndKind + "'");
        return body;
    }
    std::vector<Statement> parseChineseIfBody() {
        requireBlockLine();
        return parseStatementsUntil({"ElseIf", "Else", "EndKw"});
    }
    // P1-6: stopAtDefault is only for English switch arms: a bare
    // `default:` starts the default arm, so a case arm's body must stop
    // there. (A variable literally named `default` cannot start an
    // expression statement inside a switch arm; `let default` still works,
    // because that statement starts with `let`, not `default`.)
    std::vector<Statement> parseStatementsUntil(std::initializer_list<const char*> stops,
                                                bool stopAtDefault = false) {
        DepthGuard guard(stmtsUntilDepth_, "statement list", current());
        std::vector<Statement> body;
        while (!at("End")) {
            skipNewlines();
            bool stop = false;
            for (const char* kind : stops) if (at(kind)) { stop = true; break; }
            if (!stop && stopAtDefault && language_ == Language::En && atWord("default"))
                stop = true;
            if (stop) return body;
            body.push_back(parseStatement());
        }
        fail("unexpected end of file inside a block");
    }
    Statement parseStatement() {
        DepthGuard guard(stmtDepth_, "statement", current());
        // D-2a: node rows are only valid inside a layout body (layoutDepth_
        // is raised while parsing one, including its `如果` branches). A
        // two-identifier statement anywhere else is a misplaced node row,
        // not a valid expression, so reject it with the position, not a
        // generic terminator error.
        if (nodeRowAhead()) {
            if (layoutDepth_ == 0)
                fail("a node row is only allowed inside a layout declaration");
            return parseNodeRowStatement();
        }
        if (at("VarDecl")) return parseVariable(false);
        if (at("ConstDecl")) return parseVariable(true);
        if (at("Return")) return parseReturn();
        if (at("If")) return parseIf();
        if (at("Match")) return parseMatch();
        if (at("WhileLoop")) return parseWhile();
        if (at("CountLoop")) return parseCountLoop();
        if (at("ForEachLoop")) return parseForEachLoop();
        if (at("EnumLoop")) return parseEnumLoop();
        if (at("BreakKw")) return parseLoopControl("BreakStatement");
        if (at("ContinueKw")) return parseLoopControl("ContinueStatement");

        Expression left = parseExpression();
        if (eat("Eq")) {
            Statement statement;
            statement.line = left.line;
            statement.column = left.column;
            statement.kind = "AssignmentStatement";
            Expression right = parseExpression();
            statement.expression.kind = "Assignment";
            statement.expression.value = "=";
            statement.expression.children.push_back(std::move(left));
            statement.expression.children.push_back(std::move(right));
            statement.hasExpression = true;
            requireTerminator();
            return statement;
        }
        Statement statement;
        statement.line = left.line;
        statement.column = left.column;
        statement.kind = "ExpressionStatement";
        statement.expression = std::move(left);
        statement.hasExpression = true;
        requireTerminator();
        return statement;
    }
    Statement parseVariable(bool isConstant) {
        const Token start = current();
        ++position_;
        Statement statement;
        statement.line = start.line;
        statement.column = start.column;
        statement.sourceFile = sourceFile_;
        statement.kind = isConstant ? "ConstantDeclaration" : "VariableDeclaration";
        statement.name = parseName();
        if (eat("Colon")) {
            statement.typeName = parseType();
            // P1-7: one dimension only, matching struct/class fields (which
            // already reject a second dimension) and the EBNF/design
            // one-dimensional rule. No existing suite depends on multi-
            // dimensional variables (checked 2026-11-23); the only
            // multi-dimensional case in the cn suites is the parameter
            // rejection test in cn-backend-checks.sh.
            if (eat("LBracket")) {
                statement.arrayDimensions.push_back(
                    expect("Number", "expected a fixed array length").text);
                expect("RBracket", "expected ']' after the array length");
                if (at("LBracket"))
                    fail("the current compiler backend supports one-dimensional arrays");
            }
        }
        if (eat("Eq")) {
            statement.hasExpression = true;
            statement.expression = parseExpression();
        }
        if (isConstant && (statement.typeName.empty() || !statement.hasExpression))
            fail("a constant needs a type and an initializer");
        requireTerminator();
        return statement;
    }
    Statement parseReturn() {
        const Token start = current();
        ++position_;
        Statement statement;
        statement.line = start.line;
        statement.column = start.column;
        statement.kind = "ReturnStatement";
        if (!at("Newline") && !at("Semi") && !at("EndKw") && !at("RBrace") && !at("End")) {
            statement.expression = parseExpression();
            statement.hasExpression = true;
        }
        requireTerminator();
        return statement;
    }
    Statement parseLoopControl(const char* kind) {
        const Token start = current();
        ++position_;
        Statement statement;
        statement.line = start.line;
        statement.column = start.column;
        statement.kind = kind;
        if (at("Identifier")) statement.name = parseName();
        requireTerminator();
        return statement;
    }
    Expression parseCondition() {
        if (eat("LParen")) {
            Expression condition = parseExpression();
            expect("RParen", "expected ')' after the condition");
            return condition;
        }
        if (language_ == Language::En) fail("expected '(' before the condition");
        return parseExpression();
    }
    Statement parseWhile() {
        const Token start = current();
        ++position_;
        Statement statement;
        statement.line = start.line;
        statement.column = start.column;
        statement.kind = "WhileLoopStatement";
        statement.expression = parseCondition();
        statement.hasExpression = true;
        statement.body = parseBlock("WhileLoop");
        return statement;
    }
    Statement parseCountLoop() {
        const Token start = current();
        ++position_;
        Statement statement;
        statement.line = start.line;
        statement.column = start.column;
        statement.kind = "CountLoopStatement";
        expect("LParen", "expected '(' after the counting-loop keyword");
        if ((at("Identifier") || at("Main")) && position_ + 1 < tokens_.size() &&
            tokens_[position_ + 1].kind == "Eq") {
            statement.name = parseName();
            expect("Eq", "expected '=' after the counting-loop variable");
        }
        statement.expressions.push_back(parseExpression());
        expect("Comma", "expected ',' after the counting-loop start value");
        statement.expressions.push_back(parseExpression());
        if (eat("Comma")) { skipNewlines(); statement.expressions.push_back(parseExpression()); }
        expect("RParen", "expected ')' after the counting-loop range");
        statement.body = parseBlock("CountLoop");
        return statement;
    }
    Statement parseForEachLoop() {
        const Token start = current();
        ++position_;
        Statement statement;
        statement.line = start.line;
        statement.column = start.column;
        statement.kind = "ForEachLoopStatement";
        if (language_ == Language::Zh)
            expect("LParen", "expected '(' after the foreach keyword");
        statement.name = parseName();
        if (eat("Comma")) { skipNewlines(); statement.secondaryName = parseName(); }
        expect(language_ == Language::Zh ? "Arrow" : "InKw",
               language_ == Language::Zh
                   ? "expected '->' before the array being traversed"
                   : "expected 'in' before the array being traversed");
        statement.expression = parseExpression();
        statement.hasExpression = true;
        if (language_ == Language::Zh)
            expect("RParen", "expected ')' after the foreach source");
        statement.body = parseBlock("ForEachLoop");
        return statement;
    }
    Statement parseEnumLoop() {
        const Token start = current();
        ++position_;
        Statement statement;
        statement.line = start.line;
        statement.column = start.column;
        statement.kind = "EnumLoopStatement";
        if (language_ == Language::Zh) {
            expect("LParen", "expected '(' after the enum-loop keyword");
            statement.name = parseName();
            expect("Arrow", "expected '->' before the object being enumerated");
            statement.expression = parseExpression();
            expect("RParen", "expected ')' after the enum-loop object");
        } else {
            statement.name = parseName();
            expect("InKw", "expected 'in' before the object being enumerated");
            statement.expression = parseExpression();
        }
        statement.hasExpression = true;
        statement.body = parseBlock("EnumLoop");
        return statement;
    }
    Expression parseMatchPattern() {
        Expression lower = parseExpression();
        if (language_ == Language::Zh && atWord("到")) {
            fail("范围匹配尚未实现，请用 '如果…否则如果' 改写");
        } else if (language_ == Language::Zh && atWord("及以上")) {
            fail("范围匹配尚未实现，请用 '如果…否则如果' 改写");
        } else if (language_ == Language::En && atWord("to")) {
            fail("range matching is not implemented; rewrite with 'if...else if'");
        } else if (language_ == Language::En && atWord("and") && wordAhead(1, "above")) {
            fail("range matching is not implemented; rewrite with 'if...else if'");
        }
        return lower;
    }

    Statement parseMatch() {
        const Token start = current();
        ++position_;
        Statement statement;
        statement.line = start.line;
        statement.column = start.column;
        statement.kind = "MatchStatement";
        statement.expression = parseCondition();
        statement.hasExpression = true;

        if (language_ == Language::Zh) {
            requireBlockLine();
            while (at("CaseArm")) {
                ++position_;
                std::vector<Expression> values;
                // D-3 (i): skip newlines only after a comma. The newline
                // after the LAST value is requireBlockLine's terminator
                // below; skipping it here would eat the block line.
                while (true) {
                    values.push_back(parseMatchPattern());
                    if (!eat("Comma")) break;
                    skipNewlines();
                }
                requireBlockLine();
                statement.caseValues.push_back(std::move(values));
                statement.branches.push_back(parseStatementsUntil({"CaseArm", "Else", "EndKw"}));
            }
            // P1-9: an empty match is allowed by the EBNF
            // (`{ match_arm }` is zero or more); the lowering treats it as
            // a no-op (or just the else body).
            if (eat("Else")) {
                statement.hasElse = true;
                requireBlockLine();
                statement.elseBody = parseStatementsUntil({"EndKw"});
            }
            expect("EndKw", "expected '结束' after the match");
            expect("Match", "expected '结束 假如' after the match");
            return statement;
        }

        expect("LBrace", "expected '{' after the switch subject");
        skipNewlines();
        // P1-6: English switch accepts the mainline forms `case <expr>:` and
        // `default:` (docs/language-reference.md). The older bilingual form
        // without a colon (`case 1` + newline) and the EBNF `else` default
        // keep working. `default` is not a cn keyword, so it is matched as
        // the identifier `default` followed by `:`.
        bool sawDefault = false;
        while (true) {
            if (at("CaseArm")) {
                ++position_;
                std::vector<Expression> values;
                // D-3 (i): skip newlines only after a comma (see the
                // Chinese arm above: the line end after the last value
                // belongs to the arm body).
                while (true) {
                    values.push_back(parseMatchPattern());
                    if (!eat("Comma")) break;
                    skipNewlines();
                }
                if (!eat("Colon")) requireBlockLine();
                statement.caseValues.push_back(std::move(values));
                statement.branches.push_back(parseStatementsUntil({"CaseArm", "Else", "RBrace"}, true));
            } else if (!sawDefault && atWord("default")) {
                ++position_;
                expect("Colon", "expected ':' after 'default'");
                statement.hasElse = true;
                sawDefault = true;
                statement.elseBody = parseStatementsUntil({"CaseArm", "Else", "RBrace"}, true);
            } else if (!sawDefault && eat("Else")) {
                statement.hasElse = true;
                sawDefault = true;
                requireBlockLine();
                statement.elseBody = parseStatementsUntil({"CaseArm", "Else", "RBrace"}, true);
            } else {
                break;
            }
        }
        if (at("Else") || atWord("default"))
            fail("a switch can have only one 'default' branch");
        expect("RBrace", "expected '}' after the switch");
        return statement;
    }
    Statement parseIf() {
        DepthGuard guard(ifDepth_, "if statement", current());
        const Token start = current();
        ++position_;
        Statement statement;
        statement.line = start.line;
        statement.column = start.column;
        statement.kind = "IfStatement";
        statement.conditions.push_back(parseCondition());
        if (language_ == Language::Zh) {
            statement.branches.push_back(parseChineseIfBody());
            while (eat("ElseIf")) {
                statement.conditions.push_back(parseCondition());
                statement.branches.push_back(parseChineseIfBody());
            }
            if (eat("Else")) {
                statement.hasElse = true;
                // D-3 (i): `else if` written as two words desugars to
                // `else { if ... }`; the lowering lowers the nested if
                // directly. (zh normally writes the single keyword
                // `否则如果`, but the two-word form is accepted too.)
                if (at("If")) statement.elseBody.push_back(parseIf());
                else statement.elseBody = parseChineseIfBody();
            }
            expect("EndKw", "expected '结束 如果' after the conditional");
            expect("If", "expected '结束 如果' after the conditional");
            return statement;
        }
        statement.branches.push_back(parseBlock("If"));
        // D-3 (i): the framework writes `}` and `else` on separate lines,
        // so skip newlines before looking for the next arm; the statement
        // list skips them anyway, so this cannot swallow a following
        // statement.
        skipNewlines();
        while (eat("ElseIf")) {
            statement.conditions.push_back(parseCondition());
            statement.branches.push_back(parseBlock("If"));
            skipNewlines();
        }
        if (eat("Else")) {
            statement.hasElse = true;
            // D-3 (i): `else if` is two tokens in English; desugar to
            // `else { if ... }` (see the Chinese branch above).
            if (at("If")) statement.elseBody.push_back(parseIf());
            else statement.elseBody = parseBlock("If");
        }
        return statement;
    }

    static int precedence(const std::string& kind) {
        // C precedence, loosest first (`a & b == c` is `a & (b == c)`:
        // equality binds tighter than bitwise AND, the classic C rule).
        if (kind == "Or") return 1;
        if (kind == "And") return 2;
        if (kind == "BitOr") return 3;
        if (kind == "BitXor") return 4;
        if (kind == "Amp") return 5;
        if (kind == "EqEq" || kind == "Ne") return 6;
        if (kind == "Lt" || kind == "Le" || kind == "Gt" || kind == "Ge") return 7;
        // D-3 (i): shifts sit between additive and relational, as in C
        // (`a + b << c` is `(a + b) << c`); the mainline shift() level.
        if (kind == "Shl" || kind == "Shr") return 8;
        if (kind == "Plus" || kind == "Minus") return 9;
        if (kind == "Star" || kind == "Slash" || kind == "Percent") return 10;
        return 0;
    }
    static std::string operatorName(const std::string& kind) {
        if (kind == "Or") return "||";
        if (kind == "And") return "&&";
        if (kind == "EqEq") return "==";
        if (kind == "Ne") return "!=";
        if (kind == "Lt") return "<";
        if (kind == "Le") return "<=";
        if (kind == "Gt") return ">";
        if (kind == "Ge") return ">=";
        if (kind == "Plus") return "+";
        if (kind == "Minus") return "-";
        if (kind == "Star") return "*";
        if (kind == "Slash") return "/";
        if (kind == "Percent") return "%";
        if (kind == "Shl") return "<<";
        if (kind == "Shr") return ">>";
        if (kind == "BitOr") return "|";
        if (kind == "BitXor") return "^";
        if (kind == "Not") return "!";
        if (kind == "Tilde") return "~";
        if (kind == "Amp") return "&";
        return kind;
    }
    Expression parseExpression(int minimumPrecedence = 1) {
        DepthGuard guard(exprDepth_, "expression", current());
        Expression left = parseUnary();
        while (true) {
            // D-3 (i): an operator may also LEAD the next line
            // (`(a << 8)\n | b`): look past newlines; if a binary operator
            // follows, continue the expression. A newline followed by
            // anything else still ends it.
            if (at("Newline")) {
                std::size_t probe = position_;
                while (probe < tokens_.size() && tokens_[probe].kind == "Newline") ++probe;
                if (probe >= tokens_.size() || precedence(tokens_[probe].kind) == 0) break;
                position_ = probe;
            }
            const int priority = precedence(current().kind);
            if (priority < minimumPrecedence) break;
            const std::string op = operatorName(current().kind);
            ++position_;
            // D-3 (i): an operand may start on the next line (`a &&\n b`,
            // `x +\n y`); inside an expression a newline never terminates
            // a statement, in either language.
            skipNewlines();
            Expression right = parseExpression(priority + 1);
            Expression binary;
            binary.kind = "Binary";
            binary.value = op;
            binary.children.push_back(std::move(left));
            binary.children.push_back(std::move(right));
            left = std::move(binary);
        }
        // P1-5: ternary `条件 ? 值1 : 值2`, right-associative, lowest
        // precedence (below `||`), mirroring the mainline parser's expr()
        // (`c ? a : b`, both arms at full precedence). Only handled at the
        // outermost level of this call (minimumPrecedence == 1): a binary
        // right-hand side parses with a higher minimum, so `a + b ? c : d`
        // groups as `(a + b) ? c : d`, as in C. The lowering emits
        // Expr::Cond; the condition must be bool and both arms must agree.
        // NOTE for the doc group (EBNF lacks a ternary production): the
        // implemented form is
        //   expression = logical_or, [ "?", expression, ":", expression ] ;
        // with the middle and else arms parsed at full expression
        // precedence, so `a ? b : c ? d : e` nests right.
        if (minimumPrecedence == 1 && at("Question")) {
            ++position_;
            skipNewlines();
            Expression middle = parseExpression();
            expect("Colon", "expected ':' in conditional expression");
            skipNewlines();
            Expression otherwise = parseExpression();
            Expression conditional;
            conditional.kind = "Conditional";
            conditional.line = left.line;
            conditional.column = left.column;
            conditional.children.push_back(std::move(left));
            conditional.children.push_back(std::move(middle));
            conditional.children.push_back(std::move(otherwise));
            return conditional;
        }
        return left;
    }
    Expression parseUnary() {
        DepthGuard guard(unaryDepth_, "unary expression", current());
        if (at("Minus") || at("Not") || at("Tilde") || at("Amp") || at("Star")) {
            const std::string op = operatorName(current().kind);
            ++position_;
            Expression expression;
            expression.kind = "Unary";
            expression.value = op;
            expression.children.push_back(parseUnary());
            return expression;
        }
        return parsePostfix(parsePrimary());
    }
    Expression parsePrimary() {
        DepthGuard guard(primaryDepth_, "expression", current());
        const Token token = current();
        auto make = [&](const char* kind, const std::string& value) {
            Expression expression{kind, value, {}, nullptr, token.line, token.column};
            expression.line = token.line;
            expression.column = token.column;
            return expression;
        };
        if (at("Method")) return parseClosure();
        if (eat("Number")) {
            const bool hexOrBinary = token.text.size() > 1 && token.text[0] == '0' &&
                (token.text[1] == 'x' || token.text[1] == 'X' ||
                 token.text[1] == 'b' || token.text[1] == 'B');
            const bool floating = !hexOrBinary && (token.text.find('.') != std::string::npos ||
                token.text.find('e') != std::string::npos || token.text.find('E') != std::string::npos);
            return make(floating ? "FloatLiteral" : "IntegerLiteral", token.text);
        }
        if (eat("String")) return make("StringLiteral", token.text);
        if (eat("Character")) return make("CharacterLiteral", token.text);
        if (eat("LBracket")) {
            Expression expression = make("ArrayLiteral", "");
            skipNewlines();
            if (!at("RBracket")) {
                while (true) {
                    expression.children.push_back(parseExpression());
                    skipNewlines();
                    if (!eat("Comma")) break;
                    skipNewlines();
                }
            }
            expect("RBracket", "expected ']' after the array literal");
            return expression;
        }
        // D-3 (i): generic-pointer cast `ptr<T>(expr)`. The plain
        // `ptr(...)` cast below would leave `<T>` behind; confirm the
        // `<...>` is followed by `(` first, so `ptr < x` (a comparison)
        // still parses as one.
        if ((token.kind == "Ptr" ||
             (token.kind == "Identifier" && isBuiltinTypeSpelling(token.text))) &&
            position_ + 1 < tokens_.size() && tokens_[position_ + 1].kind == "Lt") {
            std::size_t depth = 0;
            std::size_t scan = position_ + 1;
            for (; scan < tokens_.size(); ++scan) {
                if (tokens_[scan].kind == "Lt") ++depth;
                else if (tokens_[scan].kind == "Gt") {
                    if (--depth == 0) break;
                } else if (tokens_[scan].kind == "Newline") break;
            }
            if (scan + 1 < tokens_.size() && tokens_[scan].kind == "Gt" &&
                tokens_[scan + 1].kind == "LParen") {
                ++position_;
                ++position_;
                const std::string inner = parseType();
                expect("Gt", "expected '>' after the pointer element type");
                return make("TypeName", "ptr<" + inner + ">");
            }
        }
        if (token.kind == "Identifier" &&
            (classNames_.count(token.text) || isBuiltinTypeSpelling(token.text)) &&
            position_ + 1 < tokens_.size() && tokens_[position_ + 1].kind == "LParen") {
            ++position_;
            return make("TypeName", token.text);
        }
        if (eat("Identifier") || eat("Main")) return make("Identifier", token.text);
        if (eat("StartMethod")) return make("Identifier", "main");
        if (token.kind == "I8" || token.kind == "I16" || token.kind == "I32" ||
            token.kind == "U32" || token.kind == "I64" ||
            token.kind == "U64" || token.kind == "U8" || token.kind == "U16" ||
            token.kind == "F32" || token.kind == "F64" || token.kind == "Bool" ||
            token.kind == "CharType" || token.kind == "StringView" || token.kind == "Ptr") {
            ++position_;
            return make("TypeName", canonicalType(token));
        }
        if (eat("TrueLit")) return make("BooleanLiteral", "true");
        if (eat("FalseLit")) return make("BooleanLiteral", "false");
        if (eat("Empty") || eat("NullLit")) return make("NullLiteral", "null");
        if (eat("ThisKw")) return make("ThisExpression", "this");
        if (eat("SuperKw")) return make("SuperExpression", "super");
        if (at("At")) {
            // B-P2: `@embed("path")` / `@embed_len("path")`, the mainline
            // embedded-blob forms (design draft attribute table): the
            // same ASCII spellings in both languages. `@embed` is the
            // address of the file's bytes, `@embed_len` folds to how many
            // there are, and `@embed` takes an optional literal alignment
            // (`@embed("path", 16)`, a power of two, at most 4096). The
            // lowering reads the file and mints the `__aster_embed_*`
            // global, so the parser only records the path (raw string
            // spelling, as for StringLiteral), the alignment literal if
            // any, and the file that wrote it (the path resolves against
            // that file's directory, the mainline rule). An `@`-name that
            // is neither is an annotation error (A-021), as for unknown
            // top-level annotations; a malformed embed argument is a
            // syntax error (A-011), so those messages carry no '@'.
            const Token atToken = current();
            ++position_;
            if (!at("Identifier") || (current().text != "embed" && current().text != "embed_len"))
                fail("expected 'embed' or 'embed_len' after '@'");
            const bool isLen = current().text == "embed_len";
            const std::string name = isLen ? "embed_len" : "embed";
            ++position_;
            const std::string afterName = "expected '(' after '" + name + "'";
            expect("LParen", afterName.c_str());
            const Token pathToken = expect("String", ("expected a file path after '" + name + "('").c_str());
            Expression expression;
            expression.kind = isLen ? "EmbedLen" : "Embed";
            expression.value = pathToken.text;
            expression.line = atToken.line;
            expression.column = atToken.column;
            expression.sourceFile = sourceFile_;
            if (eat("Comma")) {
                if (isLen)
                    fail("embed_len takes no alignment argument");
                const Token alignToken = current();
                if (!eat("Number"))
                    fail("expected a power-of-two alignment after 'embed(\"path\",'");
                Expression alignment;
                alignment.kind = "IntegerLiteral";
                alignment.value = alignToken.text;
                alignment.line = alignToken.line;
                alignment.column = alignToken.column;
                expression.children.push_back(std::move(alignment));
            }
            expect("RParen", "expected ')' after the file path");
            return expression;
        }
        if (eat("LParen")) {
            skipNewlines();
            Expression expression = parseExpression();
            skipNewlines();
            expect("RParen", "expected ')' after the expression");
            return expression;
        }
        fail("expected an expression");
    }
    Expression parsePostfix(Expression expression) {
        while (true) {
            if (expression.kind == "Identifier" && structureNames_.count(expression.value) &&
                eat("LBrace")) {
                Expression literal;
                literal.kind = "StructLiteral";
                literal.value = expression.value;
                literal.line = expression.line;
                literal.column = expression.column;
                skipNewlines();
                if (!at("RBrace")) {
                    while (true) {
                        literal.children.push_back(parseExpression());
                        skipNewlines();
                        if (!eat("Comma")) break;
                        skipNewlines();
                    }
                }
                expect("RBrace", "expected '}' after structure literal");
                expression = std::move(literal);
            } else if (eat("LParen")) {
                Expression call;
                call.kind = "Call";
                call.line = expression.line;
                call.column = expression.column;
                call.children.push_back(std::move(expression));
                skipNewlines();
                if (!at("RParen")) {
                    while (true) {
                        call.children.push_back(parseExpression());
                        skipNewlines();
                        if (!eat("Comma")) break;
                        skipNewlines();
                    }
                }
                expect("RParen", "expected ')' after call arguments");
                // D-2a (W-7): `键(名)` / `key(name)` with a single
                // identifier argument is the compile-time key builtin, not
                // an ordinary call. Any other shape stays a Call, and the
                // lowering rejects it as an unknown call.
                if (call.children.size() == 2 && call.children[0].kind == "Identifier" &&
                    (call.children[0].value == "键" || call.children[0].value == "key") &&
                    call.children[1].kind == "Identifier") {
                    Expression keyRef;
                    keyRef.kind = "KeyRef";
                    keyRef.value = call.children[1].value;
                    keyRef.line = call.line;
                    keyRef.column = call.column;
                    keyRef.sourceFile = sourceFile_;
                    expression = std::move(keyRef);
                } else {
                    expression = std::move(call);
                }
            } else if (eat("LBracket")) {
                Expression index;
                index.kind = "Index";
                index.line = expression.line;
                index.column = expression.column;
                index.children.push_back(std::move(expression));
                skipNewlines();
                index.children.push_back(parseExpression());
                skipNewlines();
                expect("RBracket", "expected ']' after the array index");
                expression = std::move(index);
            } else if (eat("Dot")) {
                Expression member;
                member.kind = "Member";
                member.line = expression.line;
                member.column = expression.column;
                member.children.push_back(std::move(expression));
                member.children.push_back({"Identifier", parseMemberName(), {}, nullptr, 0, 0});
                expression = std::move(member);
            } else {
                return expression;
            }
        }
    }
};

// P0-4: dump walks an already-parsed AST, so it is bounded by the parser
// caps above — but only loosely: one root-to-leaf dump path can stack
// statement nesting (<=256) and expression nesting (<=256) plus closure
// bodies, so the dump limit is 1024, not 256, to never false-trip on legal
// input. The message still starts with "expected " so it classifies A-011.
thread_local unsigned g_cnDumpDepth = 0;
struct CnDumpDepthGuard {
    CnDumpDepthGuard(const char* what, unsigned line, unsigned column) {
        if (++g_cnDumpDepth > 1024) {
            --g_cnDumpDepth;
            throw std::runtime_error(std::string("expected ") + what +
                " nesting within 1024 levels at " + std::to_string(line) +
                ":" + std::to_string(column));
        }
    }
    ~CnDumpDepthGuard() { --g_cnDumpDepth; }
};

void dumpStatements(std::ostringstream& out, const std::vector<Statement>& statements);

void dumpParameter(std::ostringstream& out, const Parameter& parameter) {
    out << " (Parameter " << quoted(parameter.name) << ' '
        << quoted(parameter.typeName);
    if (!parameter.arrayDimensions.empty()) {
        out << " (Dimensions";
        for (const auto& dimension : parameter.arrayDimensions)
            out << ' ' << quoted(dimension);
        out << ')';
    }
    out << ')';
}

void dumpExpression(std::ostringstream& out, const Expression& expression) {
    CnDumpDepthGuard guard("expression", expression.line, expression.column);
    out << '(' << expression.kind;
    if (!expression.value.empty()) out << ' ' << quoted(expression.value);
    for (const auto& child : expression.children) {
        out << ' ';
        dumpExpression(out, child);
    }
    // D-2a: node-row payload (only present on kind == "NodeRow").
    if (!expression.nodeName.empty()) out << " (NodeName " << quoted(expression.nodeName) << ')';
    if (!expression.modifiers.empty()) {
        out << " (Modifiers";
        for (const auto& modifier : expression.modifiers) {
            out << ' ';
            dumpExpression(out, modifier);
        }
        out << ')';
    }
    if (!expression.childRows.empty()) {
        out << " (ChildRows";
        for (const auto& childRow : expression.childRows) {
            out << ' ';
            dumpExpression(out, childRow);
        }
        out << ')';
    }
    if (!expression.childStatements.empty()) {
        out << " (ChildStatements ";
        dumpStatements(out, expression.childStatements);
        out << ')';
    }
    if (expression.hasKeyOverride) out << " (KeyOverride " << expression.keyOverride << ')';
    if (expression.closure) {
        out << " (Captures";
        for (const auto& capture : expression.closure->captures)
            out << ' ' << quoted(capture);
        out << ") (Parameters";
        for (const auto& parameter : expression.closure->parameters)
            dumpParameter(out, parameter);
        out << ") (Returns " << quoted(expression.closure->returnType) << ") ";
        dumpStatements(out, expression.closure->body);
    }
    out << ')';
}

void dumpStatements(std::ostringstream& out, const std::vector<Statement>& statements) {
    CnDumpDepthGuard guard("statement", statements.empty() ? 0 : statements.front().line,
                           statements.empty() ? 0 : statements.front().column);
    out << "(Block";
    for (const auto& statement : statements) {
        out << " (" << statement.kind;
        if (!statement.name.empty()) out << ' ' << quoted(statement.name);
        if (!statement.secondaryName.empty()) out << ' ' << quoted(statement.secondaryName);
        if (!statement.typeName.empty()) out << ' ' << quoted(statement.typeName);
        if (!statement.arrayDimensions.empty()) {
            out << " (Dimensions";
            for (const auto& dimension : statement.arrayDimensions) out << ' ' << quoted(dimension);
            out << ')';
        }
        if (statement.hasExpression) {
            out << ' ';
            dumpExpression(out, statement.expression);
        }
        for (const auto& expression : statement.expressions) {
            out << ' ';
            dumpExpression(out, expression);
        }
        for (std::size_t i = 0; i < statement.branches.size(); ++i) {
            if (statement.kind == "MatchStatement") {
                out << " (Case";
                for (const auto& value : statement.caseValues[i]) {
                    out << ' ';
                    dumpExpression(out, value);
                }
            } else {
                out << " (Branch ";
                dumpExpression(out, statement.conditions[i]);
            }
            out << ' ';
            dumpStatements(out, statement.branches[i]);
            out << ')';
        }
        if (statement.kind == "WhileLoopStatement" || statement.kind == "CountLoopStatement" ||
            statement.kind == "ForEachLoopStatement" || statement.kind == "EnumLoopStatement") {
            out << ' ';
            dumpStatements(out, statement.body);
        }
        if (statement.hasElse) {
            out << " (Else ";
            dumpStatements(out, statement.elseBody);
            out << ')';
        }
        out << ')';
    }
    out << ')';
}

}  // namespace

Program parseProgram(const std::string& source, Language language, const std::string& sourceFile) {
    try {
        return Parser(lex(source, language), language, sourceFile).run();
    } catch (const std::exception& error) {
        throw std::runtime_error(decorateDiagnostic(error.what(), language));
    }
}

std::string readPackageName(const std::string& source, Language language) {
    try {
        const std::vector<std::string> names = Parser(lex(source, language), language, {}).readPackageHeader();
        return names.empty() ? std::string() : names.front();
    } catch (const std::exception& error) {
        throw std::runtime_error(decorateDiagnostic(error.what(), language));
    }
}

std::vector<std::string> readPackageNames(const std::string& source, Language language) {
    try {
        return Parser(lex(source, language), language, {}).readPackageHeader();
    } catch (const std::exception& error) {
        throw std::runtime_error(decorateDiagnostic(error.what(), language));
    }
}

std::string dumpAst(const Program& program) {
    std::ostringstream out;
    out << "(Program";
    if (!program.packageName.empty()) {
        out << " (Package " << quoted(program.packageName);
        for (const auto& alias : program.packageAliases)
            out << " (Alias " << quoted(alias) << ')';
        out << ')';
    }
    for (const auto& import : program.imports)
        out << " (Import " << quoted(import.moduleName) << ' ' << quoted(import.alias) << ')';
    for (const auto& alias : program.aliases)
        out << " (Alias " << quoted(alias.name) << ' ' << quoted(alias.typeName) << ')';
    for (const auto& fileImport : program.fileImports)
        out << " (FileImport " << quoted(fileImport.path) << ')';
    for (const auto& enumeration : program.enums) {
        out << " (Enum " << quoted(enumeration.name) << " (Members";
        for (const auto& member : enumeration.members) {
            out << " (Member " << quoted(member.name);
            if (member.hasExpression) {
                out << ' ';
                dumpExpression(out, member.expression);
            }
            out << ')';
        }
        out << "))";
    }
    for (const auto& structure : program.structures) {
        out << " (Structure " << quoted(structure.name) << " (Fields";
        for (const auto& field : structure.fields) {
            out << " (Field " << quoted(field.name) << ' ' << quoted(field.typeName);
            if (!field.arrayDimensions.empty()) {
                out << " (Dimensions";
                for (const auto& dimension : field.arrayDimensions) out << ' ' << quoted(dimension);
                out << ')';
            }
            out << ')';
        }
        out << "))";
    }
    for (const auto& declaration : program.classes) {
        out << " (Class " << quoted(declaration.name);
        if (!declaration.baseName.empty())
            out << " (Base " << quoted(declaration.baseName) << ')';
        out << " (Fields";
        for (const auto& field : declaration.fields) {
            out << " (Field " << quoted(field.name) << ' ' << quoted(field.typeName);
            if (field.visibility != "public")
                out << " (Visibility " << quoted(astVisibility(field.visibility)) << ')';
            if (field.isStatic) out << " (Static)";
            if (!field.arrayDimensions.empty()) {
                out << " (Dimensions";
                for (const auto& dimension : field.arrayDimensions) out << ' ' << quoted(dimension);
                out << ')';
            }
            if (field.hasInitializer) {
                out << ' ';
                dumpExpression(out, field.initializer);
            }
            out << ')';
        }
        out << ") (Methods";
        for (const auto& method : declaration.methods) {
            out << " (Method " << quoted(method.name) << ' ' << quoted(method.returnType)
                << " (Parameters";
            for (const auto& parameter : method.parameters)
                dumpParameter(out, parameter);
            out << ')';
            if (method.visibility != "public")
                out << " (Visibility " << quoted(astVisibility(method.visibility)) << ')';
            if (method.isStatic) out << " (Static)";
            if (method.isConstructor) out << " (Constructor)";
            if (method.isOverride) out << " (Override)";
            out << ' ';
            dumpStatements(out, method.body);
            out << ')';
        }
        out << "))";
    }
    for (const auto& declaration : program.interfaceClasses) {
        out << " (InterfaceClass " << quoted(declaration.name);
        if (!declaration.baseName.empty())
            out << " (Base " << quoted(declaration.baseName) << ')';
        out << " (Methods";
        for (const auto& method : declaration.methods) {
            out << " (MethodSignature " << quoted(method.name) << ' '
                << quoted(method.returnType) << " (Parameters";
            for (const auto& parameter : method.parameters)
                dumpParameter(out, parameter);
            out << "))";
        }
        out << "))";
    }
    for (const auto& global : program.globals) {
        out << " (" << (global.kind == "ConstantDeclaration" ? "Constant" : "Global")
            << ' ' << quoted(global.name) << ' ' << quoted(global.typeName);
        if (!global.arrayDimensions.empty()) {
            out << " (Dimensions";
            for (const auto& dimension : global.arrayDimensions) out << ' ' << quoted(dimension);
            out << ')';
        }
        if (global.hasExpression) {
            out << ' ';
            dumpExpression(out, global.expression);
        }
        if (global.isExternal)
            out << " (External " << quoted(global.externalName) << ')';
        out << ')';
    }
    for (const auto& method : program.methods) {
        out << " (Method " << quoted(method.name) << ' ' << quoted(method.returnType) << " (Parameters";
        for (const auto& parameter : method.parameters)
            dumpParameter(out, parameter);
        out << ')';
        if (method.isExternal)
            out << " (External " << quoted(method.externalName) << ')';
        if (method.visibility != "public")
            out << " (Visibility " << quoted(astVisibility(method.visibility)) << ')';
        out << ' ';
        dumpStatements(out, method.body);
        out << ')';
    }
    // D-2a: layout declarations and event blocks.
    for (const auto& layout : program.layouts) {
        out << " (Layout " << quoted(layout.name) << ' ' << quoted(layout.returnType) << " (Parameters";
        for (const auto& parameter : layout.parameters)
            dumpParameter(out, parameter);
        out << ')';
        if (layout.visibility != "public")
            out << " (Visibility " << quoted(astVisibility(layout.visibility)) << ')';
        out << ' ';
        dumpStatements(out, layout.body);
        out << ')';
    }
    for (const auto& event : program.events) {
        out << " (Event " << quoted(event.nodeName) << ' ' << quoted(event.eventKind);
        if (event.visibility != "public")
            out << " (Visibility " << quoted(astVisibility(event.visibility)) << ')';
        out << ' ';
        dumpStatements(out, event.body);
        out << ')';
    }
    out << ')';
    return out.str();
}

}  // namespace aster_cn
