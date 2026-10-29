#pragma once

#include <atomic>
#include <cstddef>
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

// Moves one file, creating the parent folders of `to`. Never replaces an
// existing `to`. Platform code: organizer_mac.mm / organizer_fallback.cpp.
bool moveFile(const std::filesystem::path& from, const std::filesystem::path& to, std::string* error);

// False (with a reason) for an empty destination, one inside a Photos
// library, or one at or under a hard-denylisted system path.
bool isValidDestination(const std::filesystem::path& dest, std::string* reason);

struct ApplyResult {
    std::size_t moved = 0;
    std::vector<std::string> problems; // "<path>: <reason>"
};

using ApplyProgress = std::function<void(std::size_t done, std::size_t total)>;

// Runs `moves` in order. A move takes the file away from `source`, so each
// `from` must pass safety::isSafeToDelete with `source` as the only allowed
// root. A refused or failed move becomes a problem and the rest go on.
// `cancelled` is checked before each move.
ApplyResult applyPlan(const std::vector<Move>& moves, const std::filesystem::path& source,
                      const std::atomic<bool>* cancelled = nullptr, const ApplyProgress& progress = {});

// Fills `date` (and `category`) of a photo, and `date` of a video, from the
// file's own metadata; other kinds and unreadable files are left as they
// are. Photos: EXIF DateTimeOriginal (else TIFF DateTime) and Vision on a
// 512 px thumbnail. Videos: AVFoundation creationDate. Platform code.
void readMetadata(FileMeta& meta);

using MetadataFn = std::function<void(FileMeta& meta)>;
using ScanProgress = std::function<void(std::size_t filesSeen)>;

// Every file under `source` that the organizer would place, with `read`
// applied and a missing date replaced by the file's birth time. Skips
// hidden files and folders, app bundles, Photos libraries, and the
// Photos/ Videos/ Music/ Documents/ Other/ folders directly under `dest`
// (already organized when `dest` is inside `source`).
std::vector<FileMeta> scanForOrganize(const std::filesystem::path& source, const std::filesystem::path& dest,
                                      const std::atomic<bool>* cancelled = nullptr, const ScanProgress& progress = {},
                                      const MetadataFn& read = readMetadata);

} // namespace maccleaner::organizer
