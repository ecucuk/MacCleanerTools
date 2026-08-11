// Non-Apple / MACCLEANER_USE_NATIVE_TRASH=OFF fallback. There is no portable
// "move to trash" primitive outside platform APIs, so this permanently
// removes the path. It exists so the core library and its tests can build
// on Linux/CI; the real macOS build uses trash_mac.mm instead (see
// CMakeLists.txt).

#include "maccleaner/trash.hpp"

#include <filesystem>
#include <system_error>

namespace maccleaner::trash {

bool moveToTrash(const std::filesystem::path& path, std::string& error) {
    std::error_code ec;
    const std::uintmax_t removed = std::filesystem::remove_all(path, ec);
    if (ec) {
        error = ec.message();
        return false;
    }
    if (removed == 0) {
        error = "nothing was removed (path did not exist?)";
        return false;
    }
    return true;
}

bool isNativeImplementation() {
    return false;
}

} // namespace maccleaner::trash
