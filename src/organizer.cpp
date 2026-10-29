#include "maccleaner/organizer.hpp"

#include "maccleaner/safety.hpp"
#include "maccleaner/walk.hpp"

#include <algorithm>
#include <cctype>
#include <set>
#include <string_view>

namespace maccleaner::organizer {

namespace fs = std::filesystem;

const char* kindName(Kind kind) {
    switch (kind) {
    case Kind::Photos: return "Photos";
    case Kind::Videos: return "Videos";
    case Kind::Music: return "Music";
    case Kind::Documents: return "Documents";
    case Kind::Other: return "Other";
    }
    return "Other";
}

Kind kindFromPath(const fs::path& path) {
    struct Entry {
        Kind kind;
        std::vector<std::string_view> extensions;
    };
    static const std::vector<Entry> kTable = {
        {Kind::Photos, {"jpg", "jpeg", "heic", "heif", "png", "gif", "tif", "tiff", "bmp", "webp", "dng", "cr2", "cr3",
                        "nef", "arw", "raf", "orf", "rw2"}},
        {Kind::Videos, {"mp4", "mov", "m4v", "avi", "mkv", "mts", "m2ts", "3gp", "wmv", "webm"}},
        {Kind::Music, {"mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "alac", "ogg", "opus", "wma"}},
        {Kind::Documents, {"pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "txt", "rtf",
                           "md", "csv", "odt"}},
    };
    std::string extension = path.extension().string();
    if (extension.empty()) {
        return Kind::Other;
    }
    extension.erase(0, 1);
    std::transform(extension.begin(), extension.end(), extension.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    for (const Entry& entry : kTable) {
        if (std::find(entry.extensions.begin(), entry.extensions.end(), extension) != entry.extensions.end()) {
            return entry.kind;
        }
    }
    return Kind::Other;
}

const char* categoryName(PhotoCategory category) {
    switch (category) {
    case PhotoCategory::Other: return "Other";
    case PhotoCategory::Screenshots: return "Screenshots";
    case PhotoCategory::Documents: return "Documents";
    case PhotoCategory::People: return "People";
    case PhotoCategory::Animals: return "Animals";
    case PhotoCategory::Food: return "Food";
    case PhotoCategory::Vehicles: return "Vehicles";
    case PhotoCategory::Buildings: return "Buildings";
    case PhotoCategory::Nature: return "Nature";
    }
    return "Other";
}

PhotoCategory categoryFromLabels(const std::vector<Label>& labels) {
    // Vision's taxonomy reports parents with their children ("animal" with
    // "dog"), so mostly top-level identifiers are enough. Checked on a real
    // 14k-photo library: everyday photos carry "people" or "outdoor".
    struct Rule {
        PhotoCategory category;
        std::vector<std::string_view> identifiers;
    };
    static const std::vector<Rule> kRules = {
        {PhotoCategory::Screenshots, {"screenshot"}},
        {PhotoCategory::Documents, {"document", "receipt", "handwriting"}},
        {PhotoCategory::People, {"people"}},
        {PhotoCategory::Animals, {"animal"}},
        {PhotoCategory::Food, {"food", "drink", "dessert"}},
        {PhotoCategory::Vehicles, {"vehicle", "aircraft", "watercraft", "train", "bicycle", "motorcycle"}},
        {PhotoCategory::Buildings, {"building", "cityscape"}},
        {PhotoCategory::Nature, {"outdoor", "plant", "sky", "land", "water_body", "mountain", "beach", "snow"}},
    };
    for (const Rule& rule : kRules) {
        for (const Label& label : labels) {
            if (label.confidence >= kMinLabelConfidence &&
                std::find(rule.identifiers.begin(), rule.identifiers.end(), label.identifier) !=
                    rule.identifiers.end()) {
                return rule.category;
            }
        }
    }
    return PhotoCategory::Other;
}

namespace {

std::string formatLocal(std::time_t time, const char* format) {
    std::tm local{};
    localtime_r(&time, &local);
    char buffer[16];
    return std::string(buffer, std::strftime(buffer, sizeof buffer, format, &local));
}

std::optional<fs::path> targetFolder(const FileMeta& file, const fs::path& dest) {
    fs::path folder = dest / kindName(file.kind);
    if (file.kind == Kind::Photos) {
        folder /= categoryName(file.category);
    }
    if (file.kind == Kind::Photos || file.kind == Kind::Videos) {
        if (!file.date) {
            return std::nullopt;
        }
        folder = folder / formatLocal(*file.date, "%Y") / formatLocal(*file.date, "%Y-%m");
    }
    return folder;
}

} // namespace

std::vector<Move> planOrganize(const std::vector<FileMeta>& files, const fs::path& dest, const ExistsFn& exists) {
    std::vector<Move> moves;
    std::set<fs::path> taken;
    for (const FileMeta& file : files) {
        const std::optional<fs::path> folder = targetFolder(file, dest);
        if (!folder) {
            continue;
        }
        fs::path target = *folder / file.path.filename();
        if (target == file.path) {
            continue;
        }
        const std::string stem = file.path.stem().string();
        const std::string extension = file.path.extension().string();
        for (int n = 2; taken.count(target) != 0 || exists(target); ++n) {
            target = *folder / (stem + " (" + std::to_string(n) + ")" + extension);
        }
        taken.insert(target);
        moves.push_back({file.path, target});
    }
    return moves;
}

bool isValidDestination(const fs::path& dest, std::string* reason) {
    const auto reject = [&](std::string why) {
        if (reason != nullptr) {
            *reason = std::move(why);
        }
        return false;
    };
    if (dest.empty()) {
        return reject("no destination folder");
    }
    if (safety::isInsidePhotosLibrary(dest)) {
        return reject("destination is inside a Photos library: " + dest.string());
    }
    std::error_code ec;
    const fs::path resolved = fs::weakly_canonical(dest, ec);
    const fs::path& checked = ec ? dest : resolved;
    for (const fs::path& denied : safety::hardDenylist()) {
        const auto [end, _] = std::mismatch(denied.begin(), denied.end(), checked.begin(), checked.end());
        if (end == denied.end()) {
            return reject("destination is protected: " + denied.string());
        }
    }
    return true;
}

ApplyResult applyPlan(const std::vector<Move>& moves, const fs::path& source, const std::atomic<bool>* cancelled,
                      const ApplyProgress& progress) {
    safety::AllowedRoots allowed;
    allowed.add(source);
    ApplyResult result;
    for (std::size_t i = 0; i < moves.size(); ++i) {
        if (cancelled != nullptr && cancelled->load()) {
            break;
        }
        const Move& move = moves[i];
        std::string reason;
        if (!safety::isSafeToDelete(move.from, allowed, &reason) || !moveFile(move.from, move.to, &reason)) {
            result.problems.push_back(move.from.string() + ": " + reason);
        } else {
            ++result.moved;
        }
        if (progress) {
            progress(i + 1, moves.size());
        }
    }
    return result;
}

std::vector<FileMeta> scanForOrganize(const fs::path& source, const fs::path& dest, const std::atomic<bool>* cancelled,
                                      const ScanProgress& progress, const MetadataFn& read) {
    std::error_code ec;
    const fs::path root = fs::weakly_canonical(source, ec);
    const fs::path destination = fs::weakly_canonical(dest, ec);
    const auto isKindFolder = [](const std::string& name) {
        for (Kind kind : {Kind::Photos, Kind::Videos, Kind::Music, Kind::Documents, Kind::Other}) {
            if (name == kindName(kind)) {
                return true;
            }
        }
        return false;
    };
    const auto enterDir = [&](const fs::path& dir) {
        const std::string name = dir.filename().string();
        const bool isBundle = dir.extension() == ".app";
        return !(name.empty() || name.front() == '.' || isBundle || safety::isInsidePhotosLibrary(dir) ||
                 (dir.parent_path() == destination && isKindFolder(name)));
    };
    std::vector<FileMeta> files;
    walkFiles(
        root,
        [&](const fs::path& path, const struct stat& st) {
            const std::string name = path.filename().string();
            if (name.empty() || name.front() == '.') {
                return;
            }
            FileMeta meta{path, kindFromPath(path), std::nullopt, PhotoCategory::Other};
            read(meta);
            if (!meta.date) {
#ifdef __APPLE__
                meta.date = st.st_birthtimespec.tv_sec;
#else
                meta.date = st.st_mtime;
#endif
            }
            files.push_back(std::move(meta));
            if (progress) {
                progress(files.size());
            }
        },
        cancelled, {}, enterDir);
    return files;
}

} // namespace maccleaner::organizer
