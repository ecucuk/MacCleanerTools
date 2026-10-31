#pragma once

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

} // namespace maccleaner::updater
