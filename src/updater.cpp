#include "maccleaner/updater.hpp"

#include "maccleaner/json.hpp"

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <sstream>

#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <crt_externs.h>
#endif

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

// brew can print warnings before and after the JSON. The document starts at
// a line that begins with '{'.
std::optional<json::Value> parseJsonAfterNoise(std::string_view output) {
    for (std::size_t pos = 0; pos < output.size();) {
        if (output[pos] == '{') {
            if (auto v = json::parsePrefix(output.substr(pos)); v && v->type == json::Value::Type::Object) {
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

namespace {

char** currentEnviron() {
#if defined(__APPLE__)
    return *_NSGetEnviron(); // `environ` is not reliably visible from a library
#else
    extern char** environ;
    return environ;
#endif
}

bool waitWithDeadline(pid_t pid, int& status, std::chrono::steady_clock::time_point deadline) {
    while (true) {
        const pid_t r = ::waitpid(pid, &status, WNOHANG);
        if (r == pid || (r < 0 && errno != EINTR)) {
            return true;
        }
        if (std::chrono::steady_clock::now() >= deadline) {
            return false;
        }
        ::usleep(20'000);
    }
}

} // namespace

CommandResult runCommand(const std::vector<std::string>& argv, int timeoutSeconds) {
    if (argv.empty()) {
        return {-1, "no command"};
    }
    int fds[2];
    if (::pipe(fds) != 0) {
        return {-1, std::string("pipe: ") + std::strerror(errno)};
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDERR_FILENO);
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    // Own process group: a timeout must also stop brew's children (curl, ruby).
    short flags = POSIX_SPAWN_SETPGROUP;
#if defined(__APPLE__)
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT; // don't leak the app's other fds into brew
#else
    posix_spawn_file_actions_addclose(&actions, fds[0]);
    posix_spawn_file_actions_addclose(&actions, fds[1]);
#endif
    posix_spawnattr_setflags(&attr, flags);
    posix_spawnattr_setpgroup(&attr, 0);

    std::vector<char*> args;
    for (const auto& a : argv) {
        args.push_back(const_cast<char*>(a.c_str()));
    }
    args.push_back(nullptr);

    pid_t pid = 0;
    const int rc = ::posix_spawn(&pid, argv[0].c_str(), &actions, &attr, args.data(), currentEnviron());
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    ::close(fds[1]);
    if (rc != 0) {
        ::close(fds[0]);
        return {-1, "cannot run " + argv[0] + ": " + std::strerror(rc)};
    }

    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(timeoutSeconds);
    CommandResult result;
    bool timedOut = false;
    char buffer[16384];
    while (true) {
        const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now());
        if (left.count() <= 0) {
            timedOut = true;
            break;
        }
        pollfd pfd{fds[0], POLLIN, 0};
        const int ready = ::poll(&pfd, 1, static_cast<int>(left.count()));
        if (ready < 0 && errno == EINTR) {
            continue;
        }
        if (ready <= 0) {
            timedOut = ready == 0;
            break;
        }
        const ssize_t n = ::read(fds[0], buffer, sizeof buffer);
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n <= 0) {
            break; // EOF: every writer closed the pipe
        }
        result.output.append(buffer, static_cast<std::size_t>(n));
    }
    ::close(fds[0]);

    int status = 0;
    // EOF is not exit: a child can close its output and keep running.
    if (!timedOut && !waitWithDeadline(pid, status, deadline)) {
        timedOut = true;
    }
    if (timedOut) {
        ::kill(-pid, SIGTERM);
        if (!waitWithDeadline(pid, status, std::chrono::steady_clock::now() + std::chrono::seconds(2))) {
            ::kill(-pid, SIGKILL);
            while (::waitpid(pid, &status, 0) < 0 && errno == EINTR) {
            }
        }
        result.exitCode = -1;
        return result;
    }
    result.exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    return result;
}

namespace {

constexpr int kBrewUpdateTimeout = 120;
constexpr int kCheckTimeout = 60;
constexpr int kCurlRunnerTimeout = 15; // curl's own --max-time is 10
constexpr int kUpgradeTimeout = 1800;

std::vector<std::string> curlCommand(const std::string& url) {
    return {"/usr/bin/curl", "-fsSL", "--proto", "=https", "--proto-redir", "=https",
            "--max-time", "10", "--max-filesize", "5M", url};
}

// One line for the UI: the last non-empty output line, or what went wrong.
std::string describeFailure(const CommandResult& r) {
    std::string last;
    std::istringstream lines(r.output);
    for (std::string line; std::getline(lines, line);) {
        if (line.find_first_not_of(" \t\r") != std::string::npos) {
            last = line;
        }
    }
    if (!last.empty()) {
        return last;
    }
    return r.exitCode == -1 ? "timed out" : "exit code " + std::to_string(r.exitCode);
}

std::vector<std::string> listApps(const std::vector<std::string>& folders) {
    std::vector<std::string> apps;
    for (const auto& folder : folders) {
        std::error_code ec;
        std::filesystem::directory_iterator it(folder, ec), end;
        // increment(ec), not range-for: operator++ throws (see CLAUDE.md).
        for (; !ec && it != end; it.increment(ec)) {
            const auto& path = it->path();
            std::error_code dirEc;
            if (path.extension() == ".app" && it->is_directory(dirEc)) {
                apps.push_back(path.string());
            }
        }
    }
    std::sort(apps.begin(), apps.end());
    return apps;
}

std::string appName(const std::string& appPath) {
    return std::filesystem::path(appPath).stem().string();
}

} // namespace

CheckResult checkUpdates(const RunFn& run, const Environment& env, const std::function<bool()>& cancelled) {
    CheckResult result;
    bool stopped = false;
    auto exec = [&](const std::vector<std::string>& argv, int timeout) -> std::optional<CommandResult> {
        if (stopped || (cancelled && cancelled())) {
            stopped = true;
            return std::nullopt;
        }
        return run(argv, timeout);
    };
    auto add = [&](std::vector<OutdatedItem> items) {
        result.items.insert(result.items.end(), std::make_move_iterator(items.begin()),
                            std::make_move_iterator(items.end()));
    };

    // Homebrew. A failed `brew update` (offline) is not fatal: `outdated`
    // still answers from the local index.
    SourceStatus brew{Source::Homebrew, !env.brewPath.empty(), ""};
    std::set<std::string> caskApps;
    if (brew.available) {
        exec({env.brewPath, "update"}, kBrewUpdateTimeout);
        if (auto r = exec({env.brewPath, "outdated", "--json=v2"}, kCheckTimeout)) {
            auto items = parseBrewOutdated(r->output);
            // No JSON at all must not read as "up to date".
            if ((r->exitCode != 0 && items.empty()) || !parseJsonAfterNoise(r->output)) {
                brew.error = describeFailure(*r);
            }
            add(std::move(items));
        }
        if (auto r = exec({env.brewPath, "info", "--cask", "--json=v2", "--installed"}, kCheckTimeout);
            r && r->exitCode == 0) {
            caskApps = parseBrewCaskApps(r->output);
        }
    }
    brew.skipped = stopped;
    result.sources.push_back(brew);

    SourceStatus port{Source::MacPorts, !env.portPath.empty(), ""};
    if (port.available) {
        if (auto r = exec({env.portPath, "outdated"}, kCheckTimeout)) {
            if (r->exitCode != 0) {
                port.error = describeFailure(*r);
            } else {
                add(parsePortOutdated(r->output));
            }
        }
    }
    port.skipped = stopped;
    result.sources.push_back(port);

    // Split the installed apps: a receipt means App Store, else a feed means Sparkle.
    std::vector<std::pair<std::string, BundleInfo>> storeApps, sparkleApps;
    for (const auto& path : listApps(env.appFolders)) {
        auto info = env.readBundle ? env.readBundle(path) : std::nullopt;
        if (!info) {
            continue;
        }
        if (env.exists && env.exists(path + "/Contents/_MASReceipt/receipt")) {
            if (!info->shortVersion.empty()) { // nothing to compare the store version with
                storeApps.emplace_back(path, std::move(*info));
            }
        } else if (!info->feedURL.empty()) {
            sparkleApps.emplace_back(path, std::move(*info));
        }
    }

    SourceStatus store{Source::AppStore, true, ""};
    if (!storeApps.empty()) {
        std::vector<std::string> mdls{"/usr/bin/mdls", "-raw", "-name", "kMDItemAppStoreAdamID"};
        for (const auto& [path, info] : storeApps) {
            mdls.push_back(path);
        }
        std::map<std::string, std::size_t> idToApp;
        if (auto r = exec(mdls, kCheckTimeout); r && r->exitCode == 0) {
            // -raw separates the values of several files with NUL.
            std::size_t index = 0, start = 0;
            while (index < storeApps.size() && start <= r->output.size()) {
                auto end = r->output.find('\0', start);
                if (end == std::string::npos) {
                    end = r->output.size();
                }
                const std::string id = r->output.substr(start, end - start);
                if (!id.empty() && std::all_of(id.begin(), id.end(), [](unsigned char c) { return std::isdigit(c); })) {
                    idToApp[id] = index;
                }
                ++index;
                start = end + 1;
            }
        } else if (r) {
            store.error = describeFailure(*r);
        }
        if (!idToApp.empty()) {
            std::string ids;
            for (const auto& [id, index] : idToApp) {
                ids += (ids.empty() ? "" : ",") + id;
            }
            const std::string url = "https://itunes.apple.com/lookup?id=" + ids + "&country=" + env.country;
            if (auto r = exec(curlCommand(url), kCurlRunnerTimeout)) {
                if (r->exitCode != 0) {
                    store.error = describeFailure(*r);
                }
                for (const auto& [id, version] : parseItunesLookup(r->output)) {
                    const auto it = idToApp.find(id);
                    if (it == idToApp.end()) {
                        continue;
                    }
                    const auto& [path, info] = storeApps[it->second];
                    if (compareVersions(version, info.shortVersion) > 0) {
                        OutdatedItem item;
                        item.source = Source::AppStore;
                        item.name = appName(path);
                        item.installedVersion = info.shortVersion;
                        item.latestVersion = version;
                        item.appPath = path;
                        item.storeId = id;
                        result.items.push_back(std::move(item));
                    }
                }
            }
        }
    }
    store.skipped = stopped;
    result.sources.push_back(store);

    SourceStatus sparkle{Source::Sparkle, true, ""};
    int failedFeeds = 0;
    for (const auto& [path, info] : sparkleApps) {
        // A cask app is Homebrew's to report; no CFBundleVersion means
        // nothing to compare against; plain http feeds are not fetched.
        if (caskApps.count(std::filesystem::path(path).filename().string()) || info.bundleVersion.empty() ||
            info.feedURL.rfind("https://", 0) != 0) {
            continue;
        }
        auto r = exec(curlCommand(info.feedURL), kCurlRunnerTimeout);
        if (!r) {
            break;
        }
        if (r->exitCode != 0) {
            ++failedFeeds;
            continue;
        }
        const auto latest = parseAppcast(r->output);
        if (latest && compareVersions(latest->version, info.bundleVersion) > 0) {
            OutdatedItem item;
            item.source = Source::Sparkle;
            item.name = appName(path);
            item.installedVersion = info.shortVersion.empty() ? info.bundleVersion : info.shortVersion;
            item.latestVersion = latest->shortVersion.empty() ? latest->version : latest->shortVersion;
            item.appPath = path;
            result.items.push_back(std::move(item));
        }
    }
    if (failedFeeds > 0) {
        sparkle.error = std::to_string(failedFeeds) + (failedFeeds == 1 ? " feed" : " feeds") + " could not be read";
    }
    sparkle.skipped = stopped;
    result.sources.push_back(sparkle);
    return result;
}

std::vector<std::string> upgradeCommand(const Environment& env, const OutdatedItem& item) {
    // `brew update` already ran during the check; no prompts without a TTY.
    std::vector<std::string> argv{"/usr/bin/env", "HOMEBREW_NO_AUTO_UPDATE=1", "NONINTERACTIVE=1", env.brewPath, "upgrade"};
    if (item.isCask) {
        argv.push_back("--cask");
    }
    argv.push_back(item.name);
    return argv;
}

CommandResult upgradeBrew(const RunFn& run, const Environment& env, const OutdatedItem& item) {
    return run(upgradeCommand(env, item), kUpgradeTimeout);
}

std::string manualCommand(const OutdatedItem& item) {
    if (item.source == Source::MacPorts) {
        return "sudo port upgrade " + item.name;
    }
    return std::string("brew upgrade ") + (item.isCask ? "--cask " : "") + item.name;
}

} // namespace maccleaner::updater
