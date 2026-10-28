#include "maccleaner/walk.hpp"

#include <system_error>
#include <vector>

namespace maccleaner {

namespace fs = std::filesystem;

std::uint64_t walkFiles(const fs::path& root,
                        const FileVisitor& onFile,
                        const std::atomic<bool>* cancelled,
                        const WalkProgress& progress,
                        const DirFilter& enterDir) {
    auto isCancelled = [cancelled] {
        return cancelled != nullptr && cancelled->load(std::memory_order_relaxed);
    };

    std::uint64_t visited = 0;

    // Hand-rolled DFS stack; see the header for why recursive_directory_iterator
    // is unsuitable (its error handling aborts the whole walk on TCC's EPERM).
    std::vector<fs::path> pending;
    pending.push_back(root);

    while (!pending.empty() && !isCancelled()) {
        const fs::path dir = std::move(pending.back());
        pending.pop_back();

        if (progress) {
            progress(visited, dir);
        }

        std::error_code ec;
        fs::directory_iterator it(dir, fs::directory_options::skip_permission_denied, ec);
        if (ec) {
            continue; // unreadable directory (EPERM/EACCES/gone): skip, keep walking
        }

        for (; it != fs::directory_iterator(); it.increment(ec)) {
            if (ec) {
                break; // error mid-listing: abandon this directory only
            }
            if (isCancelled()) {
                return visited;
            }
            ++visited;

            const fs::directory_entry& entry = *it;

            // lstat, not entry.status(): one syscall answers "symlink?",
            // "directory?", "regular?" and the size, without following links.
            struct stat st {};
            if (::lstat(entry.path().c_str(), &st) != 0) {
                continue;
            }
            if (S_ISLNK(st.st_mode)) {
                continue;
            }
            if (S_ISDIR(st.st_mode)) {
                if (!enterDir || enterDir(entry.path())) {
                    pending.push_back(entry.path());
                }
                continue;
            }
            if (S_ISREG(st.st_mode)) {
                onFile(entry.path(), st);
            }
        }
    }

    return visited;
}

} // namespace maccleaner
