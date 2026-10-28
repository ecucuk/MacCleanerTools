#include "maccleaner/photos.hpp"

#include "maccleaner/safety.hpp"
#include "maccleaner/walk.hpp"

#include <algorithm>
#include <bit>
#include <cctype>
#include <map>
#include <set>
#include <numeric>
#include <tuple>

namespace maccleaner::photos {

std::uint64_t dHash(const GrayImage& image) {
    constexpr int kCols = 9;
    constexpr int kRows = 8;
    if (image.width < kCols || image.height < kRows ||
        image.pixels.size() < static_cast<std::size_t>(image.width) * static_cast<std::size_t>(image.height)) {
        return 0;
    }

    double cells[kRows][kCols] = {};
    for (int r = 0; r < kRows; ++r) {
        const int y0 = r * image.height / kRows;
        const int y1 = (r + 1) * image.height / kRows;
        for (int c = 0; c < kCols; ++c) {
            const int x0 = c * image.width / kCols;
            const int x1 = (c + 1) * image.width / kCols;
            std::uint64_t sum = 0;
            for (int y = y0; y < y1; ++y) {
                const std::uint8_t* row = image.pixels.data() + static_cast<std::size_t>(y) * static_cast<std::size_t>(image.width);
                for (int x = x0; x < x1; ++x) {
                    sum += row[x];
                }
            }
            cells[r][c] = static_cast<double>(sum) / static_cast<double>((y1 - y0) * (x1 - x0));
        }
    }

    std::uint64_t hash = 0;
    for (int r = 0; r < kRows; ++r) {
        for (int c = 0; c + 1 < kCols; ++c) {
            if (cells[r][c] > cells[r][c + 1]) {
                hash |= std::uint64_t{1} << (r * 8 + c);
            }
        }
    }
    return hash;
}

int hammingDistance(std::uint64_t a, std::uint64_t b) {
    return std::popcount(a ^ b);
}

double sharpness(const GrayImage& image) {
    const int w = image.width;
    const int h = image.height;
    if (w < 3 || h < 3 || image.pixels.size() < static_cast<std::size_t>(w) * static_cast<std::size_t>(h)) {
        return 0;
    }

    auto at = [&](int x, int y) { return static_cast<double>(image.pixels[static_cast<std::size_t>(y * w + x)]); };

    double sum = 0;
    double sumSquares = 0;
    for (int y = 1; y + 1 < h; ++y) {
        for (int x = 1; x + 1 < w; ++x) {
            const double laplacian = 4 * at(x, y) - at(x - 1, y) - at(x + 1, y) - at(x, y - 1) - at(x, y + 1);
            sum += laplacian;
            sumSquares += laplacian * laplacian;
        }
    }
    const double n = static_cast<double>(w - 2) * static_cast<double>(h - 2);
    const double mean = sum / n;
    return sumSquares / n - mean * mean;
}

std::vector<std::vector<std::size_t>> groupDuplicates(const std::vector<PhotoInfo>& photos, int maxDistance) {
    std::vector<std::size_t> parent(photos.size());
    std::iota(parent.begin(), parent.end(), std::size_t{0});
    auto find = [&](std::size_t i) {
        while (parent[i] != i) {
            parent[i] = parent[parent[i]];
            i = parent[i];
        }
        return i;
    };

    // shortcut: O(n^2) pair scan (~50M popcounts at 10k photos, well under a
    // second); switch to a BK-tree or multi-index hashing above ~50k photos.
    for (std::size_t i = 0; i < photos.size(); ++i) {
        for (std::size_t j = i + 1; j < photos.size(); ++j) {
            if (hammingDistance(photos[i].hash, photos[j].hash) <= maxDistance) {
                parent[find(i)] = find(j);
            }
        }
    }

    std::map<std::size_t, std::vector<std::size_t>> byRoot;
    for (std::size_t i = 0; i < photos.size(); ++i) {
        byRoot[find(i)].push_back(i);
    }

    // Unknown dates (0) rank as newest so a dated original wins over them.
    auto keepKey = [&](std::size_t i) {
        const PhotoInfo& p = photos[i];
        const std::int64_t created = p.createdUnix != 0 ? p.createdUnix : INT64_MAX;
        return std::tuple<std::int64_t, double, std::int64_t, const std::string&>(
            -static_cast<std::int64_t>(p.pixelWidth) * p.pixelHeight, -p.sharpness, created, p.id);
    };

    std::vector<std::vector<std::size_t>> groups;
    for (auto& [root, members] : byRoot) {
        if (members.size() < 2) {
            continue;
        }
        std::sort(members.begin(), members.end(),
                  [&](std::size_t a, std::size_t b) { return keepKey(a) < keepKey(b); });
        groups.push_back(std::move(members));
    }
    std::sort(groups.begin(), groups.end(),
              [&](const auto& a, const auto& b) { return photos[a[0]].id < photos[b[0]].id; });
    return groups;
}

bool isPhotoExtension(const std::filesystem::path& path) {
    static const std::set<std::string> kExtensions = {
        ".jpg", ".jpeg", ".heic", ".heif", ".png", ".tif", ".tiff", ".webp",
        ".dng", ".cr2", ".cr3", ".nef", ".arw", ".raf", ".orf", ".rw2",
    };
    std::string extension = path.extension().string();
    std::transform(extension.begin(), extension.end(), extension.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return kExtensions.count(extension) != 0;
}

FolderScan scanPhotoFolder(const std::filesystem::path& root,
                           const std::atomic<bool>* cancelled,
                           const PhotoProgress& progress,
                           const DecodeFn& decode) {
    FolderScan scan;
    std::uint64_t done = 0;
    walkFiles(
        root,
        [&](const std::filesystem::path& path, const struct stat& st) {
            if (!isPhotoExtension(path)) {
                return;
            }
            Decoded decoded;
            if (!decode(path, decoded)) {
                ++scan.undecodable;
                return;
            }
            PhotoInfo info;
            info.id = path.string();
            info.hash = dHash(decoded.gray);
            info.sharpness = sharpness(decoded.gray);
            info.pixelWidth = decoded.pixelWidth;
            info.pixelHeight = decoded.pixelHeight;
            info.createdUnix = decoded.createdUnix;
#ifdef __APPLE__
            if (info.createdUnix == 0) {
                info.createdUnix = st.st_birthtimespec.tv_sec;
            }
#endif
            info.sizeBytes = static_cast<std::uintmax_t>(st.st_size);
            scan.photos.push_back(std::move(info));
            if (progress) {
                progress(++done, path);
            }
        },
        cancelled, {}, [](const std::filesystem::path& dir) { return !safety::isInsidePhotosLibrary(dir); });
    return scan;
}

} // namespace maccleaner::photos
