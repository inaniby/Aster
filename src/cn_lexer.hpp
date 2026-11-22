#pragma once

#include <cstddef>
#include <string>
#include <vector>

namespace aster_cn {

enum class Language { Zh, En };

struct ProjectLanguageConfig {
    bool hasDefault = false;
    Language defaultLanguage = Language::Zh;
    bool hasAllowed = false;
    bool zhAllowed = true;
    bool enAllowed = true;
};

struct Token {
    std::string kind;
    std::string text;
    std::size_t byteOffset = 0;
    std::size_t byteLength = 0;
    unsigned line = 1;
    unsigned column = 1;
};

Language selectLanguage(const std::string& source, bool hasOverride,
                        Language overrideLanguage,
                        const ProjectLanguageConfig& project = {});
ProjectLanguageConfig readProjectLanguage(const std::string& path);
const char* languageName(Language language);
std::vector<Token> lex(const std::string& source, Language language);

}  // namespace aster_cn
