#pragma once

#include <filesystem>
#include <string>
#include <vector>

namespace maccleaner::safety {

// Deletion is allowlist-based, not denylist-based: a candidate path is only
// ever considered safe if it resolves (via weakly_canonical) to a descendant
// of one of the explicitly registered roots below. This is deliberately more
// restrictive than "anything under $HOME" -- it means a bug in the scanner
// can produce a path outside the known cache/log/build-artifact directories
// and it will still be rejected here rather than deleted.
class AllowedRoots {
public:
    void add(const std::filesystem::path& root);
    const std::vector<std::filesystem::path>& roots() const { return roots_; }

private:
    std::vector<std::filesystem::path> roots_;
};

// Resolves `candidate` and checks, in order:
//   1. it exists and is not itself a symlink (we never delete through a
//      symlink -- a malicious or accidental symlink under a cache dir could
//      otherwise point anywhere on disk);
//   2. its weakly_canonical resolution is a strict descendant of one of
//      `allowed.roots()`;
//   3. it is not equal to, or an ancestor of, any known-dangerous path
//      (home directory root, "/", SIP-protected system paths);
//   4. it is owned by the current effective user (st_uid == geteuid()),
//      so we never touch files another account (including root) owns even
//      if they happen to live under a nominally-allowed root.
// On rejection, `reasonIfUnsafe` (if non-null) is filled with a human
// readable explanation suitable for CLI output.
bool isSafeToDelete(const std::filesystem::path& candidate,
                     const AllowedRoots& allowed,
                     std::string* reasonIfUnsafe = nullptr);

// Top-level system containers (/System, /Library, /usr, ...) we refuse to
// ever delete, or delete into, regardless of what the allowlist says -- a
// last line of defense against a misconfigured ScanTarget. Checked in both
// directions: a candidate under one of these is rejected, and so is a
// candidate that would (via a misconfigured allowed root) contain one of
// these. The home directory itself is guarded separately inside
// isSafeToDelete, since -- unlike these system paths -- legitimate
// candidates are expected to live *underneath* it.
const std::vector<std::filesystem::path>& hardDenylist();

} // namespace maccleaner::safety
