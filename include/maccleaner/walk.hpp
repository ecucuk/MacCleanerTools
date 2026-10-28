#pragma once

#include <sys/stat.h>

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <functional>

namespace maccleaner {

// Called for every regular file found; `st` is its lstat, so size and mode
// come without a second syscall.
using FileVisitor = std::function<void(const std::filesystem::path& path, const struct stat& st)>;

// Called roughly once per directory with the number of entries seen so far
// and the directory being walked.
using WalkProgress = std::function<void(std::uint64_t visited, const std::filesystem::path& currentDir)>;

// Return false to leave a directory (and everything under it) out of the walk.
using DirFilter = std::function<bool(const std::filesystem::path& dir)>;

// Depth-first walk of `root` that reports every regular file to `onFile`.
//
//   - Symlinks are never followed, neither to directories (no cycles, no
//     escaping the root) nor to files.
//   - Iteration errors are consumed *per directory*: an unreadable dir (TCC's
//     EPERM, plain EACCES, or a race with deletion) is skipped and the walk
//     continues elsewhere. This is why the walk is a hand-rolled stack rather
//     than recursive_directory_iterator: the iterator's skip_permission_denied
//     only forgives EACCES, and any other error (notably TCC's EPERM under
//     ~/Library) aborts the whole iteration.
//   - `enterDir` (optional) is asked before a subdirectory is queued; `root`
//     itself is always entered.
//
// `cancelled` (optional) is checked between entries. Returns the number of
// entries visited.
std::uint64_t walkFiles(const std::filesystem::path& root,
                        const FileVisitor& onFile,
                        const std::atomic<bool>* cancelled = nullptr,
                        const WalkProgress& progress = {},
                        const DirFilter& enterDir = {});

} // namespace maccleaner
