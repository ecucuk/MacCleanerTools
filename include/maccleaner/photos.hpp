#pragma once

#include <cstdint>
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
// more are returned. Element 0 of each group is the one to keep: largest
// pixel count, then sharpest, then oldest known creation date, then id.
// Groups are ordered by their keeper's id.
std::vector<std::vector<std::size_t>> groupDuplicates(const std::vector<PhotoInfo>& photos,
                                                      int maxDistance = kDefaultMaxDistance);

} // namespace maccleaner::photos
