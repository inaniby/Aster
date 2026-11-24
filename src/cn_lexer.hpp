#pragma once

#include <cstddef>
#include <map>
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
    // B-P1: per-file entries from the [language] section,
    // `"path/to/file.ast" = "en"`. Keys are absolute, lexically normalised
    // paths (resolved against the aster.proj directory when read), so a
    // file listed here keeps its own language in a mixed-language project
    // without a directive inside the file itself.
    std::map<std::string, Language> fileLanguages;
};

struct Token {
    std::string kind;
    std::string text;
    std::size_t byteOffset = 0;
    std::size_t byteLength = 0;
    unsigned line = 1;
    unsigned column = 1;
};

// Absolute, lexically normalised spelling of a path (no symlink or
// existence checks), so a per-file entry and a source path spelled
// differently compare equal. Falls back to the input on error.
std::string absoluteLexicalPath(const std::string& path);
// Deterministic serialisation of the per-file entries, for cache keys:
// `;file=<absolute path>=<zh|en>` per entry, in path order.
std::string projectLanguageFileEntries(const ProjectLanguageConfig& project);

// Language resolution for one source file (design §2/§3.1, B-P1):
//   CLI override > file directive > per-file [language] entry (sourcePath)
//   > importer language (hasImporterLanguage: include/导入 file imports
//   only — a package file is its own TU and never inherits, since one
//   module's files may be zh and en at once)
//   > project [language] default > built-in default zh.
// The override conflicts with a file directive (error, as before); the
// `allowed` check applies to the final selection. Nothing is guessed from
// the file's contents: every step above is an explicit configuration.
Language selectLanguage(const std::string& source, bool hasOverride,
                        Language overrideLanguage,
                        const ProjectLanguageConfig& project = {},
                        const std::string& sourcePath = {},
                        bool hasImporterLanguage = false,
                        Language importerLanguage = Language::Zh);
ProjectLanguageConfig readProjectLanguage(const std::string& path);
const char* languageName(Language language);
std::vector<Token> lex(const std::string& source, Language language);

}  // namespace aster_cn
