#include "maccleaner/updater.hpp"

#include <cstdlib>
#include <filesystem>
#include <unistd.h>

namespace maccleaner::updater {

// Off macOS there are no app bundles to read; only the package managers work.
Environment defaultEnvironment() {
    Environment env;
    if (::access("/usr/local/bin/brew", X_OK) == 0) {
        env.brewPath = "/usr/local/bin/brew";
    }
    env.readBundle = [](const std::string&) { return std::optional<BundleInfo>(); };
    env.exists = [](const std::string& path) {
        std::error_code ec;
        return std::filesystem::exists(path, ec);
    };
    return env;
}

} // namespace maccleaner::updater
