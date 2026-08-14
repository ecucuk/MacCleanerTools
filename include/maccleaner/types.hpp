#pragma once

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace maccleaner {

// Every category maps to one or more concrete filesystem roots discovered
// at runtime (see scanner.hpp). Keeping this as an enum (rather than a
// free-form string) lets the CLI and safety layer switch on it exhaustively.
enum class Category {
    UserCaches,          // ~/Library/Caches/<app>
    UserLogs,             // ~/Library/Logs
    DiagnosticReports,    // ~/Library/Logs/DiagnosticReports
    XcodeDerivedData,     // ~/Library/Developer/Xcode/DerivedData/<project>
    XcodeArchives,        // ~/Library/Developer/Xcode/Archives
    XcodeDeviceSupport,   // ~/Library/Developer/Xcode/iOS DeviceSupport
    SimulatorCaches,      // ~/Library/Developer/CoreSimulator/Caches
    HomebrewCache,        // ~/Library/Caches/Homebrew
    NpmCache,              // ~/.npm/_cacache
    YarnCache,             // ~/Library/Caches/Yarn
    PipCache,              // ~/Library/Caches/pip
    Trash,                 // ~/.Trash
};

std::string toString(Category category);

// A single filesystem entry considered for cleanup. For most categories this
// is one entry per direct child of the category root (e.g. one entry per
// app's cache folder), not the root itself -- see ScanTarget::granularity.
struct FileEntry {
    std::filesystem::path path;
    std::uintmax_t sizeBytes = 0;
    std::filesystem::file_time_type lastModified{};
    bool isDirectory = false;
};

// A category's deletable units are always the *direct children* of its root,
// never the root itself. This isn't a stylistic choice: safety::isSafeToDelete
// only accepts strict descendants of an allowlisted root, so a "delete the root
// itself" mode could never actually pass the safety check -- it would scan
// something and then unconditionally skip it at clean time. Categories whose
// root should end up empty (e.g. Trash) express that by deleting every child.
struct ScanTarget {
    Category category;
    std::string label;
    std::filesystem::path root;

    // Roots of *other* targets that live underneath this one, e.g.
    // ~/Library/Caches/Homebrew under ~/Library/Caches. Those subtrees belong
    // to their own category: this target must neither count their bytes (it
    // would double-count the grand total) nor offer them for deletion (cleaning
    // "caches" would silently wipe the Homebrew/Yarn/pip caches that the user
    // did not select). Populated by defaultTargets(); see resolveExclusions().
    std::vector<std::filesystem::path> exclusions;
};

struct ScanResult {
    Category category;
    std::string label;
    std::filesystem::path root;
    std::uintmax_t totalSizeBytes = 0;
    std::vector<FileEntry> entries;
    bool rootExisted = false;
};

} // namespace maccleaner
