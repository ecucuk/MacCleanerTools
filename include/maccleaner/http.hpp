#pragma once

#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace maccleaner::http {

struct Response {
    int status = 0;
    std::string body;
};

// GET with the given headers. nullopt on a transport error or timeout (no
// HTTP status at all). Blocks the calling thread; never call it on main.
std::optional<Response> get(const std::string& url,
                            const std::vector<std::pair<std::string, std::string>>& headers,
                            double timeoutSeconds);

} // namespace maccleaner::http
