#include "maccleaner/uninstaller.hpp"

#include <cstdlib>
#include <unistd.h>
#include <sys/stat.h>

namespace maccleaner::uninstaller {

// Off macOS there are no app bundles to read.
Environment defaultEnvironment() {
    Environment env;
    env.appFolders = {"/Applications"};
    if (const char* home = std::getenv("HOME")) {
        env.home = home;
        env.appFolders.push_back(env.home + "/Applications");
    }
    env.readApp = [](const std::string&) { return std::optional<AppInfo>(); };
    env.readLaunchAgent = [](const std::string&) { return std::optional<LaunchAgentInfo>(); };
    env.ownedByUser = [](const std::string& path) {
        struct stat st {};
        return ::lstat(path.c_str(), &st) == 0 && st.st_uid == ::geteuid();
    };
    return env;
}

} // namespace maccleaner::uninstaller
