#include "maccleaner/organizer.hpp"

#include "maccleaner/safety.hpp"
#include "maccleaner/walk.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <fstream>
#include <map>
#include <sstream>
#include <thread>
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

GeoCell cellOf(GeoPoint point) {
    return {static_cast<int>(std::floor(point.latitude / kGeoCellDegrees)),
            static_cast<int>(std::floor(point.longitude / kGeoCellDegrees))};
}

GeoPoint cellCenter(GeoCell cell) {
    return {(cell.lat + 0.5) * kGeoCellDegrees, (cell.lon + 0.5) * kGeoCellDegrees};
}

std::string folderName(std::string_view raw, std::string_view fallback) {
    std::string name(raw);
    std::replace(name.begin(), name.end(), '/', '-');
    std::replace(name.begin(), name.end(), ':', '-');
    const auto first = name.find_first_not_of(' ');
    if (first == std::string::npos) {
        return std::string(fallback);
    }
    name = name.substr(first, name.find_last_not_of(' ') - first + 1);
    return name == "." || name == ".." ? std::string(fallback) : name;
}

namespace {

// ASCII case folding: macOS volumes are case-insensitive by default, so
// "music/" is the Music folder and "IMG_1.JPG" collides with "img_1.jpg".
std::string folded(std::string text) {
    std::transform(text.begin(), text.end(), text.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return text;
}

std::string formatLocal(std::time_t time, const char* format) {
    std::tm local{};
    localtime_r(&time, &local);
    char buffer[16];
    return std::string(buffer, std::strftime(buffer, sizeof buffer, format, &local));
}

std::optional<fs::path> targetFolder(const FileMeta& file, const fs::path& dest, PhotoLayout layout) {
    fs::path folder = dest / kindName(file.kind);
    if (file.kind == Kind::Photos && layout == PhotoLayout::Content) {
        folder /= categoryName(file.category);
    } else if (file.kind == Kind::Photos) {
        if (file.location && !file.placeResolved) {
            return std::nullopt; // the lookup failed; a later run places it
        }
        const std::string country = folderName(file.country, "");
        folder = country.empty() ? folder / "Unknown Place"
                                 : folder / country / folderName(file.province, "Unknown Province") /
                                       folderName(file.city, "Unknown City");
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

std::vector<Move> planOrganize(const std::vector<FileMeta>& files, const fs::path& dest, const ExistsFn& exists,
                               PhotoLayout layout) {
    // A sidecar (.xmp/.aae/.thm) or a Live Photo video belongs to the photo
    // (or, for a sidecar, the video) with the same stem in the same folder:
    // it follows that file's folder and final name, so the pair stays linked.
    const auto key = [](const fs::path& path) { return folded((path.parent_path() / path.stem()).string()); };
    const auto isSidecar = [](const fs::path& path) {
        const std::string extension = folded(path.extension().string());
        return extension == ".xmp" || extension == ".aae" || extension == ".thm";
    };
    std::map<std::string, std::size_t> photoByKey, videoByKey;
    for (std::size_t i = 0; i < files.size(); ++i) {
        if (files[i].kind == Kind::Photos) {
            photoByKey.emplace(key(files[i].path), i);
        } else if (files[i].kind == Kind::Videos) {
            videoByKey.emplace(key(files[i].path), i);
        }
    }
    std::vector<std::optional<std::size_t>> partner(files.size());
    for (std::size_t i = 0; i < files.size(); ++i) {
        const auto photo = photoByKey.find(key(files[i].path));
        const auto video = videoByKey.find(key(files[i].path));
        if (isSidecar(files[i].path)) {
            if (photo != photoByKey.end()) {
                partner[i] = photo->second;
            } else if (video != videoByKey.end()) {
                partner[i] = video->second;
            }
        } else if (files[i].kind == Kind::Videos && photo != photoByKey.end()) {
            partner[i] = photo->second;
        }
    }

    std::vector<Move> moves;
    std::set<std::string> taken; // folded target paths
    std::vector<std::optional<fs::path>> placedAt(files.size()); // target of each moved file
    const auto place = [&](std::size_t i, const fs::path& folder, const std::string& stem) {
        const FileMeta& file = files[i];
        const std::string extension = file.path.extension().string();
        fs::path target = folder / (stem + extension);
        if (folded(target.string()) == folded(file.path.string())) {
            return; // already in place (maybe in another letter case)
        }
        for (int n = 2; taken.count(folded(target.string())) != 0 || exists(target); ++n) {
            target = folder / (stem + " (" + std::to_string(n) + ")" + extension);
        }
        taken.insert(folded(target.string()));
        placedAt[i] = target;
        moves.push_back({file.path, target});
    };
    for (int pass = 0; pass < 2; ++pass) {
        for (std::size_t i = 0; i < files.size(); ++i) {
            const bool follows = partner[i] && placedAt[*partner[i]];
            if (pass == 0 ? partner[i].has_value() : !partner[i].has_value()) {
                continue;
            }
            if (follows) {
                const fs::path& lead = *placedAt[*partner[i]];
                place(i, lead.parent_path(), lead.stem().string());
            } else if (const std::optional<fs::path> folder = targetFolder(files[i], dest, layout)) {
                place(i, *folder, files[i].path.stem().string());
            }
        }
    }
    return moves;
}

std::size_t countWaitingForPlace(const std::vector<FileMeta>& files) {
    return static_cast<std::size_t>(std::count_if(files.begin(), files.end(), [](const FileMeta& file) {
        return file.kind == Kind::Photos && file.location && !file.placeResolved;
    }));
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
            if (folded(name) == folded(kindName(kind))) {
                return true;
            }
        }
        return false;
    };
    const auto enterDir = [&](const fs::path& dir) {
        const std::string name = dir.filename().string();
        // Packages (apps, iMovie / Lightroom libraries, Keynote decks, ...)
        // stay whole: moving the files inside them out breaks them.
        static const std::set<std::string> kPackages = {
            ".app", ".photoslibrary", ".photolibrary", ".aplibrary", ".imovielibrary", ".fcpbundle", ".band",
            ".logicx", ".lrdata", ".rtfd", ".pages", ".key", ".numbers", ".bundle", ".framework", ".plugin",
            ".musiclibrary", ".tvlibrary", ".sparsebundle", ".xcodeproj", ".xcworkspace",
        };
        const bool isBundle = kPackages.count(folded(dir.extension().string())) != 0 || isPackageDirectory(dir);
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
            FileMeta meta;
            meta.path = path;
            meta.kind = kindFromPath(path);
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

namespace {

// Tabs and newlines would break the TSV cache.
std::string cacheField(std::string text) {
    std::replace_if(text.begin(), text.end(), [](char c) { return c == '\t' || c == '\n' || c == '\r'; }, ' ');
    return text;
}

} // namespace

void resolvePlaces(std::vector<FileMeta>& files, const fs::path& cacheFile, const std::atomic<bool>* cancelled,
                   const std::function<void(std::size_t done, std::size_t total)>& progress, const GeocodeFn& geocode,
                   const SleepFn& sleep) {
    const SleepFn sleepFor = sleep ? sleep : SleepFn([](std::chrono::milliseconds ms) { std::this_thread::sleep_for(ms); });
    const auto isCancelled = [&] { return cancelled != nullptr && cancelled->load(); };
    // Waits in short steps so Cancel never sits out a 60 s throttle pause.
    const auto pause = [&](std::chrono::milliseconds total) {
        for (auto left = total; left.count() > 0 && !isCancelled(); left -= std::chrono::milliseconds(500)) {
            sleepFor(std::min(left, std::chrono::milliseconds(500)));
        }
    };
    std::map<GeoCell, Place> known;
    {
        std::ifstream in(cacheFile);
        std::string line;
        while (std::getline(in, line)) {
            std::istringstream fields(line);
            std::string lat, lon;
            Place place;
            if (std::getline(fields, lat, '\t') && std::getline(fields, lon, '\t') &&
                std::getline(fields, place.country, '\t') && std::getline(fields, place.province, '\t')) {
                std::getline(fields, place.city); // empty for a NotFound cell
                try {
                    known[{std::stoi(lat), std::stoi(lon)}] = place;
                } catch (const std::exception&) {
                    // A damaged line is just looked up again.
                }
            }
        }
    }

    std::vector<GeoCell> missing;
    for (const FileMeta& file : files) {
        if (file.location) {
            const GeoCell cell = cellOf(*file.location);
            if (known.count(cell) == 0 && std::find(missing.begin(), missing.end(), cell) == missing.end()) {
                missing.push_back(cell);
            }
        }
    }

    std::error_code ec;
    fs::create_directories(cacheFile.parent_path(), ec);
    std::ofstream out(cacheFile, std::ios::app);
    for (std::size_t i = 0; i < missing.size(); ++i) {
        if (cancelled != nullptr && cancelled->load()) {
            break;
        }
        if (i > 0) {
            pause(std::chrono::milliseconds(1200));
        }
        Place place;
        GeocodeStatus status = geocode(cellCenter(missing[i]), place);
        if (status == GeocodeStatus::Throttled && !isCancelled()) {
            pause(std::chrono::milliseconds(60000));
        }
        if (status == GeocodeStatus::Throttled && !isCancelled()) {
            place = {};
            status = geocode(cellCenter(missing[i]), place);
        }
        if (status == GeocodeStatus::Found || status == GeocodeStatus::NotFound) {
            if (status == GeocodeStatus::NotFound) {
                place = {};
            }
            place = {cacheField(place.country), cacheField(place.province), cacheField(place.city)};
            known[missing[i]] = place;
            out << missing[i].lat << '\t' << missing[i].lon << '\t' << place.country << '\t' << place.province << '\t'
                << place.city << '\n';
            out.flush();
        }
        if (progress) {
            progress(i + 1, missing.size());
        }
    }

    for (FileMeta& file : files) {
        if (file.location) {
            const auto found = known.find(cellOf(*file.location));
            if (found != known.end()) {
                file.country = found->second.country;
                file.province = found->second.province;
                file.placeResolved = true;
                file.city = found->second.city;
            }
        }
    }
}

} // namespace maccleaner::organizer
