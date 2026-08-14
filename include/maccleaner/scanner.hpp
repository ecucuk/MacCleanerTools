#pragma once

#include "maccleaner/safety.hpp"
#include "maccleaner/types.hpp"

#include <filesystem>
#include <vector>

namespace maccleaner {

// Returns the current user's home directory, preferring $HOME and falling
// back to the password database entry (getpwuid) so this still works when
// $HOME is unset -- e.g. invoked via launchd or certain sudo configurations.
std::filesystem::path homeDirectory();

// The default set of known cleanup locations. Each target's root is derived
// from `home`, and each target's `exclusions` are resolved against the whole
// set before returning. Registering every target's root with an AllowedRoots
// instance is the caller's responsibility (see registerAllowedRoots below) --
// the scanner intentionally does not own safety policy.
std::vector<ScanTarget> defaultTargets(const std::filesystem::path& home);

// Fills each target's `exclusions` with the roots of every other target nested
// underneath it. Called by defaultTargets(); exposed for tests and for callers
// assembling a custom target list.
//
// Note this runs over the *complete* target list, before any --only filtering.
// A category's meaning must not depend on what else was selected in the same
// invocation: "user caches" is always "~/Library/Caches minus the package
// manager caches that have their own categories", whether or not the user also
// asked for those categories in this run.
void resolveExclusions(std::vector<ScanTarget>& targets);

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
//
// Any path in `exclusions` that falls inside `root` is skipped along with its
// entire subtree, so a parent category never counts bytes that a nested
// category reports separately.
std::uintmax_t directorySizeBytes(const std::filesystem::path& root,
                                   const std::vector<std::filesystem::path>& exclusions = {});

} // namespace maccleaner
