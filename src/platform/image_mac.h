// Shared by the ImageIO folder decoder and the GUI's PhotoKit source, so
// both feed the core exactly the same grayscale pixels.

#pragma once

#include "maccleaner/photos.hpp"

#include <CoreGraphics/CoreGraphics.h>

namespace maccleaner::photos {

// Draws `image` into an 8-bit DeviceGray buffer at its own size. Returns
// false if the bitmap context cannot be created.
bool grayFromCGImage(CGImageRef image, GrayImage& out);

} // namespace maccleaner::photos
