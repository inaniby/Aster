#include "cn_lexer.hpp"
#include "cn_diagnostics.hpp"

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iterator>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string_view>
#include <utility>

namespace aster_cn {
namespace {

struct Keyword {
    std::string_view spelling;
    std::string_view kind;
    Language language;
};

constexpr Keyword keywords[] = {
#define ASTER_KEYWORD(spelling, kind, language) {spelling, kind, Language::language},
#include "cn_keywords.def"
#undef ASTER_KEYWORD
};

struct CodePoint { uint32_t value; std::size_t width; };

CodePoint decode(const std::string& source, std::size_t at) {
    const auto byte = [&](std::size_t i) { return static_cast<uint8_t>(source[i]); };
    const uint8_t a = byte(at);
    if (a < 0x80) return {a, 1};
    if (a >= 0xc2 && a <= 0xdf) {
        if (at + 1 >= source.size()) throw std::runtime_error("truncated UTF-8 sequence");
        const uint8_t b = byte(at + 1);
        if ((b & 0xc0) != 0x80) throw std::runtime_error("invalid UTF-8 continuation byte");
        return {uint32_t(a & 0x1f) << 6 | uint32_t(b & 0x3f), 2};
    }
    if (a >= 0xe0 && a <= 0xef) {
        if (at + 2 >= source.size()) throw std::runtime_error("truncated UTF-8 sequence");
        const uint8_t b = byte(at + 1), c = byte(at + 2);
        if ((b & 0xc0) != 0x80 || (c & 0xc0) != 0x80 ||
            (a == 0xe0 && b < 0xa0) || (a == 0xed && b >= 0xa0))
            throw std::runtime_error("invalid UTF-8 sequence");
        return {uint32_t(a & 0x0f) << 12 | uint32_t(b & 0x3f) << 6 | uint32_t(c & 0x3f), 3};
    }
    if (a >= 0xf0 && a <= 0xf4) {
        if (at + 3 >= source.size()) throw std::runtime_error("truncated UTF-8 sequence");
        const uint8_t b = byte(at + 1), c = byte(at + 2), d = byte(at + 3);
        if ((b & 0xc0) != 0x80 || (c & 0xc0) != 0x80 || (d & 0xc0) != 0x80 ||
            (a == 0xf0 && b < 0x90) || (a == 0xf4 && b >= 0x90))
            throw std::runtime_error("invalid UTF-8 sequence");
        return {uint32_t(a & 7) << 18 | uint32_t(b & 0x3f) << 12 |
                    uint32_t(c & 0x3f) << 6 | uint32_t(d & 0x3f), 4};
    }
    throw std::runtime_error("invalid UTF-8 leading byte");
}

bool cjk(uint32_t cp) { return cp >= 0x4e00 && cp <= 0x9fff; }
bool asciiStart(uint32_t cp) {
    return (cp >= 'a' && cp <= 'z') || (cp >= 'A' && cp <= 'Z') || cp == '_';
}
bool identifierStart(uint32_t cp) { return asciiStart(cp) || cjk(cp); }
bool identifierContinue(uint32_t cp) {
    return identifierStart(cp) || (cp >= '0' && cp <= '9');
}

void validateUtf8(const std::string& source) {
    for (std::size_t at = 0; at < source.size();) at += decode(source, at).width;
}

std::string directiveLanguage(const std::string& source) {
    std::size_t at = 0;
    const std::size_t limit = std::min<std::size_t>(source.size(), 4096);
    std::string found;
    while (at < limit) {
        while (at < limit && (source[at] == ' ' || source[at] == '\t' || source[at] == '\r' || source[at] == '\n')) ++at;
        if (at >= limit) break;
        if (source.compare(at, 2, "//") == 0) {
            const std::size_t end = source.find('\n', at);
            const std::size_t stop = end == std::string::npos ? source.size() : end;
            const std::string line = source.substr(at, stop - at);
            const std::string prefix = "// aster:language=";
            if (line.compare(0, prefix.size(), prefix) == 0) {
                std::string value = line.substr(prefix.size());
                while (!value.empty() && (value.front() == ' ' || value.front() == '\t')) value.erase(value.begin());
                while (!value.empty() && (value.back() == ' ' || value.back() == '\t' || value.back() == '\r')) value.pop_back();
                if (value != "zh" && value != "en") throw std::runtime_error("language directive must be zh or en");
                if (!found.empty() && found != value) throw std::runtime_error("conflicting language directives");
                found = value;
            }
            at = end == std::string::npos ? limit : end + 1;
        } else if (source.compare(at, 2, "/*") == 0) {
            const std::size_t end = source.find("*/", at + 2);
            if (end == std::string::npos) throw std::runtime_error("unterminated block comment");
            at = end + 2;
        } else break;
    }
    return found;
}

std::string trim(std::string value) {
    std::size_t first = 0;
    while (first < value.size() && (value[first] == ' ' || value[first] == '\t' || value[first] == '\r')) ++first;
    std::size_t last = value.size();
    while (last > first && (value[last - 1] == ' ' || value[last - 1] == '\t' || value[last - 1] == '\r')) --last;
    return value.substr(first, last - first);
}

std::string unquote(std::string value) {
    value = trim(std::move(value));
    if (value.size() >= 2 && ((value.front() == '"' && value.back() == '"') ||
                              (value.front() == '\'' && value.back() == '\'')))
        return value.substr(1, value.size() - 2);
    return value;
}

// B-P1: a [language] key is a per-file entry when it names a source file:
// a path (contains '/') or a bare `*.ast` name, optionally quoted. Any
// other unknown key keeps the "unknown language setting" error.
bool isFileLanguageKey(const std::string& rawKey) {
    const std::string key = unquote(rawKey);
    if (key.find('/') != std::string::npos) return true;
    return key.size() >= 4 && key.substr(key.size() - 4) == ".ast";
}

Language parseLanguageName(const std::string& value, const char* context) {    const std::string name = unquote(value);
    if (name == "zh") return Language::Zh;
    if (name == "en") return Language::En;
    throw std::runtime_error(std::string(context) + " must be zh or en");
}

void parseAllowedLanguages(const std::string& value, ProjectLanguageConfig& config) {
    std::string list = trim(value);
    if (list.size() >= 2 && list.front() == '[' && list.back() == ']')
        list = list.substr(1, list.size() - 2);
    else
        list = unquote(std::move(list));
    config.hasAllowed = true;
    config.zhAllowed = false;
    config.enAllowed = false;
    std::size_t at = 0;
    while (at <= list.size()) {
        const std::size_t comma = list.find(',', at);
        const std::string item = unquote(list.substr(at, comma == std::string::npos ? std::string::npos : comma - at));
        if (item == "zh") config.zhAllowed = true;
        else if (item == "en") config.enAllowed = true;
        else throw std::runtime_error("language allowed entries must be zh or en");
        if (comma == std::string::npos) break;
        at = comma + 1;
    }
    if (!config.zhAllowed && !config.enAllowed)
        throw std::runtime_error("language allowed must contain zh or en");
}

const Keyword* findKeyword(std::string_view spelling, Language language) {
    for (const auto& entry : keywords)
        if (entry.language == language && entry.spelling == spelling) return &entry;
    if (!spelling.empty() && spelling.front() == 'U') {
        std::string normalized(spelling);
        normalized.front() = 'u';
        for (const auto& entry : keywords)
            if (entry.language == language && entry.spelling == normalized &&
                (entry.kind == "U8" || entry.kind == "U16" || entry.kind == "U32" || entry.kind == "U64"))
                return &entry;
    }
    return nullptr;
}

bool asciiWordAt(const std::string& source, std::size_t at, std::string_view word) {
    if (at + word.size() > source.size() || source.compare(at, word.size(), word) != 0) return false;
    const std::size_t end = at + word.size();
    return end == source.size() || !identifierContinue(decode(source, end).value);
}

class Scanner {
public:
    Scanner(const std::string& source, Language language) : source_(source), language_(language) {}

    std::vector<Token> run() {
        validateUtf8(source_);
        while (offset_ < source_.size()) {
            const uint32_t cp = peek().value;
            if (cp == ' ' || cp == '\t' || cp == '\r' || cp == '\f' || cp == '\v') { take(); continue; }
            if (cp == '\n') {
                const Position start = position(); take();
                if (nesting_ == 0) add("Newline", "\\n", start);
                continue;
            }
            if (cp == '/' && peek(1).value == '/') {
                take(); take();
                while (offset_ < source_.size() && peek().value != '\n') take();
                continue;
            }
            if (cp == '/' && peek(1).value == '*') { blockComment(); continue; }
            if (identifierStart(cp)) { identifier(); continue; }
            if (cp >= '0' && cp <= '9') { number(); continue; }
            if (cp == '"') { stringLiteral(); continue; }
            if (cp == '\'') { characterLiteral(); continue; }
            punctuation();
        }
        tokens_.push_back({"End", "", offset_, 0, line_, column_});
        return tokens_;
    }

private:
    struct Position { std::size_t offset; unsigned line; unsigned column; };
    const std::string& source_;
    Language language_;
    std::size_t offset_ = 0;
    unsigned line_ = 1;
    unsigned column_ = 1;
    unsigned nesting_ = 0;
    std::vector<Token> tokens_;

    Position position() const { return {offset_, line_, column_}; }
    CodePoint peek(unsigned ahead = 0) const {
        std::size_t at = offset_;
        CodePoint cp{0, 0};
        for (unsigned i = 0; i <= ahead && at < source_.size(); ++i) {
            cp = decode(source_, at);
            at += cp.width;
        }
        return cp;
    }
    uint32_t take() {
        const CodePoint cp = peek();
        offset_ += cp.width;
        if (cp.value == '\n') { ++line_; column_ = 1; } else ++column_;
        return cp.value;
    }
    void add(std::string kind, std::string text, Position start) {
        tokens_.push_back({std::move(kind), std::move(text), start.offset,
                           offset_ - start.offset, start.line, start.column});
    }
    void blockComment() {
        const Position start = position();
        take(); take();
        bool closed = false;
        while (offset_ < source_.size()) {
            if (peek().value == '*' && peek(1).value == '/') { take(); take(); closed = true; break; }
            if (peek().value == '\n') {
                const Position nl = position(); take();
                if (nesting_ == 0) add("Newline", "\\n", nl);
            } else take();
        }
        if (!closed) throw std::runtime_error("unterminated block comment at " +
            std::to_string(start.line) + ":" + std::to_string(start.column));
    }
    bool phraseTail(std::string_view second, std::size_t& phraseEnd) const {
        std::size_t at = offset_;
        if (at >= source_.size() || (source_[at] != ' ' && source_[at] != '\t')) return false;
        while (at < source_.size() && (source_[at] == ' ' || source_[at] == '\t')) ++at;
        if (!asciiWordAt(source_, at, second)) return false;
        phraseEnd = at + second.size();
        return true;
    }
    void identifier() {
        const Position start = position();
        while (offset_ < source_.size() && identifierContinue(peek().value)) take();
        std::string spelling = source_.substr(start.offset, offset_ - start.offset);
        std::size_t phraseEnd = offset_;
        if (language_ == Language::En && spelling == "else" && phraseTail("if", phraseEnd)) {
            while (offset_ < phraseEnd) take();
            add("ElseIf", "else if", start);
            return;
        }
        if (language_ == Language::En && spelling == "interface" && phraseTail("class", phraseEnd)) {
            while (offset_ < phraseEnd) take();
            add("InterfaceClass", "interface class", start);
            return;
        }
        if (const Keyword* keyword = findKeyword(spelling, language_))
            add(std::string(keyword->kind), std::move(spelling), start);
        else add("Identifier", std::move(spelling), start);
    }
    void number() {
        const Position start = position();
        const std::size_t begin = offset_;
        bool hex = false, binary = false;
        take();
        if (source_[begin] == '0' && offset_ < source_.size() &&
            (peek().value == 'x' || peek().value == 'X' || peek().value == 'b' || peek().value == 'B')) {
            const uint32_t marker = take();
            hex = marker == 'x' || marker == 'X';
            binary = !hex;
            bool sawDigit = false;
            bool separator = false;
            while (offset_ < source_.size()) {
                const char ch = source_[offset_];
                if (ch == '_') {
                    if (!sawDigit || separator)
                        throw std::runtime_error("digit separator '_' must be between digits at " +
                            std::to_string(start.line) + ":" + std::to_string(start.column));
                    take(); separator = true; continue;
                }
                const bool valid = hex ? std::isxdigit(static_cast<unsigned char>(ch)) != 0
                                       : ch == '0' || ch == '1';
                if (!valid) break;
                take(); sawDigit = true; separator = false;
            }
            if (separator || !sawDigit) throw std::runtime_error(std::string(hex ? "hexadecimal" : "binary") +
                " literal has no digits at " + std::to_string(start.line) + ":" + std::to_string(start.column));
        } else {
            bool previousDigit = true;
            while (offset_ < source_.size()) {
                const uint32_t digit = peek().value;
                if (digit >= '0' && digit <= '9') { take(); previousDigit = true; continue; }
                if (digit == '_') {
                    if (!previousDigit || peek(1).value < '0' || peek(1).value > '9')
                        throw std::runtime_error("digit separator '_' must be between digits at " +
                            std::to_string(start.line) + ":" + std::to_string(start.column));
                    take(); previousDigit = false; continue;
                }
                break;
            }
            if (offset_ < source_.size() && peek().value == '.' && peek(1).value >= '0' && peek(1).value <= '9') {
                take();
                bool previousFractionDigit = false;
                while (offset_ < source_.size()) {
                    const uint32_t digit = peek().value;
                    if (digit >= '0' && digit <= '9') { take(); previousFractionDigit = true; continue; }
                    if (digit == '_') {
                        if (!previousFractionDigit || peek(1).value < '0' || peek(1).value > '9')
                            throw std::runtime_error("digit separator '_' must be between digits at " +
                                std::to_string(start.line) + ":" + std::to_string(start.column));
                        take(); previousFractionDigit = false; continue;
                    }
                    break;
                }
            }
            if (offset_ < source_.size() && (peek().value == 'e' || peek().value == 'E')) {
                const Position exp = position(); take();
                if (offset_ < source_.size() && (peek().value == '+' || peek().value == '-')) take();
                const std::size_t digits = offset_;
                while (offset_ < source_.size() && peek().value >= '0' && peek().value <= '9') take();
                if (digits == offset_) throw std::runtime_error("malformed exponent at " +
                    std::to_string(exp.line) + ":" + std::to_string(exp.column));
            }
        }
        if (!hex && !binary) {
            std::string suffix;
            while (offset_ < source_.size() && (peek().value == 'u' || peek().value == 'U' || peek().value == 'l' || peek().value == 'L'))
                suffix.push_back(static_cast<char>(take()));
            std::string lower;
            for (char ch : suffix) lower.push_back(static_cast<char>(std::tolower(static_cast<unsigned char>(ch))));
            const bool floating = source_.substr(start.offset, offset_ - start.offset).find_first_of(".eE") != std::string::npos;
            if (floating && !suffix.empty())
                throw std::runtime_error("floating-point literal cannot have an integer suffix at " +
                    std::to_string(start.line) + ":" + std::to_string(start.column));
            if (!suffix.empty() && lower != "u" && lower != "l" && lower != "ul" && lower != "lu")
                throw std::runtime_error("invalid numeric suffix '" + suffix + "' at " +
                    std::to_string(start.line) + ":" + std::to_string(start.column));
        }
        add("Number", source_.substr(start.offset, offset_ - start.offset), start);
    }
    void stringLiteral() {
        const Position start = position();
        take();
        bool closed = false;
        while (offset_ < source_.size()) {
            const uint32_t cp = peek().value;
            if (cp == '\n' || cp == '\r') throw std::runtime_error("newline in string literal at " +
                std::to_string(start.line) + ":" + std::to_string(start.column));
            if (cp == '"') { take(); closed = true; break; }
            if (cp == '\\') {
                take();
                if (offset_ >= source_.size()) break;
                const uint32_t escape = take();
                if (escape == 'x') {
                    for (int i = 0; i < 2; ++i) {
                        if (offset_ >= source_.size() || !std::isxdigit(static_cast<unsigned char>(source_[offset_])))
                            throw std::runtime_error("invalid \\x escape at " +
                                std::to_string(start.line) + ":" + std::to_string(start.column));
                        take();
                    }
                } else if (escape != 'n' && escape != 'r' && escape != 't' && escape != '0' &&
                           escape != '\\' && escape != '"' && escape != '\'' && escape != 'a' &&
                           escape != 'b' && escape != 'f' && escape != 'v') {
                    throw std::runtime_error("unsupported string escape at " +
                        std::to_string(start.line) + ":" + std::to_string(start.column));
                }
            } else take();
        }
        if (!closed) throw std::runtime_error("unterminated string literal at " +
            std::to_string(start.line) + ":" + std::to_string(start.column));
        add("String", source_.substr(start.offset, offset_ - start.offset), start);
    }
    void characterLiteral() {
        const Position start = position();
        take();
        if (offset_ >= source_.size() || peek().value == '\n' || peek().value == '\r' || peek().value == '\'')
            throw std::runtime_error("empty or unterminated character literal at " +
                std::to_string(start.line) + ":" + std::to_string(start.column));
        if (peek().value == '\\') {
            take();
            if (offset_ >= source_.size()) throw std::runtime_error("unterminated character literal");
            const uint32_t escape = take();
            if (escape == 'x') {
                for (int i = 0; i < 2; ++i) {
                    if (offset_ >= source_.size() || !std::isxdigit(static_cast<unsigned char>(source_[offset_])))
                        throw std::runtime_error("invalid \\x escape at " +
                            std::to_string(start.line) + ":" + std::to_string(start.column));
                    take();
                }
            } else if (escape != 'n' && escape != 'r' && escape != 't' && escape != '0' &&
                       escape != '\\' && escape != '"' && escape != '\'' && escape != 'a' &&
                       escape != 'b' && escape != 'f' && escape != 'v') {
                throw std::runtime_error("unsupported character escape at " +
                    std::to_string(start.line) + ":" + std::to_string(start.column));
            }
        } else {
            if (peek().width != 1) throw std::runtime_error("character literal must contain one byte at " +
                std::to_string(start.line) + ":" + std::to_string(start.column));
            take();
        }
        if (offset_ >= source_.size() || peek().value != '\'')
            throw std::runtime_error("character literal must contain one byte at " +
                std::to_string(start.line) + ":" + std::to_string(start.column));
        take();
        add("Character", source_.substr(start.offset, offset_ - start.offset), start);
    }
    void punctuation() {
        const Position start = position();
        const uint32_t original = peek().value;
        uint32_t cp = original;
        if (cp == 0xff0c || cp == 0x3001) cp = ',';
        else if (cp == 0xff1a) cp = ':';
        if (cp > 0x7f) {
            std::ostringstream message;
            message << "unsupported source code point U+" << std::uppercase << std::hex << cp
                    << " at " << std::dec << line_ << ':' << column_;
            throw std::runtime_error(message.str());
        }
        const char ch = static_cast<char>(cp);
        struct Multi { const char* spelling; const char* kind; };
        static const Multi multi[] = {
            {"<<=", "ShlEq"}, {">>=", "ShrEq"}, {"+=", "PlusEq"}, {"-=", "MinusEq"},
            {"*=", "StarEq"}, {"/=", "SlashEq"}, {"%=", "PercentEq"}, {"&=", "AndEq"},
            {"|=", "OrEq"}, {"^=", "XorEq"}, {"++", "PlusPlus"}, {"--", "MinusMinus"},
            {"->", "Arrow"}, {"==", "EqEq"}, {"!=", "Ne"}, {"<=", "Le"}, {">=", "Ge"},
            {"<<", "Shl"}, {">>", "Shr"}, {"&&", "And"}, {"||", "Or"}
        };
        if (original < 0x80) for (const auto& op : multi) {
            const std::string_view spelling(op.spelling);
            if (source_.compare(offset_, spelling.size(), spelling) == 0) {
                for (std::size_t i = 0; i < spelling.size(); ++i) take();
                add(op.kind, std::string(spelling), start);
                return;
            }
        }
        const char* kind = nullptr;
        switch (ch) {
            case '(': kind = "LParen"; ++nesting_; break;
            case ')': kind = "RParen"; if (nesting_) --nesting_; break;
            case '[': kind = "LBracket"; ++nesting_; break;
            case ']': kind = "RBracket"; if (nesting_) --nesting_; break;
            case '{': kind = "LBrace"; break;
            case '}': kind = "RBrace"; break;
            case ':': kind = "Colon"; break;
            case ';': kind = "Semi"; break;
            case ',': kind = "Comma"; break;
            case '=': kind = "Eq"; break;
            case '<': kind = "Lt"; break;
            case '>': kind = "Gt"; break;
            case '+': kind = "Plus"; break;
            case '-': kind = "Minus"; break;
            case '*': kind = "Star"; break;
            case '/': kind = "Slash"; break;
            case '%': kind = "Percent"; break;
            case '&': kind = "Amp"; break;
            case '|': kind = "BitOr"; break;
            case '^': kind = "BitXor"; break;
            case '~': kind = "Tilde"; break;
            case '!': kind = "Not"; break;
            case '?': kind = "Question"; break;
            case '.': kind = "Dot"; break;
            case '@': kind = "At"; break;
            default: throw std::runtime_error("unexpected character at " +
                std::to_string(line_) + ":" + std::to_string(column_));
        }
        take();
        add(kind, std::string(1, ch), start);
    }
};

}  // namespace

ProjectLanguageConfig readProjectLanguage(const std::string& path) {
    std::ifstream input(path, std::ios::binary);
    if (!input) throw std::runtime_error("cannot open project file: " + path);
    const std::string contents(std::istreambuf_iterator<char>(input), {});
    ProjectLanguageConfig config;
    // B-P1: per-file entries are relative to the project file's directory,
    // like the source paths in aster.proj.
    std::string projectDir;
    try {
        projectDir = std::filesystem::path(path).parent_path().string();
    } catch (const std::exception&) {
        projectDir.clear();
    }
    bool inLanguage = false;
    std::size_t line = 1;
    std::string current;
    auto consume = [&](const std::string& raw) {
        const std::string item = trim(raw);
        if (item.empty() || item.front() == '#') return;
        if (item.front() == '[' && item.back() == ']') {
            inLanguage = trim(item.substr(1, item.size() - 2)) == "language";
            return;
        }
        if (!inLanguage) return;
        const std::size_t equal = item.find('=');
        if (equal == std::string::npos) {
            // Project source entries may follow the optional language section.
            // A path-like line starts the project source list again; malformed
            // entries inside the section still receive the configuration error.
            if (item.find('/') != std::string::npos ||
                (item.size() >= 4 && item.substr(item.size() - 4) == ".ast")) {
                inLanguage = false;
                return;
            }
            const std::size_t space = item.find_first_of(" \t");
            const std::string key = space == std::string::npos
                ? item : item.substr(0, space);
            if (key == "kind" || key == "name" || key == "package" ||
                key == "abi" || key == "label" || key == "test" ||
                key == "min-sdk" || key == "target-sdk" || key == "page-size" ||
                key == "sign-mode" || key == "keystore" || key == "cert" ||
                key == "key-bits") {
                inLanguage = false;
                return;
            }
            throw std::runtime_error(path + ": language setting on line " + std::to_string(line) + " needs '='");
        }
        const std::string key = trim(item.substr(0, equal));
        const std::string value = trim(item.substr(equal + 1));
        if (key == "default") {
            if (config.hasDefault) throw std::runtime_error(path + ": duplicate language default");
            config.defaultLanguage = parseLanguageName(value, "language default");
            config.hasDefault = true;
        } else if (key == "allowed") {
            if (config.hasAllowed) throw std::runtime_error(path + ": duplicate language allowed setting");
            try {
                parseAllowedLanguages(value, config);
            } catch (const std::exception& error) {
                throw std::runtime_error(path + ": " + error.what());
            }
        } else if (isFileLanguageKey(key)) {
            // B-P1: per-file entry, `"path/to/file.ast" = "en"` (the key
            // may be quoted). A key that is neither `default` nor
            // `allowed` nor path-like still falls through to the unknown
            // setting error below, so a typo cannot silently become a
            // per-file entry.
            const std::string keyPath = unquote(key);
            const Language entryLanguage = parseLanguageName(value, "language entry");
            const std::string joined =
                projectDir.empty() ? keyPath : projectDir + "/" + keyPath;
            if (!config.fileLanguages.emplace(absoluteLexicalPath(joined), entryLanguage).second)
                throw std::runtime_error(path + ": duplicate language entry for file '" + keyPath + "'");
        } else {
            throw std::runtime_error(path + ": unknown language setting '" + key + "'");
        }
    };
    for (char ch : contents) {
        if (ch == '\n') { consume(current); current.clear(); ++line; }
        else current.push_back(ch);
    }
    consume(current);
    return config;
}

Language selectLanguage(const std::string& source, bool hasOverride, Language overrideLanguage,
                        const ProjectLanguageConfig& project,
                        const std::string& sourcePath,
                        bool hasImporterLanguage, Language importerLanguage) {
    const std::string directive = directiveLanguage(source);
    Language selected = project.hasDefault ? project.defaultLanguage : Language::Zh;
    if (hasOverride) {
        if (!directive.empty() && directive != languageName(overrideLanguage))
            throw std::runtime_error(std::string("language override '") + languageName(overrideLanguage) +
                                    "' conflicts with file directive '" + directive + "'");
        selected = overrideLanguage;
    } else if (!directive.empty()) {
        selected = directive == "en" ? Language::En : Language::Zh;
    } else if (!sourcePath.empty()) {
        // B-P1: an explicit per-file entry wins over inheritance; an
        // imported file with no entry inherits its importer's language,
        // which itself beats the project default below.
        const auto found = project.fileLanguages.find(absoluteLexicalPath(sourcePath));
        if (found != project.fileLanguages.end()) selected = found->second;
        else if (hasImporterLanguage) selected = importerLanguage;
    } else if (hasImporterLanguage) {
        selected = importerLanguage;
    }
    if (project.hasAllowed && ((selected == Language::Zh && !project.zhAllowed) ||
                              (selected == Language::En && !project.enAllowed)))
        throw std::runtime_error(std::string("selected language '") + languageName(selected) +
                                 "' is not allowed by project configuration");
    return selected;
}

const char* languageName(Language language) { return language == Language::Zh ? "zh" : "en"; }

std::string absoluteLexicalPath(const std::string& path) {
    try {
        return std::filesystem::absolute(std::filesystem::path(path)).lexically_normal().string();
    } catch (const std::exception&) {
        return path;
    }
}

std::string projectLanguageFileEntries(const ProjectLanguageConfig& project) {
    std::string out;
    for (const auto& entry : project.fileLanguages) {
        out += ";file=";
        out += entry.first;
        out += '=';
        out += languageName(entry.second);
    }
    return out;
}

std::vector<Token> lex(const std::string& source, Language language) {
    try {
        return Scanner(source, language).run();
    } catch (const std::exception& error) {
        throw std::runtime_error(decorateDiagnostic(error.what(), language));
    }
}

}  // namespace aster_cn
