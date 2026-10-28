#include "maccleaner/bigfiles.hpp"
#include "maccleaner/walk.hpp"

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
                                   const BigFileProgress& progress,
                                   const BigFileResults& onResults) {
    std::vector<BigFile> results; // kept sorted descending; worst element last

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
        if (onResults) {
            onResults(results);
        }
    };

    walkFiles(
        options.root,
        [&](const fs::path& path, const struct stat& st) {
            const auto size = static_cast<std::uintmax_t>(st.st_size);
            if (size < options.minSizeBytes) {
                return;
            }
            BigFile found;
            found.path = path;
            found.sizeBytes = size;
            std::error_code timeEc;
            found.lastModified = fs::last_write_time(path, timeEc);
            offer(std::move(found));
        },
        cancelled, progress);

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
