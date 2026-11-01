#include "maccleaner/uninstaller.hpp"

#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cstring>
#include <filesystem>

#include "maccleaner/processes.hpp"
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

std::vector<Leftover> findLeftovers(const Environment& env, const AppInfo& app,
                                   const std::vector<AppInfo>& installed) {
    std::vector<Leftover> out;
    const auto add = [&](const fs::path& p, LeftoverKind kind, bool system) {
        Leftover l;
        l.path = p.string();
        l.kind = kind;
        struct stat st {};
        if (::lstat(p.c_str(), &st) == 0) {
            l.sizeBytes = S_ISDIR(st.st_mode) ? directorySizeBytes(p) : static_cast<std::uint64_t>(st.st_size);
        }
        l.needsAdmin = system || !env.ownedByUser(l.path);
        out.push_back(std::move(l));
    };

    add(app.path, LeftoverKind::AppBundle, false);
    if (env.home.empty()) return out; // fail closed: no Library to scan against

    const std::string& id = app.bundleId;
    std::vector<const AppInfo*> others;
    for (const auto& o : installed)
        if (o.path != app.path) others.push_back(&o);
    // An entry of a more specific installed sibling (com.foo.app.beta for com.foo.app) is not ours.
    const auto siblingOwns = [&](const std::string& n, const std::string& prefix) {
        return std::any_of(others.begin(), others.end(), [&](const AppInfo* o) {
            return o->bundleId.size() > id.size() && matchesId(n, prefix + o->bundleId);
        });
    };
    const auto idRule = [&](const std::string& n) { return matchesId(n, id) && !siblingOwns(n, ""); };
    const auto idOrName = [&](const std::string& n) { return idRule(n) || (!app.name.empty() && equalsCi(n, app.name)); };
    const auto groupRule = [&](const std::string& n) {
        // A group another installed app declares is shared (Office apps share UBF8T346G9.Office).
        const bool shared = std::any_of(others.begin(), others.end(), [&](const AppInfo* o) {
            return std::any_of(o->appGroups.begin(), o->appGroups.end(), [&](const std::string& g) { return equalsCi(n, g); });
        });
        if (shared) return false;
        if (idRule(n)) return true;
        if (!app.teamId.empty() && matchesId(n, app.teamId + "." + id) && !siblingOwns(n, app.teamId + ".")) return true;
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
    const auto scan = [&](const fs::path& dir, LeftoverKind kind, const std::function<bool(const std::string&)>& match,
                          bool system) {
        for (const auto& p : topLevel(dir))
            if (match(p.filename().string())) add(p, kind, system);
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
    for (const auto& l : user) scan(userLib / l.dir, l.kind, l.match, false);

    // Same rules under /Library. /Library is never an allowed root: every match is needsAdmin.
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
    for (const auto& l : system) scan(sysLib / l.dir, l.kind, l.match, true);

    return out;
}

bool isAppRunning(const std::string& appPath) {
    const std::string prefix = appPath + "/";
    for (const auto& p : sampleProcesses(::getuid()))
        if (p.path.compare(0, prefix.size(), prefix) == 0) return true;
    return false;
}

safety::AllowedRoots leftoverRoots(const Environment& env) {
    safety::AllowedRoots roots;
    if (env.home.empty()) return roots; // fail closed: never resolve against the CWD
    const fs::path lib = fs::path(env.home) / "Library";
    for (const char* d : {"Application Support", "Caches", "Preferences", "Containers", "Group Containers",
                          "Saved Application State", "Logs", "HTTPStorages", "WebKit", "Cookies", "LaunchAgents"})
        roots.add(lib / d);
    return roots;
}

std::vector<RemovalResult> uninstall(const Environment& env, const AppInfo& app,
                                     const std::vector<Leftover>& selected, const TrashFn& trash,
                                     const RunningFn& running, std::string* refusal) {
    const auto refuse = [&](const std::string& why) {
        if (refusal != nullptr) *refusal = why;
        return std::vector<RemovalResult>{};
    };
    if (app.appleSigned) return refuse("Refusing to uninstall an Apple-signed app");
    if (running(app.path)) return refuse("Quit " + app.name + " first");

    std::vector<fs::path> folders;
    for (const auto& f : env.appFolders) folders.emplace_back(f);
    const safety::AllowedRoots roots = leftoverRoots(env);

    const auto remove = [&](const Leftover& row) {
        RemovalResult r{row.path, false, {}};
        struct stat st {};
        if (::lstat(row.path.c_str(), &st) != 0) {
            if (errno == ENOENT || errno == ENOTDIR) { // already gone counts as done
                r.ok = true;
            } else {
                r.error = std::strerror(errno); // EACCES/EPERM: cannot tell, not a success
            }
            return r;
        }
        const bool bundle = row.kind == LeftoverKind::AppBundle;
        if (bundle && row.path != app.path) {
            r.error = "Not the selected app's bundle";
        } else if (bundle ? !safety::isSafeToUninstall(row.path, folders, &r.error)
                          : !safety::isSafeToDelete(row.path, roots, &r.error)) {
            // r.error filled by the safety check
        } else {
            r.ok = trash(row.path, r.error);
        }
        return r;
    };

    std::vector<RemovalResult> results;
    for (const auto& row : selected)
        if (!row.needsAdmin && row.kind != LeftoverKind::AppBundle) results.push_back(remove(row));
    for (const auto& row : selected)
        if (!row.needsAdmin && row.kind == LeftoverKind::AppBundle) results.push_back(remove(row));
    return results;
}

} // namespace maccleaner::uninstaller
