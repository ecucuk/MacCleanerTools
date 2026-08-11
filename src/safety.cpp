#include "maccleaner/safety.hpp"

#include <sys/stat.h>
#include <unistd.h>

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
        "/System", "/Library", "/usr", "/bin", "/sbin", "/private", "/Applications", "/Volumes",
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

} // namespace

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

} // namespace maccleaner::safety
