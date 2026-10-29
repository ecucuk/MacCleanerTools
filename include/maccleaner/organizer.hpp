#pragma once

#include <cstdint>
#include <ctime>
#include <filesystem>
#include <functional>
#include <optional>
#include <string>
#include <vector>

namespace maccleaner::organizer {

// Top-level folder a file is sorted into, by extension.
enum class Kind : std::uint8_t { Photos, Videos, Music, Documents, Other };

const char* kindName(Kind kind);
// Case-insensitive extension lookup; no extension (or an unknown one) is Other.
Kind kindFromPath(const std::filesystem::path& path);

// Content folder under Photos/, from Vision labels.
enum class PhotoCategory : std::uint8_t { Other, Screenshots, Documents, People, Animals, Food, Vehicles, Buildings, Nature };

const char* categoryName(PhotoCategory category);

struct Label {
    std::string identifier;
    float confidence;
};

// Vision labels below this confidence are ignored.
constexpr float kMinLabelConfidence = 0.5f;

// First category in precedence order (Screenshots, Documents, People, ...)
// with a matching label at kMinLabelConfidence or more; else Other.
PhotoCategory categoryFromLabels(const std::vector<Label>& labels);

struct FileMeta {
    std::filesystem::path path;
    Kind kind = Kind::Other;
    std::optional<std::time_t> date; // capture date, or birth time when metadata has none
    PhotoCategory category = PhotoCategory::Other;
};

struct Move {
    std::filesystem::path from;
    std::filesystem::path to;
};

using ExistsFn = std::function<bool(const std::filesystem::path& path)>;

// Target of every file under `dest`:
//   Photos/<Category>/YYYY/YYYY-MM/<name>, Videos/YYYY/YYYY-MM/<name>,
//   Music/<name>, Documents/<name>, Other/<name>  (dates in local time).
// A file already at its target is left out, so a second run plans nothing.
// Photos and videos without a date are left out. No two moves share a
// target and no target `exists`: later files get "name (2).ext", "(3)", ...
std::vector<Move> planOrganize(const std::vector<FileMeta>& files, const std::filesystem::path& dest,
                               const ExistsFn& exists);

} // namespace maccleaner::organizer
