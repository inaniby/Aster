#include "cn_formatter.hpp"

#include <algorithm>
#include <string>
#include <vector>

namespace aster_cn {
namespace {

struct BlockFrame {
    std::string kind;
    bool caseBody = false;
};

std::string trimLine(const std::string& line) {
    std::size_t first = 0;
    while (first < line.size() && (line[first] == ' ' || line[first] == '\t' || line[first] == '\r'))
        ++first;
    std::size_t last = line.size();
    while (last > first && (line[last - 1] == ' ' || line[last - 1] == '\t' || line[last - 1] == '\r'))
        --last;
    return line.substr(first, last - first);
}

bool isChineseBlock(const std::string& kind) {
    return kind == "Method" || kind == "If" || kind == "WhileLoop" ||
        kind == "CountLoop" || kind == "ForEachLoop" || kind == "EnumLoop" ||
        kind == "Match" || kind == "StructKw" || kind == "EnumKw" ||
        kind == "Class" || kind == "InterfaceClass";
}

void appendIndent(std::string& output, std::size_t depth) {
    constexpr std::size_t maxDepth = 256;
    output.append(std::min(depth, maxDepth) * 4u, ' ');
}

}  // namespace

std::string formatSource(const std::string& source, Language language) {
    if (source.empty()) return {};
    const std::vector<Token> tokens = lex(source, language);
    std::vector<std::vector<std::string>> lineTokens(1);
    unsigned currentLine = 1;
    for (const auto& token : tokens) {
        if (token.line > lineTokens.size()) lineTokens.resize(token.line);
        if (token.kind != "Newline" && token.kind != "End")
            lineTokens[token.line - 1].push_back(token.kind);
        currentLine = std::max(currentLine, token.line);
    }
    lineTokens.resize(std::max<std::size_t>(lineTokens.size(), currentLine));

    std::string output;
    output.reserve(source.size() + source.size() / 8);
    std::vector<BlockFrame> blocks;
    std::size_t depth = 0;
    std::size_t lineNumber = 0;
    std::size_t offset = 0;
    while (offset < source.size()) {
        const std::size_t newline = source.find('\n', offset);
        const std::size_t end = newline == std::string::npos ? source.size() : newline;
        const std::string content = trimLine(source.substr(offset, end - offset));
        if (!content.empty()) {
            const auto& kinds = lineTokens[lineNumber];
            std::size_t indentDepth = depth;
            if (language == Language::Zh) {
                const std::string first = kinds.empty() ? std::string() : kinds.front();
                if (first == "EndKw") {
                    if (!blocks.empty() && blocks.back().kind == "Match" && blocks.back().caseBody) {
                        if (depth > 0) --depth;
                        blocks.back().caseBody = false;
                    }
                    if (!blocks.empty()) {
                        if (depth > 0) --depth;
                        blocks.pop_back();
                    }
                    indentDepth = depth;
                } else if (first == "ElseIf") {
                    if (!blocks.empty() && blocks.back().kind == "If") {
                        if (depth > 0) --depth;
                        indentDepth = depth;
                        ++depth;
                    }
                } else if (first == "Else" || first == "CaseArm") {
                    if (!blocks.empty() && blocks.back().kind == "Match") {
                        if (blocks.back().caseBody && depth > 0) --depth;
                        indentDepth = depth;
                        ++depth;
                        blocks.back().caseBody = true;
                    } else if (first == "Else" && !blocks.empty() && blocks.back().kind == "If") {
                        if (depth > 0) --depth;
                        indentDepth = depth;
                        ++depth;
                    }
                } else {
                    indentDepth = depth;
                    if (!first.empty() && isChineseBlock(first) &&
                        !(first == "Method" && !blocks.empty() && blocks.back().kind == "InterfaceClass")) {
                        blocks.push_back({first, false});
                        ++depth;
                    }
                }
            } else {
                const auto& kinds = lineTokens[lineNumber];
                std::size_t opens = 0;
                std::size_t closes = 0;
                for (const auto& kind : kinds) {
                    if (kind == "LBrace") ++opens;
                    else if (kind == "RBrace") ++closes;
                }
                std::size_t leadingCloses = 0;
                while (leadingCloses < kinds.size() && kinds[leadingCloses] == "RBrace")
                    ++leadingCloses;
                indentDepth = depth > leadingCloses ? depth - leadingCloses : 0;
                depth = depth + opens > closes ? depth + opens - closes : 0;
            }
            appendIndent(output, indentDepth);
            output += content;
        }
        output.push_back('\n');
        ++lineNumber;
        if (newline == std::string::npos) break;
        offset = newline + 1;
    }
    return output;
}

}  // namespace aster_cn
