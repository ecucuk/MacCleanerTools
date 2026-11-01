#include "maccleaner/http.hpp"

namespace maccleaner::http {

// No HTTP client off macOS; callers treat this like a network error.
std::optional<Response> get(const std::string&, const std::vector<std::pair<std::string, std::string>>&, double) {
    return std::nullopt;
}

} // namespace maccleaner::http
