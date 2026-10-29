// Non-Apple fallback for the File Organizer, so the core and its tests
// build on Linux/CI. macOS uses organizer_mac.mm.

#include "maccleaner/organizer.hpp"

namespace maccleaner::organizer {

bool moveFile(const std::filesystem::path& from, const std::filesystem::path& to, std::string* error) {
    std::error_code ec;
    // shortcut: exists-then-rename can race and replace a new file; use renameat2(RENAME_NOREPLACE) if this ships on Linux.
    if (std::filesystem::exists(to, ec)) {
        if (error != nullptr) {
            *error = "target already exists: " + to.string();
        }
        return false;
    }
    std::filesystem::create_directories(to.parent_path(), ec);
    if (!ec) {
        std::filesystem::rename(from, to, ec);
    }
    if (ec && error != nullptr) {
        *error = ec.message();
    }
    return !ec;
}

void readMetadata(FileMeta&) {}

} // namespace maccleaner::organizer
