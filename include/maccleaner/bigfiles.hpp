#pragma once

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <vector>

namespace maccleaner {

// One file found by findBigFiles. Always a regular file -- directories,
// symlinks and special files are never reported.
struct BigFile {
    std::filesystem::path path;
    std::uintmax_t sizeBytes = 0;
    std::filesystem::file_time_type lastModified{};
};

struct BigFileScanOptions {
    std::filesystem::path root;                     // where to search (e.g. home)
    std::uintmax_t minSizeBytes = 100ull << 20;     // report files >= this (default 100 MB)
    std::size_t maxResults = 100;                   // keep only the N largest
};

// Called periodically from the scanning thread (NOT the main thread):
// `visited` counts files+dirs seen so far, `currentDir` is the directory
// being walked. Frequency is bounded (roughly once per directory) so it is
// safe to marshal to a UI queue.
using BigFileProgress = std::function<void(std::uint64_t visited, const std::filesystem::path& currentDir)>;

// Called from the scanning thread every time the running top-N list changes
// (a qualifying file was inserted, possibly evicting the smallest). The
// vector is the *current* result set, sorted descending -- a UI can stream
// it straight into its table. Bursty in file-dense directories; throttle on
// the receiving side before marshalling anywhere expensive.
using BigFileResults = std::function<void(const std::vector<BigFile>& currentResults)>;

// Walks `options.root` and returns the largest regular files found, sorted
// by size descending, at most `options.maxResults` of them.
//
// Traversal rules match the rest of the codebase (see scanner.cpp), plus one
// extra requirement specific to whole-home scans:
//
//   - Symlinks are never followed -- neither directory symlinks (no cycles,
//     no escaping the root) nor file symlinks (a symlink's own size is
//     meaningless here).
//   - Every directory's iteration errors are consumed *per directory*: an
//     unreadable dir (TCC's EPERM, plain EACCES, or a race with deletion) is
//     skipped and the walk continues elsewhere. This is why the walk is a
//     hand-rolled stack rather than recursive_directory_iterator: the
//     iterator's skip_permission_denied only forgives EACCES, and any other
//     error (notably TCC's EPERM under ~/Library) aborts the whole
//     iteration, which would silently truncate a home-wide scan.
//   - Hard links are not deduplicated; a file reachable twice is counted
//     twice (same as `du` without -x tricks). Acceptable for "show me what
//     is big" purposes.
//
// `cancelled` (optional) is checked frequently; when it flips to true the
// scan returns early with whatever it has collected so far. `progress`
// (optional) reports liveness for UIs; `onResults` (optional) streams the
// evolving result list so found files can be shown before the walk ends.
std::vector<BigFile> findBigFiles(const BigFileScanOptions& options,
                                   const std::atomic<bool>* cancelled = nullptr,
                                   const BigFileProgress& progress = {},
                                   const BigFileResults& onResults = {});

// Parses a human size like "500M", "1.5G", "200000" (bytes), suffixes
// K/M/G/T, 1024-based, case-insensitive. Returns false on garbage.
// Lives here (not in the CLI) so the GUI's threshold field can reuse it.
bool parseSizeSpec(const std::string& text, std::uintmax_t& outBytes);

} // namespace maccleaner
