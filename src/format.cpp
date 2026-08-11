#include "maccleaner/format.hpp"

#include <array>
#include <cstdio>

namespace maccleaner {

std::string humanReadableBytes(std::uintmax_t bytes) {
    static constexpr std::array<const char*, 6> units{"B", "KB", "MB", "GB", "TB", "PB"};

    double value = static_cast<double>(bytes);
    std::size_t unitIndex = 0;
    while (value >= 1024.0 && unitIndex + 1 < units.size()) {
        value /= 1024.0;
        ++unitIndex;
    }

    std::array<char, 32> buffer{};
    const char* fmt = (unitIndex == 0) ? "%.0f %s" : "%.1f %s";
    std::snprintf(buffer.data(), buffer.size(), fmt, value, units[unitIndex]);
    return std::string(buffer.data());
}

} // namespace maccleaner
