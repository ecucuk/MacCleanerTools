#pragma once

#include <sys/types.h>

#include <cstdint>
#include <ctime>
#include <string>
#include <vector>

namespace maccleaner {

// One point-in-time measurement of one process. CPU time is cumulative
// (user + system, nanoseconds since process start); turning it into a
// percentage requires two samples -- see diffProcessSamples.
// Kernel-reported run state, as far as the optimizer cares. Anything that is
// not explicitly zombie or stopped counts as Running -- the distinction that
// matters is "doing nothing and never will again" versus "alive".
enum class ProcessState {
    Running,
    Stopped, // SSTOP: suspended, e.g. by SIGSTOP or a stuck debugger
    Zombie,  // SZOMB: exited, waiting for a parent that may never reap it
};

struct ProcessSample {
    pid_t pid = 0;
    pid_t parentPid = 0;
    uid_t uid = 0;
    std::string name;             // best-effort: proc_name, else path basename
    std::string path;             // may be empty when unavailable
    std::uint64_t cpuTimeNs = 0;  // cumulative user+system CPU time
    std::uint64_t memoryBytes = 0; // phys_footprint: what Activity Monitor calls "Memory"
    std::time_t startTime = 0;     // epoch seconds
    ProcessState state = ProcessState::Running;
};

// Where a process lives, for display/filtering. Classification is purely
// path-based and deliberately coarse: it drives a filter popup, not policy.
enum class ProcessKind {
    App,         // inside a .app bundle outside /System
    System,      // a /System binary running as the user (cloudd, Finder, ...)
    Background,  // everything else: agents, helpers, CLI tools
};

ProcessKind classifyProcess(const std::string& path);

// A joined pair of samples, ready for display.
struct ProcessInfo {
    ProcessSample sample;   // the newer of the two
    double cpuPercent = 0;  // 100 = one full core, can exceed 100 on multicore
};

// Samples every process owned by `uid` (pass geteuid(); other users' and
// root's processes are never of interest -- they cannot be killed anyway,
// see isSafeToKill). Non-Apple builds return an empty vector.
std::vector<ProcessSample> sampleProcesses(uid_t uid);

// Pure join of two snapshots by pid: cpuPercent = delta CPU time over
// `wallDeltaNs`. Processes present only in `current` get 0% (no baseline
// yet); processes that exited since `previous` are dropped. A pid whose
// start time changed between samples is treated as new (pid reuse), not as
// a process that mysteriously ran backwards.
std::vector<ProcessInfo> diffProcessSamples(const std::vector<ProcessSample>& previous,
                                             const std::vector<ProcessSample>& current,
                                             std::uint64_t wallDeltaNs);

enum class KillMode {
    Graceful, // SIGTERM: the process may save state, refuse, or linger
    Force,     // SIGKILL: immediate, no cleanup
};

// The process-killing analogue of safety::isSafeToDelete. A pid may be
// killed only if ALL hold:
//   1. pid > 1 (never the kernel idle slot or launchd);
//   2. it is not this process itself;
//   3. it still exists and is owned by the current *effective* user --
//      root-owned and other users' processes are rejected here as well as
//      being unkillable by the kernel, so the UI never even offers them;
//   4. its name is not on the hard denylist: currently just loginwindow,
//      whose death ends the login session -- an "optimizer" that logs the
//      user out is not optimizing anything.
// Everything else -- including /System services like cloudd or Finder -- is
// killable with confirmation; launchd restarts the managed ones.
bool isSafeToKill(pid_t pid, std::string* reasonIfUnsafe = nullptr);

// Sends SIGTERM/SIGKILL after re-running isSafeToKill (the check-then-act
// gap is pid reuse; macOS allocates pids sequentially, so the window is
// negligible but not zero -- see README). Returns false with `error` set on
// rejection or failure.
bool killProcess(pid_t pid, KillMode mode, std::string& error);

} // namespace maccleaner
