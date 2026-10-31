#pragma once

#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace maccleaner::json {

// A minimal JSON reader for the output of brew and the iTunes lookup API.
// It only reads; nothing in this project writes JSON.
struct Value {
    enum class Type { Null, Bool, Number, String, Array, Object };
    Type type = Type::Null;
    bool boolean = false;
    double number = 0;
    std::string string;
    std::vector<Value> array;
    std::vector<std::pair<std::string, Value>> object; // insertion order

    // nullptr if this is not an object or has no such key.
    const Value* find(std::string_view key) const;
    // The string at `key`, or "" if absent or not a string.
    std::string str(std::string_view key) const;
};

// nullopt on malformed input, trailing garbage, or nesting deeper than 64.
std::optional<Value> parse(std::string_view text);

} // namespace maccleaner::json
