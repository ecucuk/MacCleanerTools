#include "maccleaner/optimizer.hpp"

#include <unistd.h>

#include <algorithm>
#include <array>
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

} // namespace

std::string toString(JunkKind kind) {
    switch (kind) {
        case JunkKind::ZombieOrStopped: return "Not running";
        case JunkKind::OrphanedHelper: return "Orphaned helper";
        case JunkKind::RelaunchableAgent: return "Background updater";
    }
    return "Unknown";
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

std::vector<OptimizationCandidate> findOptimizationCandidates(const std::vector<ProcessSample>& samples) {
    // Every top-level app currently running, by bundle path. An app is
    // "running" when its own main binary is live -- helpers do not count,
    // which is the whole point of the orphan rule.
    std::unordered_set<std::string> runningApps;
    for (const ProcessSample& sample : samples) {
        if (isUserFacingApp(sample.path)) {
            const std::size_t pos = sample.path.find(kAppSuffix);
            runningApps.insert(sample.path.substr(0, pos + kAppSuffix.size()));
        }
    }

    std::vector<OptimizationCandidate> candidates;
    for (const ProcessSample& sample : samples) {
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
        } else if (isKnownAgentName(sample.name)) {
            candidate.kind = JunkKind::RelaunchableAgent;
            candidate.reason = "Update checker; macOS restarts it when it is needed";
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

    std::sort(candidates.begin(), candidates.end(),
               [](const OptimizationCandidate& a, const OptimizationCandidate& b) {
                   return a.reclaimableBytes > b.reclaimableBytes;
               });
    return candidates;
}

bool isRelaunchableAgent(const std::string& name) {
    return isKnownAgentName(name);
}

} // namespace maccleaner
