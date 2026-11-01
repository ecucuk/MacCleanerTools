#pragma once

#include <cstdint>
#include <filesystem>
#include <functional>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "maccleaner/safety.hpp"

namespace maccleaner::uninstaller {

struct AppInfo {
    std::string path;          // /Applications/Foo.app
    std::string name;          // CFBundleName, else the bundle file name without ".app"
    std::string bundleId;      // CFBundleIdentifier
    std::string version;       // CFBundleShortVersionString
    std::string teamId;        // from the code signature, "" if unsigned or ad hoc
    std::vector<std::string> appGroups; // com.apple.security.application-groups
    bool appleSigned = false;  // signed by Apple (anchor apple)
    std::uint64_t sizeBytes = 0;
};

enum class LeftoverKind { AppBundle, Support, Cache, Preferences, Container,
                          GroupContainer, SavedState, Logs, HTTPStorage,
                          WebKit, Cookies, LaunchAgent };

struct Leftover {
    std::string path;
    LeftoverKind kind = LeftoverKind::Support;
    std::uint64_t sizeBytes = 0;
    bool needsAdmin = false;   // not owned by the current user: listed, never removed
};

struct LaunchAgentInfo {
    std::string label;
    std::string program; // Program, else ProgramArguments[0]
};

// What the tool reads from the machine, injected so tests can use a fake tree.
struct Environment {
    std::vector<std::string> appFolders; // /Applications, ~/Applications
    std::string home;
    std::function<std::optional<AppInfo>(const std::string& appPath)> readApp;
    std::function<bool(const std::string& path)> ownedByUser; // lstat st_uid == geteuid()
    std::function<std::optional<LaunchAgentInfo>(const std::string& plistPath)> readLaunchAgent;
    std::string systemLibrary = "/Library"; // tests point this at a temp dir
};

constexpr const char* kSelfBundleId = "com.maccleaner.app";

std::string toString(LeftoverKind kind);

// Installed, third-party apps, sorted by name. Leaves out Apple-signed apps,
// apps without a bundle ID, symlinks and MacCleaner itself.
std::vector<AppInfo> listApps(const Environment& env);

// The bundle first, then matches in the user's and the system Library.
std::vector<Leftover> findLeftovers(const Environment& env, const AppInfo& app);

// ID rule: equal to the bundle ID, or starts with "<bundleId>.". Case-insensitive.
bool matchesId(std::string_view entryName, std::string_view bundleId);

struct RemovalResult {
    std::string path;
    bool ok = false;
    std::string error;
};

using TrashFn = std::function<bool(const std::filesystem::path&, std::string& error)>;
using RunningFn = std::function<bool(const std::string& appPath)>;

// True if any process of the current user runs from inside the bundle.
bool isAppRunning(const std::string& appPath);

// The <home>/Library locations of findLeftovers. /Library is never allowed.
safety::AllowedRoots leftoverRoots(const Environment& env);

// Moves the selected rows to the Trash: leftovers first, the bundle last.
// Refuses (empty result, *refusal set) for an Apple-signed or running app.
// A failure on one row does not stop the others. needsAdmin rows are skipped.
std::vector<RemovalResult> uninstall(const Environment& env, const AppInfo& app,
                                     const std::vector<Leftover>& selected, const TrashFn& trash,
                                     const RunningFn& running, std::string* refusal);

// Real machine: platform file (uninstaller_mac.mm / uninstaller_fallback.cpp).
Environment defaultEnvironment();

} // namespace maccleaner::uninstaller
