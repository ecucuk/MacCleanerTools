#pragma once

#include "maccleaner/processes.hpp"

#include <functional>
#include <string>
#include <vector>

namespace maccleaner {

// Why a process was proposed for termination. Every candidate carries one,
// and the UI shows it: an optimizer that cannot explain itself is
// indistinguishable from one that kills things at random.
enum class JunkKind {
    ZombieOrStopped,    // exited-but-unreaped, or suspended: doing nothing, ever
    OrphanedHelper,     // browser/Electron role helper whose app has quit
    DeletedExecutable,  // the binary behind it no longer exists on disk
    RelaunchableAgent,  // updater/telemetry agent, restarted on demand
    IdleHeavyHelper,    // helper of a running app, long idle, holding real memory
};

std::string toString(JunkKind kind);

struct OptimizationCandidate {
    ProcessSample sample;
    JunkKind kind;
    std::string reason;                 // one line, user-facing
    std::uint64_t reclaimableBytes = 0; // the process's own footprint

    // Whether the proposal starts accepted in the review UI. False for the
    // idle-helper rule: those processes are alive and serving a running app,
    // so reclaiming them costs a reload of whatever they were holding. The
    // user opts in per row rather than having it done for them.
    bool recommended = true;
};

// Tunables for the idle-helper rule, grouped so the UI and the tests can
// state them instead of hardcoding numbers in three places.
struct OptimizerThresholds {
    std::uint64_t idleHelperMinBytes = 250ull << 20; // worth reclaiming at all
    double idleHelperMaxCpuPercent = 1.0;             // "not doing anything"
    std::time_t idleHelperMinUptimeSeconds = 15 * 60; // and hasn't for a while
};

// --- classification helpers (exposed for tests) -------------------------

// Number of ".app" components in a path. A user-facing application has
// exactly one ("/Applications/Foo.app/Contents/MacOS/Foo"); its helpers are
// nested and have two or more
// ("/Applications/Foo.app/Contents/Frameworks/Foo Helper.app/Contents/MacOS/Foo Helper").
int appBundleDepth(const std::string& path);

// True for a top-level application binary -- something with a Dock icon and
// possibly unsaved documents. These are NEVER optimizer candidates, whatever
// else they look like; quitting them is the user's decision, via the manual
// Quit button. This single rule is what separates this tool from the
// "optimizers" that close your unsaved work to free imaginary memory.
bool isUserFacingApp(const std::string& path);

// For a nested helper binary, the path of the outermost .app bundle it
// belongs to; empty when `path` is not inside a nested bundle.
std::string owningAppBundle(const std::string& path);

// Background updater/telemetry agents that their app or launchd relaunches
// on demand, so terminating them reclaims memory without breaking anything.
// Matches an explicit list of known names plus a generic "*Updater",
// "*AutoUpdate", "*UpdateService" style pattern, which covers the many
// vendors whose updater this list will never enumerate individually.
bool isRelaunchableAgent(const std::string& name);

// True when `path` names a binary that is no longer on disk -- the app was
// deleted or replaced by an update while this process kept running. Such a
// process can never be used again and nothing will restart it.
bool executableIsGone(const std::string& path);

// --- the rules ----------------------------------------------------------

// Examines a snapshot and proposes processes worth terminating, largest
// footprint first. Pure: no signals are sent, nothing is sampled, so the
// rules are testable against synthetic process lists.
//
// A process qualifies when it is
//   1. zombie or stopped; or
//   2. a Chromium/Electron *role* helper -- "Foo Helper (Renderer)",
//      "(GPU)", "(Plugin)" -- whose owning .app has no running main binary
//      in `infos`, i.e. the app quit and leaked a child that can no longer
//      serve anyone; or
//   3. running from a binary that no longer exists on disk; or
//   4. a relaunchable updater/telemetry agent; or
//   5. a helper of a *running* app that has been idle for a while and is
//      holding real memory (see OptimizerThresholds). Unlike 1-4 this one
//      is alive and doing its job, so it is proposed *unrecommended*: the
//      cost of reclaiming it is that its tab, window or view reloads.
//
// and it is NOT
//   * a user-facing application (see isUserFacingApp);
//   * a login item or launchd agent/daemon (see the .cpp): those look
//     identical to leaked helpers -- reparented to launchd, owning app not
//     running -- but are deliberately registered to keep running, and
//     killing one breaks a feature the user chose to have;
//   * this very process;
//   * rejected by isSafeToKill (wrong user, pid<=1, loginwindow, ...).
//
// Rule 2 is deliberately restricted to *role* helpers. A plain "Foo Helper"
// with no parenthesised role is usually a persistent agent whose app is
// merely its settings UI, so treating "owner not running" as leakage
// misfires badly on real systems.
//
// Rule 5 is the one that needs care, because "idle and using memory" is the
// criterion cleaner apps abuse to close unsaved work. It is bounded here by
// never applying to a user-facing application, only to helper processes
// whose content can be reloaded, and by arriving unrecommended so the user
// chooses it deliberately.
//
// Takes ProcessInfo rather than ProcessSample because rule 5 needs a real
// CPU percentage, which only exists across two samples (see
// diffProcessSamples). Passing a diff whose baseline was empty makes every
// process look idle, so callers must diff two genuine samples.
// Answers "is this executable still on disk?". The filesystem is the only
// impurity in these rules, so it is injectable: tests describe a world
// instead of having to build .app bundles on disk, and a synthetic path is
// not mistaken for a deleted program. Empty = ask the real filesystem.
using PathExistsFn = std::function<bool(const std::string& path)>;

std::vector<OptimizationCandidate> findOptimizationCandidates(
    const std::vector<ProcessInfo>& infos,
    const OptimizerThresholds& thresholds = {},
    const PathExistsFn& pathExists = {});

} // namespace maccleaner
