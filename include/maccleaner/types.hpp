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

// Where a category's candidates come from and how finely we enumerate them.
enum class Granularity {
    WholeRoot,      // the root itself is the one deletable unit (e.g. ~/.Trash contents are files)
    DirectChildren, // each direct child of the root is its own deletable unit
};

struct ScanTarget {
    Category category;
    std::string label;
    std::filesystem::path root;
    Granularity granularity = Granularity::DirectChildren;
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
