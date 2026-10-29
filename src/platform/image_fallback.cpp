// Non-Apple fallback. There is no image decoder in the standard library, so
// the photo folder scan finds nothing to analyse; it exists so the core
// library and its tests build on Linux/CI. macOS uses image_mac.mm.

#include "maccleaner/photos.hpp"

namespace maccleaner::photos {

bool decodeImageFile(const std::filesystem::path&, Decoded&) {
    return false;
}

bool isSolidStateVolume(const std::filesystem::path&) {
    return false;
}

bool writeHeicCopy(const std::filesystem::path&, const std::filesystem::path&, double, std::string& error) {
    error = "HEIC encoding needs macOS";
    return false;
}

} // namespace maccleaner::photos
