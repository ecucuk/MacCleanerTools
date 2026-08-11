#pragma once

#include <cstdint>
#include <string>

namespace maccleaner {

// "1.3 GB", "824 KB", etc. Uses 1024-based (KiB/MiB/...) magnitudes but
// labels them KB/MB/GB to match what Finder and `du` show on macOS, since
// this tool's output is meant to be read next to those.
std::string humanReadableBytes(std::uintmax_t bytes);

} // namespace maccleaner
