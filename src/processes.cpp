#include "maccleaner/processes.hpp"

#include <signal.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <unordered_map>

#ifdef __APPLE__
#include <libproc.h>
#include <mach/mach_time.h>
#include <sys/proc_info.h>
#endif

namespace maccleaner {

namespace {

#ifdef __APPLE__
// rusage_info CPU times are in mach time units, which are 1:1 with
// nanoseconds on Intel but not on Apple Silicon (125/3). Convert once.
std::uint64_t machToNs(std::uint64_t mach) {
    static const mach_timebase_info_data_t timebase = [] {
        mach_timebase_info_data_t info{};
        mach_timebase_info(&info);
        return info;
    }();
    return mach * timebase.numer / timebase.denom;
}
#endif

bool isDenylistedName(const std::string& name) {
    // Killing loginwindow terminates the whole login session.
    return name == "loginwindow";
}

} // namespace

ProcessKind classifyProcess(const std::string& path) {
    if (path.rfind("/System/", 0) == 0 || path.rfind("/usr/libexec/", 0) == 0) {
        return ProcessKind::System;
    }
    if (path.find(".app/") != std::string::npos) {
        return ProcessKind::App;
    }
    return ProcessKind::Background;
}

std::vector<ProcessSample> sampleProcesses(uid_t uid) {
    std::vector<ProcessSample> samples;

#ifdef __APPLE__
    // First call sizes the buffer (returns bytes); headroom absorbs processes
    // spawned between the two calls.
    const int sizeBytes = proc_listpids(PROC_UID_ONLY, uid, nullptr, 0);
    if (sizeBytes <= 0) {
        return samples;
    }
    std::vector<pid_t> pids(static_cast<std::size_t>(sizeBytes) / sizeof(pid_t) + 32);
    const int filledBytes =
        proc_listpids(PROC_UID_ONLY, uid, pids.data(), static_cast<int>(pids.size() * sizeof(pid_t)));
    if (filledBytes <= 0) {
        return samples;
    }
    pids.resize(static_cast<std::size_t>(filledBytes) / sizeof(pid_t));

    samples.reserve(pids.size());
    for (const pid_t pid : pids) {
        if (pid <= 0) {
            continue;
        }

        // Any per-pid call can fail mid-iteration when the process exits;
        // each failure just drops that process from the snapshot.
        struct proc_bsdinfo bsd {};
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd)) != static_cast<int>(sizeof(bsd))) {
            continue;
        }
        if (bsd.pbi_uid != uid) {
            continue; // PROC_UID_ONLY matches real uid; re-check what we display
        }

        rusage_info_v4 usage{};
        if (proc_pid_rusage(pid, RUSAGE_INFO_V4, reinterpret_cast<rusage_info_t*>(&usage)) != 0) {
            continue;
        }

        ProcessSample sample;
        sample.pid = pid;
        sample.uid = bsd.pbi_uid;
        sample.startTime = static_cast<std::time_t>(bsd.pbi_start_tvsec);
        sample.cpuTimeNs = machToNs(usage.ri_user_time + usage.ri_system_time);
        sample.memoryBytes = usage.ri_phys_footprint;

        char pathBuffer[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath(pid, pathBuffer, sizeof(pathBuffer)) > 0) {
            sample.path = pathBuffer;
        }

        char nameBuffer[2 * MAXCOMLEN + 1] = {0};
        if (proc_name(pid, nameBuffer, sizeof(nameBuffer)) > 0) {
            sample.name = nameBuffer;
        } else if (!sample.path.empty()) {
            const std::size_t slash = sample.path.find_last_of('/');
            sample.name = slash == std::string::npos ? sample.path : sample.path.substr(slash + 1);
        } else {
            sample.name = "(pid " + std::to_string(pid) + ")";
        }

        samples.push_back(std::move(sample));
    }
#else
    (void)uid; // process inspection is macOS-only; other platforms get an empty list
#endif

    return samples;
}

std::vector<ProcessInfo> diffProcessSamples(const std::vector<ProcessSample>& previous,
                                             const std::vector<ProcessSample>& current,
                                             std::uint64_t wallDeltaNs) {
    std::unordered_map<pid_t, const ProcessSample*> byPid;
    byPid.reserve(previous.size());
    for (const ProcessSample& sample : previous) {
        byPid.emplace(sample.pid, &sample);
    }

    std::vector<ProcessInfo> infos;
    infos.reserve(current.size());
    for (const ProcessSample& sample : current) {
        ProcessInfo info;
        info.sample = sample;

        const auto it = byPid.find(sample.pid);
        if (it != byPid.end() && wallDeltaNs > 0 &&
            it->second->startTime == sample.startTime &&      // same incarnation, not pid reuse
            sample.cpuTimeNs >= it->second->cpuTimeNs) {
            const std::uint64_t cpuDelta = sample.cpuTimeNs - it->second->cpuTimeNs;
            info.cpuPercent = 100.0 * static_cast<double>(cpuDelta) / static_cast<double>(wallDeltaNs);
        }
        infos.push_back(std::move(info));
    }
    return infos;
}

bool isSafeToKill(pid_t pid, std::string* reasonIfUnsafe) {
    auto reject = [&](const std::string& reason) {
        if (reasonIfUnsafe != nullptr) {
            *reasonIfUnsafe = reason;
        }
        return false;
    };

    if (pid <= 1) {
        return reject("system process (pid " + std::to_string(pid) + ")");
    }
    if (pid == ::getpid()) {
        return reject("that is this application");
    }

#ifdef __APPLE__
    struct proc_bsdinfo bsd {};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd)) != static_cast<int>(sizeof(bsd))) {
        // proc_pidinfo also fails for live processes we are not allowed to
        // inspect (root's, other users'), so "it exited" would be a lie --
        // and this reason is shown to the user. Signal 0 tells the two apart:
        // EPERM means it is alive and someone else's, ESRCH that it is gone.
        if (::kill(pid, 0) != 0 && errno == ESRCH) {
            return reject("process no longer exists");
        }
        return reject("not owned by the current user");
    }
    if (bsd.pbi_uid != ::geteuid()) {
        return reject("not owned by the current user");
    }

    char nameBuffer[2 * MAXCOMLEN + 1] = {0};
    if (proc_name(pid, nameBuffer, sizeof(nameBuffer)) > 0 && isDenylistedName(nameBuffer)) {
        return reject(std::string(nameBuffer) + " would end the login session");
    }
#else
    // Portable best effort: signal 0 probes existence and permission.
    if (::kill(pid, 0) != 0) {
        return reject(errno == ESRCH ? "process no longer exists" : "not permitted");
    }
#endif

    return true;
}

bool killProcess(pid_t pid, KillMode mode, std::string& error) {
    if (!isSafeToKill(pid, &error)) {
        return false;
    }

    const int sig = (mode == KillMode::Force) ? SIGKILL : SIGTERM;
    if (::kill(pid, sig) != 0) {
        error = std::strerror(errno);
        return false;
    }
    return true;
}

} // namespace maccleaner
