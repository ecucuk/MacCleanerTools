#include "maccleaner/photos.hpp"

#include "maccleaner/safety.hpp"
#include "maccleaner/walk.hpp"

#include <algorithm>
#include <bit>
#include <cctype>
#include <fcntl.h>
#include <unistd.h>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <fstream>
#include <iterator>
#include <map>
#include <mutex>
#include <numeric>
#include <set>
#include <thread>
#include <tuple>
#include <unordered_map>

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

namespace {

std::int64_t modifiedNs(const struct stat& st) {
#ifdef __APPLE__
    const struct timespec& mtime = st.st_mtimespec;
#else
    const struct timespec& mtime = st.st_mtim;
#endif
    return static_cast<std::int64_t>(mtime.tv_sec) * 1'000'000'000 + mtime.tv_nsec;
}

} // namespace

FolderScan scanPhotoFolder(const std::filesystem::path& root,
                           const std::atomic<bool>* cancelled,
                           const PhotoProgress& progress,
                           const DecodeFn& decode,
                           const std::vector<PhotoInfo>& previous) {
    // Decoding is ~all of the time (tens of ms per photo, more for large
    // HEIC), so workers decode while this thread walks. Results land in walk
    // order, so the output does not depend on thread timing.
    //
    // On a disk that is not known to be solid state, only one thread reads:
    // it pulls each file into the page cache in walk order, a short window
    // ahead of the workers, and workers decode only files already read.
    // Parallel reads made a USB hard disk seek between files (16.9k photos,
    // 43 GB: 1050 s, against 575 s with this). On an SSD the extra read cost
    // ~25% (12 GB set: 26 s -> 33 s), so there the reader only paces.
    struct Job {
        std::filesystem::path path;
        struct stat st;
        bool decoded = false; // already true for a file reused from `previous`
        PhotoInfo info;
    };
    std::unordered_map<std::string, const PhotoInfo*> known;
    for (const PhotoInfo& info : previous) {
        known.emplace(info.id, &info);
    }
    std::mutex mutex;
    std::condition_variable wake;
    std::deque<Job> jobs; // a deque keeps claimed jobs in place while the walk appends
    std::size_t next = 0;      // first job no worker has claimed
    std::size_t readAhead = 0; // jobs before this one are read (or reused)
    bool walkDone = false;
    const unsigned workerCount = std::max(1u, std::thread::hardware_concurrency());
    const std::size_t window = 2 * std::size_t{workerCount};
    const bool readAheadFromDisk = !isSolidStateVolume(root);
    FolderScan scan;
    std::uint64_t done = 0;

    auto isCancelled = [cancelled] { return cancelled != nullptr && cancelled->load(std::memory_order_relaxed); };
    auto readFiles = [&] {
        std::vector<char> buffer(std::size_t{1} << 20);
        std::unique_lock lock(mutex);
        for (;;) {
            wake.wait(lock, [&] {
                return isCancelled() || (readAhead < jobs.size() ? readAhead < next + window : walkDone);
            });
            if (isCancelled() || readAhead == jobs.size()) {
                wake.notify_all(); // workers waiting on this thread must see the end
                return;
            }
            const Job& job = jobs[readAhead];
            if (!job.decoded && readAheadFromDisk) {
                lock.unlock();
                const int fd = ::open(job.path.c_str(), O_RDONLY | O_CLOEXEC);
                if (fd >= 0) {
                    while (::read(fd, buffer.data(), buffer.size()) > 0) {
                    }
                    ::close(fd);
                }
                lock.lock();
            }
            ++readAhead;
            wake.notify_all();
        }
    };
    auto work = [&] {
        std::unique_lock lock(mutex);
        for (;;) {
            wake.wait(lock, [&] {
                return isCancelled() || next < readAhead || (walkDone && readAhead == jobs.size());
            });
            if (isCancelled() || next == jobs.size()) {
                wake.notify_all(); // the reader may wait for the window to move
                return;
            }
            Job& job = jobs[next++];
            const bool reused = job.decoded;
            wake.notify_all();
            lock.unlock();

            Decoded decoded;
            if (!reused) {
                job.decoded = decode(job.path, decoded);
            }
            if (!reused && job.decoded) {
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
                info.modifiedNs = modifiedNs(job.st);
            }

            lock.lock();
            if (!job.decoded) {
                ++scan.undecodable;
            } else if (progress) {
                progress(++done, job.path);
            }
        }
    };

    std::vector<std::thread> workers(workerCount);
    for (std::thread& worker : workers) {
        worker = std::thread(work);
    }
    std::thread reader(readFiles);
    walkFiles(
        root,
        [&](const std::filesystem::path& path, const struct stat& st) {
            if (!isPhotoExtension(path)) {
                return;
            }
            Job job{path, st, false, {}};
            const auto earlier = known.find(path.string());
            if (earlier != known.end() && earlier->second->sizeBytes == static_cast<std::uintmax_t>(st.st_size) &&
                earlier->second->modifiedNs == modifiedNs(st)) {
                job.decoded = true;
                job.info = *earlier->second;
            }
            {
                std::lock_guard lock(mutex);
                jobs.push_back(std::move(job));
            }
            wake.notify_all();
        },
        cancelled, {}, [](const std::filesystem::path& dir) { return !safety::isInsidePhotosLibrary(dir); });
    {
        std::lock_guard lock(mutex);
        walkDone = true;
    }
    wake.notify_all();
    reader.join();
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

namespace {

// Bump when the layout or the analysis (decode size, hash, sharpness) changes,
// so old caches are dropped instead of mixed with new results.
constexpr std::uint32_t kCacheMagic = 0x4D435048; // "MCPH"
constexpr std::uint32_t kCacheVersion = 1;

// Host byte order: the cache never leaves this Mac.
template <typename T>
void put(std::string& out, const T& value) {
    out.append(reinterpret_cast<const char*>(&value), sizeof value);
}

void putString(std::string& out, const std::string& value) {
    put(out, static_cast<std::uint32_t>(value.size()));
    out += value;
}

struct Reader {
    const std::string& data;
    std::size_t at = 0;

    template <typename T>
    bool get(T& value) {
        if (data.size() - at < sizeof value) {
            return false;
        }
        std::memcpy(&value, data.data() + at, sizeof value);
        at += sizeof value;
        return true;
    }

    bool getString(std::string& value) {
        std::uint32_t size = 0;
        if (!get(size) || data.size() - at < size) {
            return false;
        }
        value.assign(data, at, size);
        at += size;
        return true;
    }
};

} // namespace

bool savePhotoCache(const std::filesystem::path& file, const std::filesystem::path& root,
                    const std::vector<PhotoInfo>& photos) {
    std::string out;
    put(out, kCacheMagic);
    put(out, kCacheVersion);
    putString(out, root.string());
    put(out, static_cast<std::uint64_t>(photos.size()));
    for (const PhotoInfo& p : photos) {
        putString(out, p.id);
        put(out, p.hash);
        put(out, p.sharpness);
        put(out, static_cast<std::int32_t>(p.pixelWidth));
        put(out, static_cast<std::int32_t>(p.pixelHeight));
        put(out, p.createdUnix);
        put(out, static_cast<std::uint64_t>(p.sizeBytes));
        put(out, p.modifiedNs);
    }

    std::filesystem::path temp = file;
    temp += ".tmp";
    {
        std::ofstream stream(temp, std::ios::binary | std::ios::trunc);
        stream.write(out.data(), static_cast<std::streamsize>(out.size()));
        if (!stream.flush()) {
            return false;
        }
    }
    std::error_code ec;
    std::filesystem::rename(temp, file, ec);
    return !ec;
}

bool loadPhotoCache(const std::filesystem::path& file, const std::filesystem::path& root,
                    std::vector<PhotoInfo>& photos) {
    photos.clear();
    std::ifstream stream(file, std::ios::binary);
    if (!stream) {
        return false;
    }
    const std::string data((std::istreambuf_iterator<char>(stream)), std::istreambuf_iterator<char>());

    Reader in{data};
    std::uint32_t magic = 0;
    std::uint32_t version = 0;
    std::string savedRoot;
    std::uint64_t count = 0;
    if (!in.get(magic) || magic != kCacheMagic || !in.get(version) || version != kCacheVersion ||
        !in.getString(savedRoot) || savedRoot != root.string() || !in.get(count)) {
        return false;
    }
    std::vector<PhotoInfo> loaded;
    for (std::uint64_t i = 0; i < count; ++i) {
        PhotoInfo p;
        std::int32_t width = 0;
        std::int32_t height = 0;
        std::uint64_t size = 0;
        if (!in.getString(p.id) || !in.get(p.hash) || !in.get(p.sharpness) || !in.get(width) ||
            !in.get(height) || !in.get(p.createdUnix) || !in.get(size) || !in.get(p.modifiedNs)) {
            return false; // truncated: a count larger than the data never allocates past it
        }
        p.pixelWidth = width;
        p.pixelHeight = height;
        p.sizeBytes = size;
        loaded.push_back(std::move(p));
    }
    if (in.at != data.size()) {
        return false;
    }
    photos = std::move(loaded);
    return true;
}

} // namespace maccleaner::photos
