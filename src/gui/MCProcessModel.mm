#import "MCProcessModel.h"

#include "maccleaner/optimizer.hpp"
#include "maccleaner/processes.hpp"

#include <cerrno>
#include <mach/mach_time.h>
#include <signal.h>
#include <unistd.h>

#include <string>
#include <vector>

using namespace maccleaner;

namespace {

NSString *toNSString(const std::string &value) {
    NSString *result = [NSString stringWithUTF8String:value.c_str()];
    return result != nil ? result : @"(unprintable)";
}

std::uint64_t nowNs() {
    static const mach_timebase_info_data_t timebase = [] {
        mach_timebase_info_data_t info{};
        mach_timebase_info(&info);
        return info;
    }();
    return mach_absolute_time() * timebase.numer / timebase.denom;
}

} // namespace

@interface MCProcessItem ()
- (instancetype)initWithInfo:(const ProcessInfo &)info now:(NSDate *)now;
@end

@implementation MCProcessItem

- (instancetype)initWithInfo:(const ProcessInfo &)info now:(NSDate *)now {
    if ((self = [super init])) {
        _pid = info.sample.pid;
        _name = [toNSString(info.sample.name) copy];
        _path = [toNSString(info.sample.path) copy];
        _cpuPercent = info.cpuPercent;
        _memoryBytes = info.sample.memoryBytes;
        _uptimeSeconds =
            MAX(0.0, now.timeIntervalSince1970 - (NSTimeInterval)info.sample.startTime);

        switch (classifyProcess(info.sample.path)) {
            case ProcessKind::App: _kind = MCProcessKindApp; break;
            case ProcessKind::System: _kind = MCProcessKindSystem; break;
            case ProcessKind::Background: _kind = MCProcessKindBackground; break;
        }

        std::string reason;
        _killable = isSafeToKill(info.sample.pid, &reason);
        _notKillableReason = _killable ? nil : [toNSString(reason) copy];
    }
    return self;
}

@end

@interface MCOptimizationCandidate ()
- (instancetype)initWithCandidate:(const OptimizationCandidate &)candidate;
@end

@implementation MCOptimizationCandidate

- (instancetype)initWithCandidate:(const OptimizationCandidate &)candidate {
    if ((self = [super init])) {
        _pid = candidate.sample.pid;
        _name = [toNSString(candidate.sample.name) copy];
        _path = [toNSString(candidate.sample.path) copy];
        _kindLabel = [toNSString(toString(candidate.kind)) copy];
        _reason = [toNSString(candidate.reason) copy];
        _reclaimableBytes = candidate.reclaimableBytes;
        _recommended = candidate.recommended;
        // Recommended proposals start accepted; the opt-in ones (a live
        // helper whose content would reload) start unchecked, so nothing
        // with a visible cost happens unless the user asks for it.
        _selected = candidate.recommended;
    }
    return self;
}

@end

@interface MCProcessModel () {
    // Owned by the work queue: the previous snapshot and its timestamp, the
    // baseline for the next CPU%% computation.
    std::vector<ProcessSample> _previous;
    std::uint64_t _previousAtNs;
}
@property(nonatomic, strong) dispatch_queue_t workQueue;
@property(nonatomic) BOOL refreshing; // main-thread only; coalesces overlapping refreshes
@end

@implementation MCProcessModel

- (instancetype)init {
    if ((self = [super init])) {
        _workQueue = dispatch_queue_create("com.maccleaner.processes", DISPATCH_QUEUE_SERIAL);
        _previousAtNs = 0;
    }
    return self;
}

- (void)refreshWithCompletion:(void (^)(NSArray<MCProcessItem *> *))completion {
    if (self.refreshing) {
        return;
    }
    self.refreshing = YES;

    dispatch_async(self.workQueue, ^{
        const std::vector<ProcessSample> current = sampleProcesses(::geteuid());
        const std::uint64_t currentAtNs = nowNs();
        const std::uint64_t wallDelta =
            self->_previousAtNs > 0 ? currentAtNs - self->_previousAtNs : 0;

        const std::vector<ProcessInfo> infos = diffProcessSamples(self->_previous, current, wallDelta);

        self->_previous = current;
        self->_previousAtNs = currentAtNs;

        NSDate *now = [NSDate date];
        NSMutableArray<MCProcessItem *> *items = [NSMutableArray arrayWithCapacity:infos.size()];
        for (const ProcessInfo &info : infos) {
            [items addObject:[[MCProcessItem alloc] initWithInfo:info now:now]];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.refreshing = NO;
            completion(items);
        });
    });
}

- (void)findOptimizationCandidatesWithCompletion:
    (void (^)(NSArray<MCOptimizationCandidate *> *))completion {
    dispatch_async(self.workQueue, ^{
        // Two fresh samples, not the refresh cycle's cached ones: the rules
        // key on process state and parentage (stale by up to two seconds is
        // how you signal the wrong pid), and the idle-helper rule needs a
        // real CPU percentage, which does not exist without a baseline --
        // with an empty one every process reads as 0% and looks idle.
        const std::vector<ProcessSample> before = sampleProcesses(::geteuid());
        const std::uint64_t startNs = nowNs();
        [NSThread sleepForTimeInterval:1.0];
        const std::vector<ProcessSample> after = sampleProcesses(::geteuid());
        const std::vector<ProcessInfo> infos = diffProcessSamples(before, after, nowNs() - startNs);

        const std::vector<OptimizationCandidate> found = findOptimizationCandidates(infos);

        NSMutableArray<MCOptimizationCandidate *> *candidates =
            [NSMutableArray arrayWithCapacity:found.size()];
        for (const OptimizationCandidate &candidate : found) {
            [candidates addObject:[[MCOptimizationCandidate alloc] initWithCandidate:candidate]];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(candidates);
        });
    });
}

- (BOOL)processExists:(int)pid {
    // Signal 0 performs the permission and existence checks without sending
    // anything. EPERM means it is alive but someone else's -- still alive.
    return ::kill(pid, 0) == 0 || errno != ESRCH;
}

- (BOOL)killPid:(int)pid force:(BOOL)force error:(NSString **)error {
    std::string errorText;
    if (!killProcess(pid, force ? KillMode::Force : KillMode::Graceful, errorText)) {
        if (error != nullptr) {
            *error = toNSString(errorText);
        }
        return NO;
    }
    return YES;
}

@end
