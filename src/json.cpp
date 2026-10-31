#include "maccleaner/json.hpp"

#include <cctype>
#include <cstdlib>

namespace maccleaner::json {

const Value* Value::find(std::string_view key) const {
    if (type != Type::Object) {
        return nullptr;
    }
    for (const auto& [k, v] : object) {
        if (k == key) {
            return &v;
        }
    }
    return nullptr;
}

std::string Value::str(std::string_view key) const {
    const Value* v = find(key);
    return (v && v->type == Type::String) ? v->string : std::string();
}

namespace {

// Hostile or broken input must not overflow the stack.
constexpr int kMaxDepth = 64;

class Parser {
public:
    explicit Parser(std::string_view text) : s_(text) {}

    std::optional<Value> parseDocument(bool allowTrailing) {
        Value v;
        if (!parseValue(v, 0)) {
            return std::nullopt;
        }
        skipSpace();
        if (!allowTrailing && pos_ != s_.size()) {
            return std::nullopt;
        }
        return v;
    }

private:
    std::string_view s_;
    std::size_t pos_ = 0;

    void skipSpace() {
        while (pos_ < s_.size() && (s_[pos_] == ' ' || s_[pos_] == '\t' || s_[pos_] == '\n' || s_[pos_] == '\r')) {
            ++pos_;
        }
    }

    bool consume(char c) {
        skipSpace();
        if (pos_ < s_.size() && s_[pos_] == c) {
            ++pos_;
            return true;
        }
        return false;
    }

    bool literal(std::string_view word) {
        if (s_.substr(pos_, word.size()) != word) {
            return false;
        }
        pos_ += word.size();
        return true;
    }

    bool parseValue(Value& out, int depth) {
        if (depth > kMaxDepth) {
            return false;
        }
        skipSpace();
        if (pos_ >= s_.size()) {
            return false;
        }
        const char c = s_[pos_];
        if (c == '{') {
            return parseObject(out, depth);
        }
        if (c == '[') {
            return parseArray(out, depth);
        }
        if (c == '"') {
            out.type = Value::Type::String;
            return parseString(out.string);
        }
        if (literal("true")) {
            out.type = Value::Type::Bool;
            out.boolean = true;
            return true;
        }
        if (literal("false")) {
            out.type = Value::Type::Bool;
            return true;
        }
        if (literal("null")) {
            return true;
        }
        return parseNumber(out);
    }

    bool parseObject(Value& out, int depth) {
        out.type = Value::Type::Object;
        ++pos_; // '{'
        if (consume('}')) {
            return true;
        }
        do {
            skipSpace();
            std::string key;
            if (pos_ >= s_.size() || s_[pos_] != '"' || !parseString(key) || !consume(':')) {
                return false;
            }
            Value v;
            if (!parseValue(v, depth + 1)) {
                return false;
            }
            out.object.emplace_back(std::move(key), std::move(v));
        } while (consume(','));
        return consume('}');
    }

    bool parseArray(Value& out, int depth) {
        out.type = Value::Type::Array;
        ++pos_; // '['
        if (consume(']')) {
            return true;
        }
        do {
            Value v;
            if (!parseValue(v, depth + 1)) {
                return false;
            }
            out.array.push_back(std::move(v));
        } while (consume(','));
        return consume(']');
    }

    bool parseNumber(Value& out) {
        const std::size_t start = pos_;
        while (pos_ < s_.size() && (std::isdigit(static_cast<unsigned char>(s_[pos_])) || s_[pos_] == '-' ||
                                    s_[pos_] == '+' || s_[pos_] == '.' || s_[pos_] == 'e' || s_[pos_] == 'E')) {
            ++pos_;
        }
        if (pos_ == start) {
            return false;
        }
        const std::string text(s_.substr(start, pos_ - start));
        char* end = nullptr;
        out.type = Value::Type::Number;
        out.number = std::strtod(text.c_str(), &end);
        return end == text.c_str() + text.size();
    }

    bool parseHex4(unsigned& code) {
        if (pos_ + 4 > s_.size()) {
            return false;
        }
        code = 0;
        for (int i = 0; i < 4; ++i) {
            const char h = s_[pos_++];
            code <<= 4;
            if (h >= '0' && h <= '9') code |= unsigned(h - '0');
            else if (h >= 'a' && h <= 'f') code |= unsigned(h - 'a' + 10);
            else if (h >= 'A' && h <= 'F') code |= unsigned(h - 'A' + 10);
            else return false;
        }
        return true;
    }

    static void appendUtf8(std::string& out, unsigned cp) {
        if (cp < 0x80) {
            out += char(cp);
        } else if (cp < 0x800) {
            out += char(0xC0 | (cp >> 6));
            out += char(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000) {
            out += char(0xE0 | (cp >> 12));
            out += char(0x80 | ((cp >> 6) & 0x3F));
            out += char(0x80 | (cp & 0x3F));
        } else {
            out += char(0xF0 | (cp >> 18));
            out += char(0x80 | ((cp >> 12) & 0x3F));
            out += char(0x80 | ((cp >> 6) & 0x3F));
            out += char(0x80 | (cp & 0x3F));
        }
    }

    bool parseString(std::string& out) {
        ++pos_; // opening quote
        while (pos_ < s_.size()) {
            const char c = s_[pos_++];
            if (c == '"') {
                return true;
            }
            if (c != '\\') {
                out += c;
                continue;
            }
            if (pos_ >= s_.size()) {
                return false;
            }
            switch (s_[pos_++]) {
                case '"': out += '"'; break;
                case '\\': out += '\\'; break;
                case '/': out += '/'; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case 'n': out += '\n'; break;
                case 'r': out += '\r'; break;
                case 't': out += '\t'; break;
                case 'u': {
                    unsigned cp = 0;
                    if (!parseHex4(cp)) {
                        return false;
                    }
                    if (cp >= 0xD800 && cp <= 0xDBFF) {
                        unsigned low = 0;
                        if (!literal("\\u") || !parseHex4(low) || low < 0xDC00 || low > 0xDFFF) {
                            return false;
                        }
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                    }
                    appendUtf8(out, cp);
                    break;
                }
                default: return false;
            }
        }
        return false; // unterminated
    }
};

} // namespace

std::optional<Value> parse(std::string_view text) {
    return Parser(text).parseDocument(false);
}

std::optional<Value> parsePrefix(std::string_view text) {
    return Parser(text).parseDocument(true);
}

} // namespace maccleaner::json
