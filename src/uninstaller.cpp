#include "maccleaner/uninstaller.hpp"

#include <sys/stat.h>

#include <algorithm>
#include <cctype>
#include <filesystem>

#include "maccleaner/scanner.hpp"

namespace maccleaner::uninstaller {

namespace fs = std::filesystem;

namespace {

std::string lower(std::string_view s) {
    std::string r(s);
    std::transform(r.begin(), r.end(), r.begin(), [](unsigned char c) { return std::tolower(c); });
    return r;
}

bool equalsCi(std::string_view a, std::string_view b) { return lower(a) == lower(b); }

// Top-level entries only. increment(ec): an unreadable dir (EPERM) yields
// what was read so far instead of throwing.
std::vector<fs::path> topLevel(const fs::path& dir) {
    std::vector<fs::path> out;
    std::error_code ec;
    fs::directory_iterator it(dir, ec);
    const fs::directory_iterator end;
    while (!ec && it != end) {
        out.push_back(it->path());
        it.increment(ec);
    }
    return out;
}

bool insideBundle(std::string_view program, std::string_view bundle) {
    if (program.empty() || bundle.empty()) return false;
    std::string prefix(bundle);
    if (prefix.back() != '/') prefix += '/';
    return program.substr(0, prefix.size()) == prefix;
}

} // namespace

std::string toString(LeftoverKind kind) {
    switch (kind) {
        case LeftoverKind::AppBundle: return "App";
        case LeftoverKind::Support: return "Application Support";
        case LeftoverKind::Cache: return "Caches";
        case LeftoverKind::Preferences: return "Preferences";
        case LeftoverKind::Container: return "Container";
        case LeftoverKind::GroupContainer: return "Group Container";
        case LeftoverKind::SavedState: return "Saved State";
        case LeftoverKind::Logs: return "Logs";
        case LeftoverKind::HTTPStorage: return "HTTP Storage";
        case LeftoverKind::WebKit: return "WebKit";
        case LeftoverKind::Cookies: return "Cookies";
        case LeftoverKind::LaunchAgent: return "Launch Agent";
    }
    return "";
}

bool matchesId(std::string_view entryName, std::string_view bundleId) {
    if (bundleId.empty()) return false;
    const std::string n = lower(entryName), id = lower(bundleId);
    return n == id || n.compare(0, id.size() + 1, id + ".") == 0;
}

std::vector<AppInfo> listApps(const Environment& env) {
    std::vector<AppInfo> apps;
    for (const auto& folder : env.appFolders) {
        for (const auto& p : topLevel(folder)) {
            const std::string ext = lower(p.extension().string());
            struct stat st {};
            if (ext != ".app" || ::lstat(p.c_str(), &st) != 0 || S_ISLNK(st.st_mode)) continue;
            auto info = env.readApp(p.string());
            if (!info || info->bundleId.empty() || info->appleSigned || equalsCi(info->bundleId, kSelfBundleId)) continue;
            apps.push_back(std::move(*info));
        }
    }
    std::sort(apps.begin(), apps.end(), [](const AppInfo& a, const AppInfo& b) { return lower(a.name) < lower(b.name); });
    return apps;
}

std::vector<Leftover> findLeftovers(const Environment& env, const AppInfo& app) {
    std::vector<Leftover> out;
    const auto add = [&](const fs::path& p, LeftoverKind kind) {
        Leftover l;
        l.path = p.string();
        l.kind = kind;
        struct stat st {};
        if (::lstat(p.c_str(), &st) == 0) {
            l.sizeBytes = S_ISDIR(st.st_mode) ? directorySizeBytes(p) : static_cast<std::uint64_t>(st.st_size);
        }
        l.needsAdmin = !env.ownedByUser(l.path);
        out.push_back(std::move(l));
    };

    add(app.path, LeftoverKind::AppBundle);

    const std::string& id = app.bundleId;
    const auto idRule = [&](const std::string& n) { return matchesId(n, id); };
    const auto idOrName = [&](const std::string& n) { return matchesId(n, id) || (!app.name.empty() && equalsCi(n, app.name)); };
    const auto groupRule = [&](const std::string& n) {
        if (idRule(n)) return true;
        if (!app.teamId.empty() && matchesId(n, app.teamId + "." + id)) return true;
        return std::any_of(app.appGroups.begin(), app.appGroups.end(), [&](const std::string& g) { return equalsCi(n, g); });
    };
    const auto exact = [&](const char* suffix) {
        return [&id, suffix](const std::string& n) { return equalsCi(n, id + suffix); };
    };
    // A launchd plist matches by file name, by its Label, or by a Program inside the bundle.
    const auto agentRule = [&](const fs::path& dir) {
        return [&, dir](const std::string& n) {
            if (idRule(n)) return true;
            if (!env.readLaunchAgent) return false;
            auto info = env.readLaunchAgent((dir / n).string());
            return info && (idRule(info->label) || insideBundle(info->program, app.path));
        };
    };

    struct Location {
        const char* dir;
        LeftoverKind kind;
        std::function<bool(const std::string&)> match;
    };
    const auto scan = [&](const fs::path& dir, LeftoverKind kind, const std::function<bool(const std::string&)>& match) {
        for (const auto& p : topLevel(dir))
            if (match(p.filename().string())) add(p, kind);
    };

    const fs::path userLib = fs::path(env.home) / "Library";
    const std::vector<Location> user = {
        {"Application Support", LeftoverKind::Support, idOrName},
        {"Caches", LeftoverKind::Cache, idRule},
        {"Preferences", LeftoverKind::Preferences, idRule},
        {"Preferences/ByHost", LeftoverKind::Preferences, idRule},
        {"Containers", LeftoverKind::Container, idRule},
        {"Group Containers", LeftoverKind::GroupContainer, groupRule},
        {"Saved Application State", LeftoverKind::SavedState, exact(".savedState")},
        {"Logs", LeftoverKind::Logs, idOrName},
        {"HTTPStorages", LeftoverKind::HTTPStorage, idRule},
        {"WebKit", LeftoverKind::WebKit, idRule},
        {"Cookies", LeftoverKind::Cookies, exact(".binarycookies")},
        {"LaunchAgents", LeftoverKind::LaunchAgent, agentRule(userLib / "LaunchAgents")},
    };
    for (const auto& l : user) scan(userLib / l.dir, l.kind, l.match);

    // Same rules under /Library. Root-owned matches come back with needsAdmin.
    // LaunchDaemons use the Launch Agent kind; PrivilegedHelperTools use Support.
    const fs::path sysLib = env.systemLibrary;
    const std::vector<Location> system = {
        {"Application Support", LeftoverKind::Support, idOrName},
        {"Caches", LeftoverKind::Cache, idRule},
        {"Preferences", LeftoverKind::Preferences, idRule},
        {"LaunchAgents", LeftoverKind::LaunchAgent, agentRule(sysLib / "LaunchAgents")},
        {"LaunchDaemons", LeftoverKind::LaunchAgent, agentRule(sysLib / "LaunchDaemons")},
        {"PrivilegedHelperTools", LeftoverKind::Support, idRule},
    };
    for (const auto& l : system) scan(sysLib / l.dir, l.kind, l.match);

    return out;
}

} // namespace maccleaner::uninstaller
