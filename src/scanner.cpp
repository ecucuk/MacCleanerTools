#include "maccleaner/scanner.hpp"

#include <dirent.h>
#include <pwd.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
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

namespace {

// std::filesystem::file_size returns static_cast<uintmax_t>(-1) on failure --
// it does not return 0. Accumulating that unchecked wraps the running total
// (each failure subtracts 1 byte, and a total that is still 0 jumps to ~16 EB),
// so every size query has to consume its error_code.
std::uintmax_t fileSizeOrZero(const fs::path& path) {
    std::error_code ec;
    const std::uintmax_t size = fs::file_size(path, ec);
    return ec ? 0 : size;
}

// The size of a symlink *itself* (the length of the stored target path), not
// the size of what it points at. fs::file_size follows the link, so it reports
// the target's size for a symlink-to-file and fails outright for a
// symlink-to-directory or a broken link; lstat is what actually answers this,
// and matches how `du` counts symlinks.
std::uintmax_t symlinkOwnSizeBytes(const fs::path& path) {
    struct stat st {};
    if (::lstat(path.c_str(), &st) != 0) {
        return 0;
    }
    return static_cast<std::uintmax_t>(st.st_size);
}

// Purely lexical strict-descendant test. Both paths come from the same
// home-derived construction here, so no canonicalization is needed; using
// lexically_relative rather than a string prefix avoids "/a/b" matching
// "/a/bc". (safety.cpp has its own copy that operates on resolved paths --
// these are deliberately separate: this one is a scan-time bookkeeping
// detail, that one is a security boundary.)
bool isUnder(const fs::path& path, const fs::path& root) {
    const fs::path relative = path.lexically_relative(root);
    if (relative.empty() || relative == ".") {
        return false;
    }
    return relative.begin()->string() != "..";
}

} // namespace

void resolveExclusions(std::vector<ScanTarget>& targets) {
    for (ScanTarget& target : targets) {
        target.exclusions.clear();
        for (const ScanTarget& other : targets) {
            if (&other != &target && isUnder(other.root, target.root)) {
                target.exclusions.push_back(other.root);
            }
        }
    }
}

std::vector<ScanTarget> defaultTargets(const fs::path& home) {
    const fs::path library = home / "Library";
    const fs::path developer = library / "Developer";
    const fs::path xcode = developer / "Xcode";

    // Several of these roots nest inside each other (Homebrew/Yarn/pip under
    // Caches, DiagnosticReports under Logs). resolveExclusions() below records
    // that nesting so the outer category neither double-counts nor deletes the
    // inner one.
    std::vector<ScanTarget> targets{
        {Category::UserCaches, "User application caches", library / "Caches", {}},
        {Category::UserLogs, "User logs", library / "Logs", {}},
        {Category::DiagnosticReports, "Crash/diagnostic reports", library / "Logs" / "DiagnosticReports", {}},
        {Category::XcodeDerivedData, "Xcode build products & indexes", xcode / "DerivedData", {}},
        {Category::XcodeArchives, "Xcode .xcarchive bundles", xcode / "Archives", {}},
        {Category::XcodeDeviceSupport, "Per-device-version debug symbols", xcode / "iOS DeviceSupport", {}},
        {Category::SimulatorCaches, "Simulator caches", developer / "CoreSimulator" / "Caches", {}},
        {Category::HomebrewCache, "Downloaded Homebrew bottles/sources", library / "Caches" / "Homebrew", {}},
        {Category::NpmCache, "npm package cache", home / ".npm" / "_cacache", {}},
        {Category::YarnCache, "Yarn package cache", library / "Caches" / "Yarn", {}},
        {Category::PipCache, "pip wheel/http cache", library / "Caches" / "pip", {}},
        {Category::Trash, "Items already in the Trash", home / ".Trash", {}},
    };
    resolveExclusions(targets);
    return targets;
}

void registerAllowedRoots(const std::vector<ScanTarget>& targets, safety::AllowedRoots& allowed) {
    for (const ScanTarget& target : targets) {
        allowed.add(target.root);
    }
}

std::uintmax_t directorySizeBytes(const fs::path& root, const std::vector<fs::path>& exclusions) {
    std::error_code ec;
    if (!fs::exists(root, ec) || ec) {
        return 0;
    }

    // is_symlink itself doesn't follow the link, so this is safe even if
    // `root` is a symlink -- we just report its own size and stop.
    if (fs::is_symlink(root, ec)) {
        return symlinkOwnSizeBytes(root);
    }

    if (!fs::is_directory(root, ec)) {
        return fileSizeOrZero(root);
    }

    const auto isExcluded = [&exclusions](const fs::path& path) {
        for (const fs::path& excluded : exclusions) {
            if (path == excluded) {
                return true;
            }
        }
        return false;
    };

    std::uintmax_t total = 0;
    fs::directory_options options = fs::directory_options::skip_permission_denied;
    for (auto it = fs::recursive_directory_iterator(root, options, ec);
         it != fs::recursive_directory_iterator();
         it.increment(ec)) {
        if (ec) {
            break; // stop walking this subtree on error; keep what we've accumulated
        }

        const fs::directory_entry& entry = *it;

        // A nested category's root: its bytes are reported by that category,
        // so skip the whole subtree rather than counting it twice.
        if (isExcluded(entry.path())) {
            it.disable_recursion_pending();
            continue;
        }

        // Never descend into a symlinked directory: count it as its own
        // (typically tiny) size and skip its children entirely.
        std::error_code symlinkEc;
        if (fs::is_symlink(entry.path(), symlinkEc)) {
            it.disable_recursion_pending();
            total += symlinkOwnSizeBytes(entry.path());
            continue;
        }

        std::error_code kindEc;
        if (entry.is_regular_file(kindEc) && !kindEc) {
            std::error_code sizeEc;
            const std::uintmax_t size = entry.file_size(sizeEc);
            if (!sizeEc) {
                total += size;
            }
        }
    }
    return total;
}

namespace {

// True for entries macOS itself will not let this process touch, so offering
// them for deletion would only manufacture guaranteed FAIL rows (the exact
// failure mode: "Move to Trash" on ~/Library/Caches selected wholesale fails
// on com.apple.homed, CloudKit, com.apple.Safari, ...).
//
// Two distinct mechanisms, detected separately:
//
//   1. BSD flags: UF_DATAVAULT / SF_RESTRICTED mark SIP-style protection
//      right on the inode. Cheap to read via lstat.
//   2. TCC. The dirs the user tripped over carry *no* flags (st_flags == 0,
//      mode drwxr-xr-x, owned by the user!) -- the denial is enforced
//      per-process at syscall level and is invisible to stat. The only
//      reliable detector is attempting the operation: opendir() fails with
//      EPERM for a TCC-protected dir. EACCES, by contrast, means ordinary
//      mode bits -- such a dir is still perfectly trashable (rename only
//      needs write on the parent), so it must NOT be excluded.
//
// The probe deliberately runs with the scanning process's own privileges:
// grant the app Full Disk Access and TCC-only dirs (e.g. Safari's caches)
// automatically become visible and cleanable, with no code change.
bool isSystemProtected(const fs::path& path) {
#ifdef __APPLE__
    struct stat st {};
    if (::lstat(path.c_str(), &st) != 0) {
        return errno == EPERM; // can't even stat it: TCC says no
    }
    if ((st.st_flags & (UF_DATAVAULT | SF_RESTRICTED)) != 0) {
        return true;
    }
    if (S_ISDIR(st.st_mode)) {
        if (DIR* dir = ::opendir(path.c_str()); dir != nullptr) {
            ::closedir(dir);
            return false;
        }
        return errno == EPERM;
    }
#else
    (void)path; // no SIP/TCC elsewhere; plain permissions are handled downstream
#endif
    return false;
}

FileEntry makeFileEntry(const fs::directory_entry& entry, const std::vector<fs::path>& exclusions) {
    FileEntry result;
    result.path = entry.path();

    std::error_code ec;
    result.isDirectory = entry.is_directory(ec) && !ec;

    if (result.isDirectory) {
        result.sizeBytes = directorySizeBytes(entry.path(), exclusions);
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
        const fs::directory_entry& entry = *it;

        // A direct child that *is* another category's root belongs to that
        // category: don't list it here and don't offer it for deletion.
        // Children that merely *contain* a nested root are still listed, but
        // makeFileEntry sizes them with the exclusion list applied.
        const bool isNestedRoot = std::find(target.exclusions.begin(), target.exclusions.end(), entry.path()) !=
                                   target.exclusions.end();
        if (isNestedRoot) {
            continue;
        }

        // SIP/TCC-protected entries are undeletable by construction; listing
        // them would just bake failures into "select all". Checked before the
        // size walk, which could not see inside them anyway.
        if (isSystemProtected(entry.path())) {
            continue;
        }

        result.entries.push_back(makeFileEntry(entry, target.exclusions));
    }

    // Largest first: the whole point of the report is deciding what to delete,
    // and directory order is meaningless for that.
    std::sort(result.entries.begin(), result.entries.end(),
               [](const FileEntry& a, const FileEntry& b) { return a.sizeBytes > b.sizeBytes; });

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
