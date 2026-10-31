#include "maccleaner/updater.hpp"

#include "maccleaner/json.hpp"

#include <algorithm>
#include <cctype>
#include <sstream>

namespace maccleaner::updater {

std::string toString(Source source) {
    switch (source) {
        case Source::Homebrew: return "Homebrew";
        case Source::MacPorts: return "MacPorts";
        case Source::AppStore: return "App Store";
        case Source::Sparkle: return "Sparkle";
    }
    return "?";
}

namespace {

struct VersionPart {
    bool numeric = true;
    std::string text;
};

std::vector<VersionPart> splitVersion(std::string_view v) {
    std::vector<VersionPart> parts;
    std::size_t i = 0;
    while (i < v.size()) {
        const auto c = static_cast<unsigned char>(v[i]);
        if (!std::isalnum(c)) {
            ++i;
            continue;
        }
        VersionPart part;
        part.numeric = std::isdigit(c) != 0;
        while (i < v.size() && std::isalnum(static_cast<unsigned char>(v[i])) &&
               (std::isdigit(static_cast<unsigned char>(v[i])) != 0) == part.numeric) {
            part.text += static_cast<char>(std::tolower(static_cast<unsigned char>(v[i])));
            ++i;
        }
        if (part.numeric) {
            // Compare digit strings by length then lexically: no integer overflow.
            const auto nz = part.text.find_first_not_of('0');
            part.text = nz == std::string::npos ? "0" : part.text.substr(nz);
        }
        parts.push_back(std::move(part));
    }
    return parts;
}

int comparePart(const VersionPart& a, const VersionPart& b) {
    if (a.numeric != b.numeric) {
        return a.numeric ? 1 : -1;
    }
    if (a.numeric && a.text.size() != b.text.size()) {
        return a.text.size() < b.text.size() ? -1 : 1;
    }
    return a.text.compare(b.text) < 0 ? -1 : (a.text == b.text ? 0 : 1);
}

// brew can print warnings before the JSON. The document starts at a line
// that begins with '{'.
std::optional<json::Value> parseJsonAfterNoise(std::string_view output) {
    for (std::size_t pos = 0; pos < output.size();) {
        if (output[pos] == '{') {
            if (auto v = json::parse(output.substr(pos)); v && v->type == json::Value::Type::Object) {
                return v;
            }
        }
        const auto nl = output.find('\n', pos);
        if (nl == std::string_view::npos) {
            break;
        }
        pos = nl + 1;
    }
    return std::nullopt;
}

// Value of `name` in an XML block: the attribute name="..." or the element
// <name>...</name>. "" if neither is there.
std::string xmlValue(std::string_view block, std::string_view name) {
    const std::string attr = std::string(name) + "=\"";
    if (auto p = block.find(attr); p != std::string_view::npos) {
        p += attr.size();
        const auto end = block.find('"', p);
        if (end != std::string_view::npos) {
            return std::string(block.substr(p, end - p));
        }
    }
    const std::string open = "<" + std::string(name) + ">";
    if (auto p = block.find(open); p != std::string_view::npos) {
        p += open.size();
        const auto end = block.find('<', p);
        if (end != std::string_view::npos) {
            return std::string(block.substr(p, end - p));
        }
    }
    return {};
}

} // namespace

int compareVersions(std::string_view a, std::string_view b) {
    const auto pa = splitVersion(a);
    const auto pb = splitVersion(b);
    const VersionPart zero{true, "0"};
    for (std::size_t i = 0; i < std::max(pa.size(), pb.size()); ++i) {
        const VersionPart& x = i < pa.size() ? pa[i] : zero;
        const VersionPart& y = i < pb.size() ? pb[i] : zero;
        if (const int c = comparePart(x, y); c != 0) {
            return c;
        }
    }
    return 0;
}

std::vector<OutdatedItem> parseBrewOutdated(std::string_view output) {
    std::vector<OutdatedItem> items;
    const auto doc = parseJsonAfterNoise(output);
    if (!doc) {
        return items;
    }
    for (const char* key : {"formulae", "casks"}) {
        const json::Value* list = doc->find(key);
        if (!list || list->type != json::Value::Type::Array) {
            continue;
        }
        for (const auto& entry : list->array) {
            OutdatedItem item;
            item.source = Source::Homebrew;
            item.name = entry.str("name");
            item.latestVersion = entry.str("current_version");
            if (const json::Value* installed = entry.find("installed_versions");
                installed && !installed->array.empty()) {
                item.installedVersion = installed->array.back().string;
            }
            if (const json::Value* pinned = entry.find("pinned")) {
                item.pinned = pinned->boolean;
            }
            item.isCask = std::string_view(key) == "casks";
            if (!item.name.empty()) {
                items.push_back(std::move(item));
            }
        }
    }
    return items;
}

std::set<std::string> parseBrewCaskApps(std::string_view output) {
    std::set<std::string> apps;
    const auto doc = parseJsonAfterNoise(output);
    const json::Value* casks = doc ? doc->find("casks") : nullptr;
    if (!casks) {
        return apps;
    }
    for (const auto& cask : casks->array) {
        const json::Value* artifacts = cask.find("artifacts");
        if (!artifacts) {
            continue;
        }
        for (const auto& artifact : artifacts->array) {
            if (const json::Value* app = artifact.find("app")) {
                for (const auto& name : app->array) {
                    if (name.type == json::Value::Type::String) {
                        apps.insert(name.string);
                    }
                }
            }
        }
    }
    return apps;
}

std::vector<OutdatedItem> parsePortOutdated(std::string_view output) {
    std::vector<OutdatedItem> items;
    std::istringstream lines{std::string(output)};
    std::string line;
    while (std::getline(lines, line)) {
        std::istringstream fields(line);
        OutdatedItem item;
        std::string op;
        if (fields >> item.name >> item.installedVersion >> op >> item.latestVersion && op == "<") {
            item.source = Source::MacPorts;
            items.push_back(std::move(item));
        }
    }
    return items;
}

std::map<std::string, std::string> parseItunesLookup(std::string_view text) {
    std::map<std::string, std::string> versions;
    const auto doc = json::parse(text);
    const json::Value* results = doc ? doc->find("results") : nullptr;
    if (!results) {
        return versions;
    }
    for (const auto& r : results->array) {
        const json::Value* id = r.find("trackId");
        const std::string version = r.str("version");
        if (id && id->type == json::Value::Type::Number && !version.empty()) {
            versions[std::to_string(static_cast<long long>(id->number))] = version;
        }
    }
    return versions;
}

std::optional<AppcastLatest> parseAppcast(std::string_view xml) {
    std::optional<AppcastLatest> best;
    for (std::size_t pos = xml.find("<item"); pos != std::string_view::npos; pos = xml.find("<item", pos)) {
        const auto end = xml.find("</item>", pos);
        if (end == std::string_view::npos) {
            break;
        }
        const std::string_view item = xml.substr(pos, end - pos);
        pos = end;
        if (item.find("<sparkle:channel") != std::string_view::npos) {
            continue;
        }
        AppcastLatest candidate{xmlValue(item, "sparkle:version"), xmlValue(item, "sparkle:shortVersionString")};
        if (candidate.version.empty()) {
            continue;
        }
        if (!best || compareVersions(candidate.version, best->version) > 0) {
            best = std::move(candidate);
        }
    }
    return best;
}

} // namespace maccleaner::updater
