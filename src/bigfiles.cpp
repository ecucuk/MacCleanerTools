#include "maccleaner/bigfiles.hpp"

#include <sys/stat.h>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <string>
#include <system_error>

namespace maccleaner {

namespace fs = std::filesystem;

std::vector<BigFile> findBigFiles(const BigFileScanOptions& options,
                                   const std::atomic<bool>* cancelled,
                                   const BigFileProgress& progress) {
    std::vector<BigFile> results; // kept sorted descending; worst element last

    auto isCancelled = [cancelled] {
        return cancelled != nullptr && cancelled->load(std::memory_order_relaxed);
    };

    // Inserts keeping `results` sorted by size descending and capped at
    // maxResults. With the cap at typical values (<= a few hundred) the
    // linear upper_bound + insert is cheaper than maintaining a heap and
    // keeps the vector permanently display-ready.
    auto offer = [&](BigFile&& candidate) {
        if (results.size() >= options.maxResults &&
            candidate.sizeBytes <= results.back().sizeBytes) {
            return;
        }
        auto pos = std::upper_bound(results.begin(), results.end(), candidate,
                                     [](const BigFile& a, const BigFile& b) { return a.sizeBytes > b.sizeBytes; });
        results.insert(pos, std::move(candidate));
        if (results.size() > options.maxResults) {
            results.pop_back();
        }
    };

    std::uint64_t visited = 0;

    // Hand-rolled DFS stack; see the header for why recursive_directory_iterator
    // is unsuitable (its error handling aborts the whole walk on TCC's EPERM).
    std::vector<fs::path> pending;
    pending.push_back(options.root);

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
                return results;
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
                pending.push_back(entry.path());
                continue;
            }
            if (!S_ISREG(st.st_mode)) {
                continue;
            }

            const auto size = static_cast<std::uintmax_t>(st.st_size);
            if (size < options.minSizeBytes) {
                continue;
            }

            BigFile found;
            found.path = entry.path();
            found.sizeBytes = size;
            std::error_code timeEc;
            found.lastModified = fs::last_write_time(entry.path(), timeEc);
            offer(std::move(found));
        }
    }

    return results;
}

bool parseSizeSpec(const std::string& text, std::uintmax_t& outBytes) {
    if (text.empty()) {
        return false;
    }

    std::size_t pos = 0;
    double value = 0;
    try {
        value = std::stod(text, &pos);
    } catch (const std::exception&) {
        return false;
    }
    if (value < 0) {
        return false;
    }

    // Skip optional whitespace between number and suffix.
    while (pos < text.size() && std::isspace(static_cast<unsigned char>(text[pos]))) {
        ++pos;
    }

    std::uintmax_t multiplier = 1;
    if (pos < text.size()) {
        switch (std::toupper(static_cast<unsigned char>(text[pos]))) {
            case 'K': multiplier = 1ull << 10; break;
            case 'M': multiplier = 1ull << 20; break;
            case 'G': multiplier = 1ull << 30; break;
            case 'T': multiplier = 1ull << 40; break;
            default: return false;
        }
        ++pos;
        // Tolerate a trailing B ("500MB"), nothing else.
        if (pos < text.size() && std::toupper(static_cast<unsigned char>(text[pos])) == 'B') {
            ++pos;
        }
    }
    if (pos != text.size()) {
        return false;
    }

    outBytes = static_cast<std::uintmax_t>(std::llround(value * static_cast<double>(multiplier)));
    return true;
}

} // namespace maccleaner
