#include "maccleaner/safety.hpp"

#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cctype>
#include <iterator>
#include <system_error>

namespace maccleaner::safety {

namespace {

namespace fs = std::filesystem;

// True if `path` is `root` itself or a descendant of it, purely
// lexically (both must already be resolved/canonical for this to be
// meaningful -- see isSafeToDelete). Using lexically_relative rather than
// string-prefix comparison avoids the classic "/Users/alice" matching
// "/Users/alice2" bug.
bool isDescendantOf(const fs::path& path, const fs::path& root) {
    const fs::path relative = path.lexically_relative(root);
    if (relative.empty() || relative == ".") {
        return false; // equal to root, not a descendant
    }
    const std::string first = relative.begin()->string();
    return first != "..";
}

// True if `a` and `b` are the same path, or either is an ancestor of the
// other -- i.e. deleting `a` would necessarily touch `b` or vice versa.
bool overlaps(const fs::path& a, const fs::path& b) {
    return a == b || isDescendantOf(a, b) || isDescendantOf(b, a);
}

} // namespace

void AllowedRoots::add(const fs::path& root) {
    std::error_code ec;
    fs::path resolved = fs::weakly_canonical(root, ec);
    roots_.push_back(ec ? root : resolved);
}

const std::vector<fs::path>& hardDenylist() {
    // System containers: reachable from *either* direction is disqualifying
    // -- a candidate under one of these, or (from a misconfigured allowed
    // root) one of these being under the candidate, is always rejected.
    // Deliberately excludes "/" itself: every absolute path is trivially a
    // descendant of the filesystem root, so denylisting it would make
    // overlaps() reject everything. "/" is never reachable here anyway --
    // candidates must already be strict descendants of an explicitly
    // allowlisted root (see isSafeToDelete), and "/" is never registered as
    // one.
    static const std::vector<fs::path> denylist{
        "/System", "/Library", "/usr", "/bin", "/sbin", "/private", "/Applications",
    };
    return denylist;
}

namespace {

// Unlike hardDenylist()'s system containers, the home directory is not
// checked with the bidirectional overlaps() test: every legitimate allowed
// root (~/Library/Caches, ...) is itself a descendant of $HOME, so a plain
// "is resolved under $HOME" test would reject every valid candidate. What we
// actually want to forbid is a candidate that *is* $HOME, or that sits above
// it (which could only happen with a misconfigured allowed root) -- not
// candidates nested underneath it, which is the normal case.
bool touchesHomeDirectoryItself(const fs::path& resolved) {
    const char* home = std::getenv("HOME");
    if (home == nullptr) {
        return false;
    }
    std::error_code ec;
    const fs::path resolvedHome = fs::weakly_canonical(fs::path(home), ec);
    if (ec) {
        return false;
    }
    return resolved == resolvedHome || isDescendantOf(resolvedHome, resolved);
}

// Files on external volumes are fair game (a folder scan may sit on one), but
// /Volumes itself and each mount point directly under it are never deleted.
bool isVolumesOrMountPoint(const fs::path& resolved) {
    const fs::path volumes = "/Volumes";
    return overlaps(resolved, volumes) && std::distance(resolved.begin(), resolved.end()) <= 3;
}

} // namespace

bool isInsidePhotosLibrary(const fs::path& path) {
    for (const fs::path& component : path) {
        std::string extension = component.extension().string();
        std::transform(extension.begin(), extension.end(), extension.begin(),
                       [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
        if (extension == ".photoslibrary") {
            return true;
        }
    }
    return false;
}

bool isSafeToDelete(const fs::path& candidate, const AllowedRoots& allowed, std::string* reasonIfUnsafe) {
    auto reject = [&](const std::string& reason) {
        if (reasonIfUnsafe != nullptr) {
            *reasonIfUnsafe = reason;
        }
        return false;
    };

    std::error_code ec;

    // 1. Never delete through a symlink: lstat the *un-resolved* path and
    //    bail if it's a symlink, before we even canonicalize it.
    struct stat lst {};
    if (::lstat(candidate.c_str(), &lst) != 0) {
        return reject("cannot stat path (" + candidate.string() + ")");
    }
    if (S_ISLNK(lst.st_mode)) {
        return reject("refusing to delete a symlink: " + candidate.string());
    }

#ifdef __APPLE__
    // Defense in depth against SIP-marked inodes: the scanner already filters
    // these out (along with TCC-protected dirs, which carry no flags at all
    // and are only detectable by probing -- see isSystemProtected in
    // scanner.cpp), but a candidate arriving through some other route is
    // still rejected here.
    if ((lst.st_flags & (UF_DATAVAULT | SF_RESTRICTED)) != 0) {
        return reject("protected by macOS (SIP data vault / restricted flag): " + candidate.string());
    }
#endif

    const fs::path resolved = fs::weakly_canonical(candidate, ec);
    if (ec) {
        return reject("failed to resolve path: " + ec.message());
    }

    // 2. Must be a strict descendant of one of the allowed roots.
    bool underAllowedRoot = false;
    for (const fs::path& root : allowed.roots()) {
        if (isDescendantOf(resolved, root)) {
            underAllowedRoot = true;
            break;
        }
    }
    if (!underAllowedRoot) {
        return reject("not under any allowlisted cleanup root: " + resolved.string());
    }

    // 3. Must not be, contain, or live inside any hard-denylisted system path.
    for (const fs::path& denied : hardDenylist()) {
        if (overlaps(resolved, denied)) {
            return reject("path is protected: " + denied.string());
        }
    }

    // 3b. Must not be the home directory itself (see touchesHomeDirectoryItself
    //     for why this is a narrower check than the system-container one above).
    if (touchesHomeDirectoryItself(resolved)) {
        return reject("refusing to delete the home directory itself");
    }

    if (isVolumesOrMountPoint(resolved)) {
        return reject("refusing to delete /Volumes or a volume mount point: " + resolved.string());
    }

    // 3c. Never reach into a Photos library package; its assets are deleted
    //     through PhotoKit instead.
    if (isInsidePhotosLibrary(resolved)) {
        return reject("inside a Photos library package (delete it from Photos instead): " + resolved.string());
    }

    // 4. Must be owned by the current effective user.
    struct stat st {};
    if (::stat(resolved.c_str(), &st) != 0) {
        return reject("cannot stat resolved path (" + resolved.string() + ")");
    }
    if (st.st_uid != ::geteuid()) {
        return reject("path is not owned by the current user: " + resolved.string());
    }

    return true;
}

bool isSafeToUninstall(const fs::path& appBundle, const std::vector<fs::path>& appFolders,
                       std::string* reasonIfUnsafe) {
    auto reject = [&](const std::string& reason) {
        if (reasonIfUnsafe != nullptr) {
            *reasonIfUnsafe = reason;
        }
        return false;
    };

    struct stat lst {};
    if (::lstat(appBundle.c_str(), &lst) != 0) {
        return reject("cannot stat path (" + appBundle.string() + ")");
    }
    if (S_ISLNK(lst.st_mode)) {
        return reject("refusing to uninstall a symlink: " + appBundle.string());
    }
    if (!S_ISDIR(lst.st_mode)) {
        return reject("not a directory: " + appBundle.string());
    }
    std::string extension = appBundle.extension().string();
    std::transform(extension.begin(), extension.end(), extension.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    if (extension != ".app") {
        return reject("not an app bundle (*.app): " + appBundle.string());
    }
    if (lst.st_uid != ::geteuid()) {
        return reject("bundle is not owned by the current user: " + appBundle.string());
    }

    std::error_code ec;
    const fs::path parent = fs::weakly_canonical(appBundle.parent_path(), ec);
    if (ec) {
        return reject("failed to resolve path: " + ec.message());
    }
    for (const fs::path& folder : appFolders) {
        std::error_code fec;
        if (fs::weakly_canonical(folder, fec) == parent && !fec) {
            return true;
        }
    }
    return reject("not a direct child of an applications folder: " + appBundle.string());
}

} // namespace maccleaner::safety
