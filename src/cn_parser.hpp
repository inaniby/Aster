#pragma once

#include "cn_lexer.hpp"

#include <memory>
#include <string>
#include <vector>

namespace aster_cn {

struct ClosureDeclaration;
struct Statement;

struct Expression {
    std::string kind;
    std::string value;
    std::vector<Expression> children;
    std::shared_ptr<ClosureDeclaration> closure;
    unsigned line = 0;
    unsigned column = 0;
    // B-P2: the file that wrote this expression, for `@embed` /
    // `@embed_len` only: the embedded path resolves against its own
    // directory (the mainline rule), so the lowering must not depend
    // on which context happens to lower the expression. Other kinds
    // leave it empty; the parser stamps it on embed expressions.
    std::string sourceFile{};
    // D-2a: node-row payload (only valid when kind == "NodeRow").
    // The parser puts every comma-separated item (position arguments and
    // modifier calls alike) into `children`; the lowering classifies them
    // by the modifier table, so the parser needs no schema table.
    // `modifiers` is kept for the lowering to fill in.
    std::string nodeName{};
    std::vector<Expression> modifiers{};
    std::vector<Expression> childRows{};
    // D-2a: the child block as an ordered statement list. The drafts put
    // `如果`/`变量` inside child blocks (counter-zh:52, tab-input-zh:69),
    // so a child block is a layout-body statement list, not rows only
    // (design §1.1 anticipated relaxing this). childStatements is the
    // authoritative order for lowering; childRows is the flat projection
    // of its node rows, kept for simple consumers.
    std::vector<Statement> childStatements{};
    bool hasKeyOverride = false;
    long long keyOverride = 0;
    // D-2a: `键(名)` / `key(name)` (kind == "KeyRef"): value = node name.
};

struct Parameter {
    std::string name;
    std::string typeName;
    std::vector<std::string> arrayDimensions;
};

struct Statement {
    std::string kind;
    std::string name;
    std::string secondaryName;
    std::string typeName;
    std::string visibility = "public";
    std::string sourceFile;
    std::vector<std::string> arrayDimensions;
    unsigned line = 0;
    unsigned column = 0;
    bool hasExpression = false;
    bool isExternal = false;
    std::string externalName;
    Expression expression;
    std::vector<Expression> expressions;
    std::vector<Statement> body;
    std::vector<Expression> conditions;
    std::vector<std::vector<Expression>> caseValues;
    std::vector<std::vector<Statement>> branches;
    bool hasElse = false;
    std::vector<Statement> elseBody;
};

struct ClosureDeclaration {
    std::vector<std::string> captures;
    std::vector<Parameter> parameters;
    std::string returnType;
    std::vector<Statement> body;
    unsigned line = 0;
    unsigned column = 0;
};

struct MethodDeclaration {
    std::string name;
    std::string returnType;
    std::vector<Parameter> parameters;
    std::vector<Statement> body;
    std::string visibility = "public";
    std::string sourceFile;
    bool isStatic = false;
    bool isConstructor = false;
    bool isOverride = false;
    bool isExternal = false;
    std::string externalName;
    unsigned line = 0;
    unsigned column = 0;
};

struct StructFieldDeclaration {
    std::string name;
    std::string typeName;
    std::vector<std::string> arrayDimensions;
    bool isStatic = false;
    bool hasInitializer = false;
    Expression initializer;
    std::string visibility = "public";
    std::string sourceFile;
    Language sourceLanguage = Language::Zh;
    unsigned line = 0;
    unsigned column = 0;
};

struct StructDeclaration {
    std::string name;
    std::vector<StructFieldDeclaration> fields;
    std::string visibility = "public";
    unsigned line = 0;
    unsigned column = 0;
    // B-P4: the file that declared the structure, so a lowering error
    // about it names that file (like classes and methods already do).
    std::string sourceFile;
};

struct ClassDeclaration {
    std::string name;
    std::string baseName;
    std::vector<StructFieldDeclaration> fields;
    std::vector<MethodDeclaration> methods;
    std::string visibility = "public";
    unsigned line = 0;
    unsigned column = 0;
    std::string sourceFile;
};

struct InterfaceMethodSignature {
    std::string name;
    std::string returnType;
    std::vector<Parameter> parameters;
    unsigned line = 0;
    unsigned column = 0;
};

struct InterfaceClassDeclaration {
    std::string name;
    std::string baseName;
    std::vector<InterfaceMethodSignature> methods;
    std::string visibility = "public";
    unsigned line = 0;
    unsigned column = 0;
    std::string sourceFile;
};

struct ImportDeclaration {
    std::string moduleName;
    std::string alias;
    unsigned line = 0;
    unsigned column = 0;
};

// D-2a (W-1): `布局 名(参数): 视图 { ... }` / `layout name(params) -> View { ... }`.
// The body is a statement list: node rows (expression statements whose
// expression is a NodeRow), `如果`/`变量` and trailing statements.
struct LayoutDeclaration {
    std::string name;
    std::vector<Parameter> parameters;
    std::string returnType;
    std::vector<Statement> body;
    std::string visibility = "public";
    std::string sourceFile;
    unsigned line = 0, column = 0;
};

// D-2a (W-4): `事件 名:事件种() { ... }` / `event Name:kind() { ... }`.
// The header names the node and the event kind; the body is ordinary
// statements (no node rows).
struct EventBlockDeclaration {
    std::string nodeName;
    std::string eventKind;
    std::vector<Statement> body;
    std::string visibility = "public";
    std::string sourceFile;
    unsigned line = 0, column = 0;
};

// P1-3: `类型 别名 = 类型` / `type Alias = Type;` (EBNF `alias`, design
// §2.9) and `导入 "文件.ast"` / `include "file.ast";` (EBNF `include`,
// design §2.10). The alias is resolved by the lowering (registered into
// the backend type-alias table); the file import is resolved textually by
// cnResolvePackageImports, like the legacy `include`.
struct TypeAliasDeclaration {
    std::string name;
    std::string typeName;
    unsigned line = 0;
    unsigned column = 0;
    // B-P4: as StructDeclaration — the file that declared the alias.
    std::string sourceFile;
};

struct FileImportDeclaration {
    std::string path;
    // The file that wrote the import: relative paths resolve against its
    // directory, which matters once several TUs are merged into one program.
    std::string sourceFile;
    unsigned line = 0;
    unsigned column = 0;
};

struct EnumMemberDeclaration {
    std::string name;
    bool hasExpression = false;
    Expression expression;
    unsigned line = 0;
    unsigned column = 0;
};

struct EnumDeclaration {
    std::string name;
    std::vector<EnumMemberDeclaration> members;
    std::string visibility = "public";
    unsigned line = 0;
    unsigned column = 0;
    // B-P4: as StructDeclaration — the file that declared the enum.
    std::string sourceFile;
};

struct Program {
    std::string sourceFile;
    Language language = Language::Zh;
    std::string packageName;
    std::vector<std::string> packageAliases;
    std::vector<ImportDeclaration> imports;
    std::vector<TypeAliasDeclaration> aliases;
    std::vector<FileImportDeclaration> fileImports;
    std::vector<StructDeclaration> structures;
    std::vector<EnumDeclaration> enums;
    std::vector<ClassDeclaration> classes;
    std::vector<InterfaceClassDeclaration> interfaceClasses;
    std::vector<Statement> globals;
    std::vector<MethodDeclaration> methods;
    std::vector<LayoutDeclaration> layouts;
    std::vector<EventBlockDeclaration> events;
};

Program parseProgram(const std::string& source, Language language,
                     const std::string& sourceFile = {});
std::string readPackageName(const std::string& source, Language language);
std::vector<std::string> readPackageNames(const std::string& source, Language language);
std::string dumpAst(const Program& program);

}  // namespace aster_cn
