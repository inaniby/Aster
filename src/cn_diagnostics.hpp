#pragma once

#include "cn_lexer.hpp"

#include <cstddef>
#include <string>
#include <string_view>

namespace aster_cn {

// The bilingual front end keeps the historical detail in an error message so
// existing command-line users and tests remain useful.  A stable code and a
// short language-specific summary are added in front of that detail.  Tools
// can parse the `[A-NNN]` prefix without having to parse prose.
struct DiagnosticInfo {
    const char* code;
    const char* zh;
    const char* en;
};

inline bool diagnosticDecorated(std::string_view message) {
    // P1-1: classifyDiagnostic() only ever emits three-digit codes
    // ([A-NNN]), so the old check for a two-digit code (message[5] == ']')
    // was false for every real diagnostic and the same error was decorated
    // once per layer (lex() -> parseProgram()/readPackageName(s) -> main's
    // catch), nesting [A-001]/[A-011] two or three deep. Accept both the
    // three-digit form and the legacy two-digit form so decoration is
    // idempotent at every layer.
    if (message.size() >= 6 && message[0] == '[' && message[1] == 'A' &&
        message[2] == '-' && message[3] >= '0' && message[3] <= '9' &&
        message[4] >= '0' && message[4] <= '9' && message[5] == ']')
        return true;
    return message.size() >= 7 && message[0] == '[' && message[1] == 'A' &&
        message[2] == '-' && message[3] >= '0' && message[3] <= '9' &&
        message[4] >= '0' && message[4] <= '9' &&
        message[5] >= '0' && message[5] <= '9' && message[6] == ']';
}

inline DiagnosticInfo classifyDiagnostic(std::string_view message) {
    const auto has = [&](std::string_view needle) {
        return message.find(needle) != std::string_view::npos;
    };
    if (has("UTF-8") || has("utf-8"))
        return {"A-001", "UTF-8 编码无效", "invalid UTF-8 encoding"};
    if (has("unsupported source code point") || has("unexpected character"))
        return {"A-002", "源文件包含不支持的字符", "source contains an unsupported character"};
    if (has("language directive") || has("language override") ||
        has("language default") || has("language allowed") ||
        has("selected language"))
        return {"A-003", "语言模式配置无效", "invalid language-mode configuration"};
    if (has("mismatched block close") || has("unexpected end of file inside") ||
        has("expected '结束'") || has("expected '}'") ||
        has("expected a newline before the block body"))
        return {"A-010", "代码块结构不匹配", "block structure does not match"};
    if (has("package") || has("import") || has("module"))
        return {"A-020", "包或模块声明无效", "invalid package or module declaration"};
    if (has("annotation") || has("@"))
        return {"A-021", "注解使用无效", "invalid annotation usage"};
    if (has("duplicate") || has("重复"))
        return {"A-030", "声明重复", "duplicate declaration"};
    if (has("not public") || has("hidden") || has("restricted") ||
        has("不可见") || has("受限"))
        return {"A-040", "成员或类型的访问权限不足", "member or type is not accessible"};
    if (has("type mismatch") || (has("expected ") && has("got ")) ||
        has("must be an ") || has("must be ") || has("cannot assign"))
        return {"A-050", "类型检查失败", "type checking failed"};
    if (has("expected ") || has("expected a ") || has("expected an "))
        return {"A-011", "语法不符合当前位置的要求", "syntax is not valid at this position"};
    if (has("not implemented") || has("not supported") || has("尚未实现") ||
        has("不支持"))
        return {"A-060", "当前语言子集尚未支持此写法", "this construct is not supported yet"};
    return {"A-099", "双语前端报告了编译错误", "the bilingual front end reported a compilation error"};
}

inline std::string diagnosticLocationSuffix(std::string_view message,
                                            std::string& body) {
    const std::size_t at = message.rfind(" at ");
    if (at == std::string_view::npos) {
        body.assign(message);
        return {};
    }
    const std::string_view suffix = message.substr(at + 4);
    bool valid = !suffix.empty();
    bool colon = false;
    for (char ch : suffix) {
        if (ch == ':' && !colon) { colon = true; continue; }
        if (ch < '0' || ch > '9') { valid = false; break; }
    }
    if (!valid || !colon) {
        body.assign(message);
        return {};
    }
    body.assign(message.substr(0, at));
    return std::string(message.substr(at));
}

inline std::string decorateDiagnostic(const std::string& message, Language language) {
    if (diagnosticDecorated(message)) return message;
    const DiagnosticInfo info = classifyDiagnostic(message);
    std::string body;
    const std::string location = diagnosticLocationSuffix(message, body);
    std::string result = "[";
    result += info.code;
    result += "] ";
    result += language == Language::Zh ? info.zh : info.en;
    if (!body.empty()) {
        result += " (";
        result += body;
        result += ')';
    }
    result += location;
    return result;
}

}  // namespace aster_cn
