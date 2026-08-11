#include "maccleaner/scanner.hpp"

#include <pwd.h>
#include <unistd.h>

#include <cstdlib>
#include <system_error>

namespace maccleaner {

namespace fs = std::filesystem;

std::string toString(Category category) {
    switch (category) {
        case Category::UserCaches: return "User Caches";
        case Category::UserLogs: return "User Logs";
        case Category::DiagnosticReports: return "Diagnostic Reports";
        case Category::XcodeDerivedData: return "Xcode DerivedData";
        case Category::XcodeArchives: return "Xcode Archives";
        case Category::XcodeDeviceSupport: return "Xcode Device Support";
        case Category::SimulatorCaches: return "Simulator Caches";
        case Category::HomebrewCache: return "Homebrew Cache";
        case Category::NpmCache: return "npm Cache";
        case Category::YarnCache: return "Yarn Cache";
        case Category::PipCache: return "pip Cache";
        case Category::Trash: return "Trash";
    }
    return "Unknown";
}

std::filesystem::path homeDirectory() {
    if (const char* home = std::getenv("HOME"); home != nullptr && *home != '\0') {
        return fs::path(home);
    }
    if (struct passwd* pw = ::getpwuid(::getuid()); pw != nullptr && pw->pw_dir != nullptr) {
        return fs::path(pw->pw_dir);
    }
    return fs::current_path();
}

std::vector<ScanTarget> defaultTargets(const fs::path& home) {
    const fs::path library = home / "Library";
    const fs::path developer = library / "Developer";
    const fs::path xcode = developer / "Xcode";

    return {
        {Category::UserCaches, "User application caches", library / "Caches", Granularity::DirectChildren},
        {Category::UserLogs, "User logs", library / "Logs", Granularity::DirectChildren},
        {Category::DiagnosticReports, "Crash/diagnostic reports", library / "Logs" / "DiagnosticReports", Granularity::DirectChildren},
        {Category::XcodeDerivedData, "Xcode build products & indexes", xcode / "DerivedData", Granularity::DirectChildren},
        {Category::XcodeArchives, "Xcode .xcarchive bundles", xcode / "Archives", Granularity::DirectChildren},
        {Category::XcodeDeviceSupport, "Per-device-version debug symbols", xcode / "iOS DeviceSupport", Granularity::DirectChildren},
        {Category::SimulatorCaches, "Simulator caches", developer / "CoreSimulator" / "Caches", Granularity::DirectChildren},
        {Category::HomebrewCache, "Downloaded Homebrew bottles/sources", library / "Caches" / "Homebrew", Granularity::DirectChildren},
        {Category::NpmCache, "npm package cache", home / ".npm" / "_cacache", Granularity::DirectChildren},
        {Category::YarnCache, "Yarn package cache", library / "Caches" / "Yarn", Granularity::DirectChildren},
        {Category::PipCache, "pip wheel/http cache", library / "Caches" / "pip", Granularity::DirectChildren},
        {Category::Trash, "Items already in the Trash", home / ".Trash", Granularity::DirectChildren},
    };
}

void registerAllowedRoots(const std::vector<ScanTarget>& targets, safety::AllowedRoots& allowed) {
    for (const ScanTarget& target : targets) {
        allowed.add(target.root);
    }
}

std::uintmax_t directorySizeBytes(const fs::path& root) {
    std::error_code ec;
    if (!fs::exists(root, ec) || ec) {
        return 0;
    }

    // is_symlink itself doesn't follow the link, so this is safe even if
    // `root` is a symlink -- we just report its own size and stop.
    if (fs::is_symlink(root, ec)) {
        return fs::file_size(root, ec);
    }

    if (!fs::is_directory(root, ec)) {
        return fs::file_size(root, ec);
    }

    std::uintmax_t total = 0;
    fs::directory_options options = fs::directory_options::skip_permission_denied;
    for (auto it = fs::recursive_directory_iterator(root, options, ec);
         it != fs::recursive_directory_iterator();
         it.increment(ec)) {
        if (ec) {
            break; // stop walking this subtree on error; keep what we've accumulated
        }

        const fs::directory_entry& entry = *it;

        // Never descend into a symlinked directory: count it as its own
        // (typically tiny) size and skip its children entirely.
        std::error_code symlinkEc;
        if (fs::is_symlink(entry.path(), symlinkEc)) {
            it.disable_recursion_pending();
            std::error_code sizeEc;
            total += fs::file_size(entry.path(), sizeEc);
            continue;
        }

        if (entry.is_regular_file(ec) && !ec) {
            std::error_code sizeEc;
            total += entry.file_size(sizeEc);
        }
    }
    return total;
}

namespace {

FileEntry makeFileEntry(const fs::directory_entry& entry) {
    FileEntry result;
    result.path = entry.path();

    std::error_code ec;
    result.isDirectory = entry.is_directory(ec) && !ec;

    if (result.isDirectory) {
        result.sizeBytes = directorySizeBytes(entry.path());
    } else {
        result.sizeBytes = entry.file_size(ec);
        if (ec) {
            result.sizeBytes = 0;
        }
    }

    result.lastModified = entry.last_write_time(ec);
    return result;
}

} // namespace

ScanResult scanTarget(const ScanTarget& target) {
    ScanResult result;
    result.category = target.category;
    result.label = target.label;
    result.root = target.root;

    std::error_code ec;
    result.rootExisted = fs::exists(target.root, ec) && !ec;
    if (!result.rootExisted) {
        return result;
    }

    if (target.granularity == Granularity::WholeRoot) {
        FileEntry entry;
        entry.path = target.root;
        entry.isDirectory = fs::is_directory(target.root, ec);
        entry.sizeBytes = directorySizeBytes(target.root);
        result.entries.push_back(entry);
    } else {
        // Deliberately not a range-based for: the non-throwing directory_iterator
        // constructor only suppresses exceptions on construction. Advancing via
        // range-for calls the throwing operator++(), so any error encountered
        // mid-walk (e.g. an entry removed concurrently) would still throw.
        // Using it.increment(ec) keeps every step non-throwing.
        for (auto it = fs::directory_iterator(target.root, fs::directory_options::skip_permission_denied, ec);
             it != fs::directory_iterator();
             it.increment(ec)) {
            if (ec) {
                break;
            }
            result.entries.push_back(makeFileEntry(*it));
        }
    }

    for (const FileEntry& entry : result.entries) {
        result.totalSizeBytes += entry.sizeBytes;
    }
    return result;
}

std::vector<ScanResult> scanAll(const std::vector<ScanTarget>& targets) {
    std::vector<ScanResult> results;
    results.reserve(targets.size());
    for (const ScanTarget& target : targets) {
        results.push_back(scanTarget(target));
    }
    return results;
}

} // namespace maccleaner
