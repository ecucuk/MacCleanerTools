#pragma once

#include <functional>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <vector>

namespace maccleaner::updater {

// Where an outdated item came from. Only Homebrew items are upgraded in-app;
// the others link out to the place that can update them.
enum class Source { Homebrew, MacPorts, AppStore, Sparkle };

std::string toString(Source source); // "Homebrew", "MacPorts", "App Store", "Sparkle"

struct OutdatedItem {
    Source source = Source::Homebrew;
    std::string name;             // brew/port token, or the app name
    std::string installedVersion;
    std::string latestVersion;
    std::string appPath;          // App Store and Sparkle
    std::string storeId;          // App Store
    bool isCask = false;          // Homebrew
    bool pinned = false;          // Homebrew: listed, but brew refuses to upgrade it
};

// <0, 0 or >0. Parts are runs of digits or of letters; digits compare as
// numbers, letters case-insensitively, a letter part sorts below a number
// part ("2.0b1" < "2.0"), and a missing part is 0 ("1.0" == "1").
int compareVersions(std::string_view a, std::string_view b);

// --- parsers (exposed for tests) -------------------------------------------

// `brew outdated --json=v2`. Lines before the JSON (warnings) are ignored.
std::vector<OutdatedItem> parseBrewOutdated(std::string_view output);
// `brew info --cask --json=v2 --installed`: the bundle names of the `app`
// artifacts ("LinearMouse.app"), used to keep cask apps out of the Sparkle list.
std::set<std::string> parseBrewCaskApps(std::string_view output);
// `port outdated`: "name  installed < latest" lines.
std::vector<OutdatedItem> parsePortOutdated(std::string_view output);
// iTunes lookup JSON: trackId -> store version.
std::map<std::string, std::string> parseItunesLookup(std::string_view json);

struct AppcastLatest {
    std::string version;      // sparkle:version, compared with CFBundleVersion
    std::string shortVersion; // sparkle:shortVersionString, shown to the user
};
// The highest item without a <sparkle:channel> (betas and other opt-in
// channels), or nullopt if there is none.
std::optional<AppcastLatest> parseAppcast(std::string_view xml);

// --- running commands --------------------------------------------------------

struct CommandResult {
    int exitCode = 0;   // -1 = timed out or could not start
    std::string output; // stdout and stderr, merged
};

// Every external command (brew, port, mdls, curl) goes through this, so the
// tests can answer for them.
using RunFn = std::function<CommandResult(const std::vector<std::string>& argv, int timeoutSeconds)>;

// posix_spawn, no shell: argv[0] is an absolute path and names read from JSON
// or XML can never become shell syntax. stdin is /dev/null, so a tool that
// wants a password fails instead of hanging. On timeout the child's process
// group gets SIGTERM, then SIGKILL after 2 s.
CommandResult runCommand(const std::vector<std::string>& argv, int timeoutSeconds);

// --- checking and upgrading --------------------------------------------------

struct BundleInfo {
    std::string shortVersion;  // CFBundleShortVersionString
    std::string bundleVersion; // CFBundleVersion
    std::string feedURL;       // SUFeedURL (Sparkle)
};

// What checkUpdates reads from the machine, injected so tests can replace it.
struct Environment {
    std::string brewPath; // "" = Homebrew not installed
    std::string portPath; // "" = MacPorts not installed
    std::vector<std::string> appFolders;
    std::function<std::optional<BundleInfo>(const std::string& appPath)> readBundle;
    std::function<bool(const std::string& path)> exists; // App Store receipt check
    std::string country = "us"; // iTunes lookup storefront
};

// The real machine: tool paths, /Applications and ~/Applications, Info.plist
// through CFBundle, and the locale's region.
Environment defaultEnvironment();

struct SourceStatus {
    Source source = Source::Homebrew;
    bool available = false; // the tool is installed (always true for apps)
    std::string error;      // "" = checked fine
};

struct CheckResult {
    std::vector<OutdatedItem> items;
    std::vector<SourceStatus> sources; // always all four, in Source order
};

// Checks Homebrew, MacPorts, the App Store and Sparkle feeds, in that order.
// A failing source records its error and the others still run. `cancelled`
// is polled before each command; once it returns true no command starts.
CheckResult checkUpdates(const RunFn& run, const Environment& env, const std::function<bool()>& cancelled);

// argv for upgrading one Homebrew item (exposed for tests).
std::vector<std::string> upgradeCommand(const Environment& env, const OutdatedItem& item);
CommandResult upgradeBrew(const RunFn& run, const Environment& env, const OutdatedItem& item);

// What the user can paste into Terminal: "sudo port upgrade curl",
// "brew upgrade --cask firefox". The app itself never runs sudo.
std::string manualCommand(const OutdatedItem& item);

} // namespace maccleaner::updater
