#include "maccleaner/optimizer.hpp"

#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <ctime>
#include <string_view>
#include <unordered_set>

namespace maccleaner {

namespace {

constexpr std::string_view kAppSuffix = ".app";
constexpr std::string_view kMacOSDir = "/Contents/MacOS/";

// Background agents whose whole job is to wake up, check for updates or
// phone home, and go away again -- their app or a launchd job starts them
// again the next time they are needed, so terminating one costs nothing but
// the memory it was holding.
//
// Membership rule for anything added here: it must be something the system
// or its owning app *restarts on demand*. Anything that would simply stay
// dead, or that the user interacts with, does not belong on this list.
// Matched on the exact process name, never a substring, so an unrelated
// binary cannot be swept up by a loose prefix.
// Something the user or an app deliberately registered to keep running in
// the background: login items and launchd agents/daemons. These look exactly
// like leaked helpers -- reparented to launchd, owning app not running -- but
// terminating one breaks a feature the user chose to have (this rule exists
// because an earlier, looser version of the orphan check proposed killing
// "Mac Mouse Fix Helper", a login item that *is* the product; the settings
// app it belongs to is only its UI).
bool isPersistentBackgroundItem(const std::string& path) {
    return path.find("/LoginItems/") != std::string::npos ||
           path.find("/LaunchAgents/") != std::string::npos ||
           path.find("/LaunchDaemons/") != std::string::npos;
}

// The Chromium/Electron per-role child process convention: "Google Chrome
// Helper (Renderer)", "Code Helper (GPU)", "Claude Helper (Plugin)". The
// parenthesised role is the signal -- these are strictly per-session
// children of a running app and are never meant to outlive it, unlike
// role-less "* Helper" processes, which are usually persistent agents.
bool isRoleHelperName(const std::string& name) {
    return name.find(" Helper (") != std::string::npos && name.back() == ')';
}

bool isKnownAgentName(const std::string& name) {
    static const std::unordered_set<std::string> agents{
        // Google (Chrome, Drive, Earth) -- relaunched by launchd/Keystone.
        "GoogleSoftwareUpdateAgent",
        "GoogleSoftwareUpdateDaemon",
        "GoogleUpdater",
        // Microsoft Office / Edge auto-update.
        "Microsoft AutoUpdate",
        "Microsoft Update Assistant",
        "MicrosoftAutoUpdate",
        // Adobe Creative Cloud satellites -- relaunched by the CC app.
        "AdobeIPCBroker",
        "AdobeCRDaemon",
        "AdobeGCClient",
        "CCXProcess",
        "Core Sync",
        // Dropbox's separate updater (not the Dropbox app itself).
        "DropboxMacUpdate",
    };
    return agents.count(name) > 0;
}

// Generic updater naming, for the many vendors the explicit list above will
// never enumerate one by one. Deliberately anchored on update-specific words
// rather than something loose like "helper" or "service": those appear in
// the names of processes that are doing actual work.
//
// It has to be a *whole word* match, or "UpdateManagerWindowController" and
// friends would qualify. In practice these names are camel-cased, so the
// test is "the word Update(r) appears with a capital U and is not part of a
// longer word like Updated".
bool looksLikeUpdater(const std::string& name) {
    static const std::array<std::string_view, 5> markers{
        "Updater", "AutoUpdate", "SoftwareUpdate", "UpdateService", "Update Helper",
    };
    for (const std::string_view marker : markers) {
        const std::size_t pos = name.find(marker);
        if (pos == std::string::npos) {
            continue;
        }
        // Reject a marker that is merely a prefix of a longer word
        // ("Updaterface"): the next character must not be a lowercase letter.
        const std::size_t after = pos + marker.size();
        if (after < name.size() && std::islower(static_cast<unsigned char>(name[after]))) {
            continue;
        }
        return true;
    }
    return false;
}

// Apple's own code, and XPC services generally. Both are started on demand
// and torn down by the system when idle, so they are never "junk the user
// should close": at best killing one is churn the system immediately undoes.
//
// This exists because the generic updater pattern matched
// SetStoreUpdateService -- an Apple XPC service under
// /System/Library/PrivateFrameworks -- and cheerfully proposed closing five
// copies of it. "UpdateService" in an Apple framework does not mean the same
// thing as "SomeVendorUpdater" in /Applications.
bool isSystemManagedService(const std::string& path) {
    return path.rfind("/System/", 0) == 0 || path.find(".xpc/") != std::string::npos;
}

// A helper process whose content can be rebuilt on demand: Chromium/Electron
// children (nested .app bundles) and WebKit's content processes, which back
// individual Safari tabs. Terminating one costs a reload, not data the user
// cannot get back -- which is why the idle rule is confined to these and
// never touches an application itself.
bool isReloadableHelper(const std::string& path, const std::string& name) {
    if (appBundleDepth(path) >= 2) {
        return true;
    }
    return name.find("WebKit.WebContent") != std::string::npos ||
           name.find("WebContent") != std::string::npos;
}

std::string humanDuration(std::time_t seconds) {
    const long long hours = static_cast<long long>(seconds) / 3600;
    if (hours >= 24) {
        return std::to_string(hours / 24) + "d";
    }
    if (hours >= 1) {
        return std::to_string(hours) + "h";
    }
    return std::to_string(static_cast<long long>(seconds) / 60) + "m";
}

std::string humanMegabytes(std::uint64_t bytes) {
    const std::uint64_t mb = bytes / (1ull << 20);
    if (mb >= 1024) {
        return std::to_string(mb / 1024) + "." + std::to_string((mb % 1024) * 10 / 1024) + " GB";
    }
    return std::to_string(mb) + " MB";
}

} // namespace

std::string toString(JunkKind kind) {
    switch (kind) {
        case JunkKind::ZombieOrStopped: return "Not running";
        case JunkKind::OrphanedHelper: return "Orphaned helper";
        case JunkKind::DeletedExecutable: return "App no longer installed";
        case JunkKind::RelaunchableAgent: return "Background updater";
        case JunkKind::IdleHeavyHelper: return "Idle helper";
    }
    return "Unknown";
}

bool executableIsGone(const std::string& path) {
    if (path.empty()) {
        return false; // unknown path is not evidence of anything
    }
    struct stat st {};
    return ::stat(path.c_str(), &st) != 0;
}

int appBundleDepth(const std::string& path) {
    int depth = 0;
    std::size_t pos = 0;
    while ((pos = path.find(kAppSuffix, pos)) != std::string::npos) {
        // Only count ".app" that is a whole path component, so a directory
        // literally named "notanapp" or a file "foo.appdata" cannot inflate
        // the depth and make a real application look like a helper.
        const std::size_t after = pos + kAppSuffix.size();
        if (after == path.size() || path[after] == '/') {
            ++depth;
        }
        pos = after;
    }
    return depth;
}

bool isUserFacingApp(const std::string& path) {
    return appBundleDepth(path) == 1 && path.find(kMacOSDir) != std::string::npos;
}

std::string owningAppBundle(const std::string& path) {
    if (appBundleDepth(path) < 2) {
        return {}; // not a nested helper: no outer bundle to speak of
    }
    const std::size_t pos = path.find(kAppSuffix);
    if (pos == std::string::npos) {
        return {};
    }
    return path.substr(0, pos + kAppSuffix.size());
}

std::vector<OptimizationCandidate> findOptimizationCandidates(const std::vector<ProcessInfo>& infos,
                                                               const OptimizerThresholds& thresholds,
                                                               const PathExistsFn& pathExists) {
    const PathExistsFn exists =
        pathExists ? pathExists : PathExistsFn([](const std::string& path) { return !executableIsGone(path); });

    // Every top-level app currently running, by bundle path. An app is
    // "running" when its own main binary is live -- helpers do not count,
    // which is the whole point of the orphan rule.
    std::unordered_set<std::string> runningApps;
    for (const ProcessInfo& info : infos) {
        if (isUserFacingApp(info.sample.path)) {
            const std::size_t pos = info.sample.path.find(kAppSuffix);
            runningApps.insert(info.sample.path.substr(0, pos + kAppSuffix.size()));
        }
    }

    const std::time_t now = std::time(nullptr);

    std::vector<OptimizationCandidate> candidates;
    for (const ProcessInfo& info : infos) {
        const ProcessSample& sample = info.sample;
        // Never a user-facing application, whatever else it looks like.
        if (isUserFacingApp(sample.path)) {
            continue;
        }
        // Never something registered to run in the background on purpose.
        if (isPersistentBackgroundItem(sample.path)) {
            continue;
        }
        if (sample.pid == ::getpid()) {
            continue;
        }

        OptimizationCandidate candidate;
        candidate.sample = sample;
        candidate.reclaimableBytes = sample.memoryBytes;
        bool matched = false;

        if (sample.state == ProcessState::Zombie) {
            candidate.kind = JunkKind::ZombieOrStopped;
            candidate.reason = "Has exited but was never cleaned up by its parent";
            matched = true;
        } else if (sample.state == ProcessState::Stopped) {
            candidate.kind = JunkKind::ZombieOrStopped;
            candidate.reason = "Suspended and not doing any work";
            matched = true;
        } else if (const std::string owner = owningAppBundle(sample.path);
                    !owner.empty() && isRoleHelperName(sample.name) && runningApps.count(owner) == 0) {
            candidate.kind = JunkKind::OrphanedHelper;
            const std::size_t slash = owner.find_last_of('/');
            const std::string appName = slash == std::string::npos ? owner : owner.substr(slash + 1);
            candidate.reason = "Renderer left behind after " + appName + " quit";
            matched = true;
        } else if (!sample.path.empty() && !exists(sample.path)) {
            candidate.kind = JunkKind::DeletedExecutable;
            candidate.reason = "Its program is no longer installed; nothing can use it again";
            matched = true;
        } else if (isRelaunchableAgent(sample.name) && !isSystemManagedService(sample.path)) {
            candidate.kind = JunkKind::RelaunchableAgent;
            candidate.reason = "Update checker; it starts again by itself when it is needed";
            matched = true;
        } else if (const std::time_t uptime = now - sample.startTime;
                    isReloadableHelper(sample.path, sample.name) &&
                    sample.memoryBytes >= thresholds.idleHelperMinBytes &&
                    info.cpuPercent < thresholds.idleHelperMaxCpuPercent &&
                    uptime >= thresholds.idleHelperMinUptimeSeconds) {
            candidate.kind = JunkKind::IdleHeavyHelper;
            candidate.reason = "Idle " + humanDuration(uptime) + " holding " +
                                humanMegabytes(sample.memoryBytes) +
                                "; its tab or window reloads if you go back to it";
            // Alive and attached to a running app: reclaiming it costs a
            // reload, so the user opts in rather than opting out.
            candidate.recommended = false;
            matched = true;
        }

        if (!matched) {
            continue;
        }
        // The safety guard has the final word, so the review list can never
        // offer something that would fail the moment the user accepted it.
        if (!isSafeToKill(sample.pid)) {
            continue;
        }
        candidates.push_back(std::move(candidate));
    }

    // Recommended proposals first, then by size: the rows the user is most
    // likely to accept should not be buried under the opt-in ones.
    std::sort(candidates.begin(), candidates.end(),
               [](const OptimizationCandidate& a, const OptimizationCandidate& b) {
                   if (a.recommended != b.recommended) {
                       return a.recommended;
                   }
                   return a.reclaimableBytes > b.reclaimableBytes;
               });
    return candidates;
}

bool isRelaunchableAgent(const std::string& name) {
    return isKnownAgentName(name) || looksLikeUpdater(name);
}

} // namespace maccleaner
