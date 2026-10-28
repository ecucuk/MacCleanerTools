#pragma once

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <string>
#include <vector>

namespace maccleaner::photos {

// 8-bit grayscale image, row-major, no padding. The analysis below never
// sees Core Graphics: ImageIO (folders) and PhotoKit (library) both decode
// into this, so the metrics stay platform-free and unit-testable.
struct GrayImage {
    int width = 0;
    int height = 0;
    std::vector<std::uint8_t> pixels;
};

// One analysed photo. `id` is a file path (folder source) or a PHAsset
// localIdentifier (Photos source). Pixel size is the original's, not the
// decoded thumbnail's.
struct PhotoInfo {
    std::string id;
    std::uint64_t hash = 0;
    double sharpness = 0;
    int pixelWidth = 0;
    int pixelHeight = 0;
    std::int64_t createdUnix = 0; // seconds; 0 = unknown, ranks as newest
    std::uintmax_t sizeBytes = 0;
};

// Hamming distance at or below which two photos count as duplicates.
constexpr int kDefaultMaxDistance = 6;
// Sharpness below which a photo counts as blurry (on a 512 px decode).
constexpr double kDefaultBlurThreshold = 100.0;

// Difference hash: box-averages the image down to 9x8 cells and sets bit
// (row*8 + col) when a cell is brighter than its right neighbour. Robust to
// rescaling, re-encoding and uniform brightness changes. 0 for images
// smaller than 9x8.
std::uint64_t dHash(const GrayImage& image);

int hammingDistance(std::uint64_t a, std::uint64_t b);

// Variance of the 4-neighbour Laplacian over the interior pixels. Edges give
// large responses, so a sharp image scores high and a blurry one low. The
// value depends on the decode size; compare scores from the same pipeline
// only. 0 for images smaller than 3x3.
double sharpness(const GrayImage& image);

// Groups photos whose hashes are within `maxDistance` of each other,
// transitively (A~B and B~C put A, B, C in one group). Only groups of two or
// more are returned. Photos with hash 0 (tiny or flat images, see dHash) are
// never grouped. Element 0 of each group is the one to keep: largest
// pixel count, then sharpest, then oldest known creation date, then id.
// Groups are ordered by their keeper's id.
std::vector<std::vector<std::size_t>> groupDuplicates(const std::vector<PhotoInfo>& photos,
                                                      int maxDistance = kDefaultMaxDistance);

// --- folder source ---------------------------------------------------------

// Longest edge of the grayscale decode that dHash and sharpness run on.
constexpr int kDecodeMaxPixels = 512;

struct Decoded {
    GrayImage gray;                // at most kDecodeMaxPixels on the long edge
    int pixelWidth = 0;            // original size
    int pixelHeight = 0;
    std::int64_t createdUnix = 0;  // EXIF capture date, 0 if absent
};

using DecodeFn = std::function<bool(const std::filesystem::path& path, Decoded& out)>;

// Platform decoder (ImageIO on macOS, EXIF orientation applied). Returns
// false for anything it cannot decode; the non-Apple fallback always does.
// Thread-safe, as every DecodeFn must be: scanPhotoFolder calls it from
// several threads at once.
bool decodeImageFile(const std::filesystem::path& path, Decoded& out);

// Case-insensitive check against the still-image formats ImageIO reads
// (JPEG, HEIF, PNG, TIFF, WebP and common camera RAW).
bool isPhotoExtension(const std::filesystem::path& path);

struct FolderScan {
    std::vector<PhotoInfo> photos;
    std::uint64_t undecodable = 0; // photo-named files the decoder rejected
};

using PhotoProgress = std::function<void(std::uint64_t done, const std::filesystem::path& current)>;

// Walks `root` with walkFiles (EPERM-tolerant, no symlinks), never entering
// a Photos library package, and analyses every file with a photo extension
// on one worker thread per core. Photos come back in walk order. The
// creation date falls back to the file's birth time when the image has no
// EXIF date. `progress` fires once per decoded file, from the workers but
// never two calls at once; `cancelled` stops the scan early with what it has
// so far.
FolderScan scanPhotoFolder(const std::filesystem::path& root,
                           const std::atomic<bool>* cancelled = nullptr,
                           const PhotoProgress& progress = {},
                           const DecodeFn& decode = decodeImageFile);

} // namespace maccleaner::photos
