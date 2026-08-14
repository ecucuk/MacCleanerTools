#import "MCProcessModel.h"

#include "maccleaner/processes.hpp"

#include <mach/mach_time.h>
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
