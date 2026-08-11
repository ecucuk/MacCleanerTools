#pragma once

#include "maccleaner/safety.hpp"
#include "maccleaner/types.hpp"

#include <filesystem>
#include <optional>
#include <vector>

namespace maccleaner {

// Returns the current user's home directory, preferring $HOME and falling
// back to the password database entry (getpwuid) so this still works when
// $HOME is unset -- e.g. invoked via launchd or certain sudo configurations.
std::filesystem::path homeDirectory();

// The default set of known cleanup locations. Each target's root is derived
// from `home`. Registering every target's root with an AllowedRoots instance
// is the caller's responsibility (see registerAllowedRoots below) -- the
// scanner intentionally does not own safety policy.
std::vector<ScanTarget> defaultTargets(const std::filesystem::path& home);

// Convenience: adds every target's root to `allowed`.
void registerAllowedRoots(const std::vector<ScanTarget>& targets, safety::AllowedRoots& allowed);

// Walks `target.root` and produces a ScanResult. Directory sizes are computed
// by recursive, symlink-non-following traversal (a symlinked child is sized
// as the symlink itself, never dereferenced) so a runaway or cyclic symlink
// cannot cause unbounded recursion or count space that isn't really under
// the target. Permission-denied entries are skipped, not treated as fatal.
ScanResult scanTarget(const ScanTarget& target);

std::vector<ScanResult> scanAll(const std::vector<ScanTarget>& targets);

// Total size, in bytes, of everything reachable from `root` without
// following symlinks. Exposed separately because both the scanner and the
// CLI's "du"-style debugging need it.
std::uintmax_t directorySizeBytes(const std::filesystem::path& root);

} // namespace maccleaner
