#include "cn_lexer.hpp"
#include "cn_diagnostics.hpp"

#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>

namespace {

std::string readSource(const std::string& path) {
    if (path == "-") return std::string(std::istreambuf_iterator<char>(std::cin), {});
    std::ifstream input(path, std::ios::binary);
    if (!input) throw std::runtime_error("cannot open source file: " + path);
    return std::string(std::istreambuf_iterator<char>(input), {});
}

void usage() {
    std::cerr << "Usage: aster-cn-lex [--language zh|en] [--project aster.proj] <source-file|->\n";
}

}  // namespace

int main(int argc, char** argv) {
    bool hasOverride = false;
    aster_cn::Language overrideLanguage = aster_cn::Language::Zh;
    aster_cn::ProjectLanguageConfig project;
    try {
        std::string projectPath;
        std::string inputPath;
        for (int i = 1; i < argc; ++i) {
            const std::string arg = argv[i];
            if (arg == "--help" || arg == "-h") { usage(); return 0; }
            if (arg == "--language") {
                if (++i >= argc) throw std::runtime_error("--language needs zh or en");
                const std::string value = argv[i];
                if (value != "zh" && value != "en") throw std::runtime_error("--language must be zh or en");
                hasOverride = true;
                overrideLanguage = value == "zh" ? aster_cn::Language::Zh : aster_cn::Language::En;
            } else if (arg == "--project") {
                if (++i >= argc) throw std::runtime_error("--project needs a path");
                projectPath = argv[i];
            } else if (arg.rfind("--project=", 0) == 0) {
                projectPath = arg.substr(10);
                if (projectPath.empty()) throw std::runtime_error("--project needs a path");
            } else if (arg.rfind("--language=", 0) == 0) {
                const std::string value = arg.substr(11);
                if (value != "zh" && value != "en") throw std::runtime_error("--language must be zh or en");
                hasOverride = true;
                overrideLanguage = value == "zh" ? aster_cn::Language::Zh : aster_cn::Language::En;
            } else if (!arg.empty() && arg[0] == '-') {
                if (arg != "-") throw std::runtime_error("unknown option: " + arg);
                if (!inputPath.empty()) throw std::runtime_error("provide only one source file");
                inputPath = arg;
            } else if (inputPath.empty()) inputPath = arg;
            else throw std::runtime_error("provide only one source file");
        }

        const std::string source = readSource(inputPath.empty() ? "-" : inputPath);
        if (!projectPath.empty()) project = aster_cn::readProjectLanguage(projectPath);
        const aster_cn::Language language = aster_cn::selectLanguage(source, hasOverride, overrideLanguage, project, inputPath);
        const auto tokens = aster_cn::lex(source, language);
        for (const auto& token : tokens) {
            std::cout << token.line << ':' << token.column << " byte=" << token.byteOffset
                      << '+' << token.byteLength << ' ' << token.kind << ' '
                      << std::quoted(token.text) << '\n';
        }
        return 0;
    } catch (const std::exception& error) {
        const aster_cn::Language diagnosticLanguage =
            hasOverride ? overrideLanguage :
            (project.hasDefault ? project.defaultLanguage : aster_cn::Language::Zh);
        std::cerr << "aster-cn-lex: error: "
                  << aster_cn::decorateDiagnostic(error.what(), diagnosticLanguage) << '\n';
        return 1;
    }
}
