#pragma once

#include "cn_lexer.hpp"

#include <memory>
#include <string>
#include <vector>

namespace aster_cn {

struct ClosureDeclaration;

struct Expression {
    std::string kind;
    std::string value;
    std::vector<Expression> children;
    std::shared_ptr<ClosureDeclaration> closure;
    unsigned line = 0;
    unsigned column = 0;
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
};

Program parseProgram(const std::string& source, Language language,
                     const std::string& sourceFile = {});
std::string readPackageName(const std::string& source, Language language);
std::vector<std::string> readPackageNames(const std::string& source, Language language);
std::string dumpAst(const Program& program);

}  // namespace aster_cn
