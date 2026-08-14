#pragma once

#include "maccleaner/safety.hpp"
#include "maccleaner/types.hpp"

#include <filesystem>
#include <string>
#include <vector>

namespace maccleaner {

enum class DeleteMode {
    Trash,      // move to Trash (recoverable) -- the default
    Permanent,  // std::filesystem::remove_all -- requires an explicit opt-in upstream (CLI --permanent)
};

struct CleanOptions {
    bool dryRun = true; // report what would happen; no filesystem mutation
    DeleteMode mode = DeleteMode::Trash;
};

struct CleanOutcome {
    std::filesystem::path path;
    std::uintmax_t sizeBytes = 0;
    bool succeeded = false;
    bool skipped = false;      // rejected by the safety layer
    std::string message;       // error, or rejection reason, when applicable
};

struct CleanReport {
    std::vector<CleanOutcome> outcomes;
    std::uintmax_t bytesFreed = 0;   // only counts succeeded, non-dry-run outcomes
    std::uintmax_t bytesWouldFree = 0; // counts everything that passed the safety check
};

// True for categories that cannot meaningfully be moved to the Trash because
// they already *are* the Trash. Emptying ~/.Trash by trashing its contents
// would move each item back into the directory it came from, freeing nothing;
// the only delete that makes sense there is a permanent one.
bool requiresPermanentDelete(Category category);

// Cleans every entry in `result`. Each entry is independently re-validated
// against `allowed` immediately before deletion (not just at scan time) --
// scans and cleans can be arbitrarily far apart in time (interactive CLI use),
// and re-checking defends against the target having changed underneath us
// (TOCTOU on the "is this still what we think it is" level; see README for
// the lower-level TOCTOU caveat this does *not* cover).
//
// Note `options.mode` is upgraded to Permanent for categories where
// requiresPermanentDelete() holds, regardless of what the caller asked for.
// Dry run is never overridden -- a dry run stays a dry run.
CleanReport clean(const ScanResult& result, const safety::AllowedRoots& allowed, const CleanOptions& options);

} // namespace maccleaner
