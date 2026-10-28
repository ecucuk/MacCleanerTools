#include "maccleaner/photos.hpp"

#include "maccleaner/safety.hpp"
#include "maccleaner/walk.hpp"

#include <algorithm>
#include <bit>
#include <cctype>
#include <condition_variable>
#include <deque>
#include <map>
#include <mutex>
#include <numeric>
#include <set>
#include <thread>
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

namespace {

// Narrowest chunk for which multi-index hashing beats the pair scan (measured
// at 100k random hashes: 5 bits, tolerance 11, is 1.0 s against 1.5 s; 4 bits
// is a draw). A b-bit chunk matches ~1/2^b of random pairs.
constexpr int kMinChunkBits = 5;

} // namespace

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

    // Hash 0 means "no structure" (too small to hash, or flat): such photos
    // would all match each other, so they are never grouped. The hashes go
    // in one contiguous array; PhotoInfo strides would thrash the cache.
    std::vector<std::size_t> index;
    std::vector<std::uint64_t> hashes;
    for (std::size_t i = 0; i < photos.size(); ++i) {
        if (photos[i].hash != 0) {
            index.push_back(i);
            hashes.push_back(photos[i].hash);
        }
    }
    auto link = [&](std::size_t a, std::size_t b) {
        if (hammingDistance(hashes[a], hashes[b]) <= maxDistance) {
            parent[find(index[a])] = find(index[b]);
        }
    };

    // Multi-index hashing: cut the 64 bits into maxDistance + 1 chunks. Two
    // hashes within maxDistance differ in at most maxDistance chunks, so they
    // agree exactly on at least one (pigeonhole). Sorting by each chunk puts
    // every candidate pair in a run of equal values; only runs are compared.
    // Each chunk costs a sort, and narrow chunks give runs too long to pay
    // off, so wide tolerances use the plain pair scan instead.
    if (maxDistance >= 0 && maxDistance < 64 / kMinChunkBits) {
        const int chunks = maxDistance + 1;
        std::vector<std::pair<std::uint64_t, std::size_t>> keys(hashes.size());
        for (int c = 0; c < chunks; ++c) {
            const int lo = c * 64 / chunks;
            const int bits = (c + 1) * 64 / chunks - lo;
            const std::uint64_t mask = bits == 64 ? ~std::uint64_t{0} : (std::uint64_t{1} << bits) - 1;
            for (std::size_t i = 0; i < hashes.size(); ++i) {
                keys[i] = {(hashes[i] >> lo) & mask, i};
            }
            std::sort(keys.begin(), keys.end());
            for (std::size_t begin = 0, end = 0; begin < keys.size(); begin = end) {
                while (end < keys.size() && keys[end].first == keys[begin].first) {
                    ++end;
                }
                for (std::size_t a = begin; a < end; ++a) {
                    for (std::size_t b = a + 1; b < end; ++b) {
                        link(keys[a].second, keys[b].second);
                    }
                }
            }
        }
    } else {
        for (std::size_t a = 0; a < hashes.size(); ++a) {
            for (std::size_t b = a + 1; b < hashes.size(); ++b) {
                link(a, b);
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
    // Decoding is ~all of the time (tens of ms per photo, more for large
    // HEIC), so workers decode while this thread walks. Results land in walk
    // order, so the output does not depend on thread timing.
    struct Job {
        std::filesystem::path path;
        struct stat st;
        bool decoded = false;
        PhotoInfo info;
    };
    std::mutex mutex;
    std::condition_variable wake;
    std::deque<Job> jobs; // a deque keeps claimed jobs in place while the walk appends
    std::size_t next = 0;
    bool walkDone = false;
    FolderScan scan;
    std::uint64_t done = 0;

    auto isCancelled = [cancelled] { return cancelled != nullptr && cancelled->load(std::memory_order_relaxed); };
    auto work = [&] {
        std::unique_lock lock(mutex);
        for (;;) {
            wake.wait(lock, [&] { return next < jobs.size() || walkDone; });
            if (next == jobs.size() || isCancelled()) {
                return;
            }
            Job& job = jobs[next++];
            lock.unlock();

            Decoded decoded;
            job.decoded = decode(job.path, decoded);
            if (job.decoded) {
                PhotoInfo& info = job.info;
                info.id = job.path.string();
                info.hash = dHash(decoded.gray);
                info.sharpness = sharpness(decoded.gray);
                info.pixelWidth = decoded.pixelWidth;
                info.pixelHeight = decoded.pixelHeight;
                info.createdUnix = decoded.createdUnix;
#ifdef __APPLE__
                if (info.createdUnix == 0) {
                    info.createdUnix = job.st.st_birthtimespec.tv_sec;
                }
#endif
                info.sizeBytes = static_cast<std::uintmax_t>(job.st.st_size);
            }

            lock.lock();
            if (!job.decoded) {
                ++scan.undecodable;
            } else if (progress) {
                progress(++done, job.path);
            }
        }
    };

    std::vector<std::thread> workers(std::max(1u, std::thread::hardware_concurrency()));
    for (std::thread& worker : workers) {
        worker = std::thread(work);
    }
    walkFiles(
        root,
        [&](const std::filesystem::path& path, const struct stat& st) {
            if (!isPhotoExtension(path)) {
                return;
            }
            {
                std::lock_guard lock(mutex);
                jobs.push_back(Job{path, st, false, {}});
            }
            wake.notify_one();
        },
        cancelled, {}, [](const std::filesystem::path& dir) { return !safety::isInsidePhotosLibrary(dir); });
    {
        std::lock_guard lock(mutex);
        walkDone = true;
    }
    wake.notify_all();
    for (std::thread& worker : workers) {
        worker.join();
    }

    for (Job& job : jobs) {
        if (job.decoded) {
            scan.photos.push_back(std::move(job.info));
        }
    }
    return scan;
}

} // namespace maccleaner::photos
