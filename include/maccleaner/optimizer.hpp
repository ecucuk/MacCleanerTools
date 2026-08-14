#pragma once

#include "maccleaner/processes.hpp"

#include <string>
#include <vector>

namespace maccleaner {

// Why a process was proposed for termination. Every candidate carries one,
// and the UI shows it: an optimizer that cannot explain itself is
// indistinguishable from one that kills things at random.
enum class JunkKind {
    ZombieOrStopped,    // exited-but-unreaped, or suspended: doing nothing, ever
    OrphanedHelper,     // browser/Electron role helper whose app has quit
    RelaunchableAgent,  // known updater/telemetry agent, restarted on demand
};

std::string toString(JunkKind kind);

struct OptimizationCandidate {
    ProcessSample sample;
    JunkKind kind;
    std::string reason;                 // one line, user-facing
    std::uint64_t reclaimableBytes = 0; // the process's own footprint
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

// Known background updater/telemetry agents that their app or launchd
// relaunches on demand, so terminating them reclaims memory without
// breaking anything. Matched on exact process name; see the list in the
// .cpp for the (deliberately short, conservative) membership.
bool isRelaunchableAgent(const std::string& name);

// --- the rules ----------------------------------------------------------

// Examines a snapshot and proposes processes worth terminating, largest
// footprint first. Pure: no signals are sent, nothing is sampled, so the
// rules are testable against synthetic process lists.
//
// A process qualifies when it is
//   1. zombie or stopped; or
//   2. a Chromium/Electron *role* helper -- "Foo Helper (Renderer)",
//      "(GPU)", "(Plugin)" -- whose owning .app has no running main binary
//      in `samples`, i.e. the app quit and leaked a child that can no longer
//      serve anyone; or
//   3. a known relaunchable updater/telemetry agent.
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
// Deliberately absent: "idle process using a lot of memory". Unused memory
// is not a problem to solve -- macOS reclaims it under pressure -- and that
// criterion is exactly how optimizer apps end up killing the editor holding
// someone's unsaved file.
std::vector<OptimizationCandidate> findOptimizationCandidates(const std::vector<ProcessSample>& samples);

} // namespace maccleaner
