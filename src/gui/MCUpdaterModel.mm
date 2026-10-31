#import "MCUpdaterModel.h"

#include "maccleaner/updater.hpp"

#include <atomic>
#include <string>
#include <vector>

using namespace maccleaner;

namespace {

NSString *toNSString(const std::string &value) {
    NSString *result = [NSString stringWithUTF8String:value.c_str()];
    return result != nil ? result : @"(unprintable)";
}

NSString *lastLineOf(const std::string &output) {
    NSArray<NSString *> *lines = [toNSString(output) componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    for (NSString *line in lines.reverseObjectEnumerator) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (trimmed.length > 0) {
            return trimmed;
        }
    }
    return @"";
}

} // namespace

@interface MCUpdateItem () {
@public
    updater::OutdatedItem _core;
}
@end

@implementation MCUpdateItem
- (instancetype)initWithCore:(const updater::OutdatedItem &)core {
    if ((self = [super init])) {
        _core = core;
        _source = static_cast<MCUpdateSource>(core.source);
        _name = toNSString(core.name);
        _installedVersion = toNSString(core.installedVersion);
        _latestVersion = toNSString(core.latestVersion);
        _appPath = toNSString(core.appPath);
        _storeId = toNSString(core.storeId);
        _isCask = core.isCask;
        _pinned = core.pinned;
        _manualCommand = toNSString(updater::manualCommand(core));
        _upgradable = core.source == updater::Source::Homebrew && !core.pinned;
        _lastLine = @"";
    }
    return self;
}
@end

@implementation MCUpdateSourceStatus
- (instancetype)initWithCore:(const updater::SourceStatus &)core {
    if ((self = [super init])) {
        _source = static_cast<MCUpdateSource>(core.source);
        _title = toNSString(updater::toString(core.source));
        _available = core.available;
        _error = toNSString(core.error);
        _skipped = core.skipped;
    }
    return self;
}
@end

@interface MCUpdaterModel () {
    // The environment belongs to the work queue; the cancel flag is the one
    // piece both threads touch.
    updater::Environment _environment;
    std::atomic<bool> _cancelled;
}
@property(nonatomic, strong) dispatch_queue_t workQueue;
@property(nonatomic) BOOL busy;
@property(nonatomic, copy) NSArray<MCUpdateItem *> *items;
@property(nonatomic, copy) NSArray<MCUpdateSourceStatus *> *sources;
@end

@implementation MCUpdaterModel

- (instancetype)init {
    if ((self = [super init])) {
        _workQueue = dispatch_queue_create("com.maccleaner.updater", DISPATCH_QUEUE_SERIAL);
        _cancelled.store(false);
        _items = @[];
        _sources = @[];
        dispatch_async(_workQueue, ^{ self->_environment = updater::defaultEnvironment(); });
    }
    return self;
}

- (void)checkWithCompletion:(void (^)(void))completion {
    if (self.busy) {
        return;
    }
    self.busy = YES;
    _cancelled.store(false);
    dispatch_async(self.workQueue, ^{
        const updater::CheckResult result = updater::checkUpdates(
            updater::runCommand, self->_environment, [self] { return self->_cancelled.load(); });
        NSMutableArray<MCUpdateItem *> *items = [NSMutableArray array];
        for (const auto &item : result.items) {
            [items addObject:[[MCUpdateItem alloc] initWithCore:item]];
        }
        NSMutableArray<MCUpdateSourceStatus *> *sources = [NSMutableArray array];
        for (const auto &status : result.sources) {
            [sources addObject:[[MCUpdateSourceStatus alloc] initWithCore:status]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.items = items;
            self.sources = sources;
            self.busy = NO;
            completion();
        });
    });
}

- (void)upgradeItems:(NSArray<MCUpdateItem *> *)items
            progress:(void (^)(MCUpdateItem *))progress
          completion:(void (^)(NSUInteger, NSUInteger, BOOL))completion {
    if (self.busy || items.count == 0) {
        return;
    }
    self.busy = YES;
    _cancelled.store(false);
    for (MCUpdateItem *item in items) {
        item.state = MCUpdateRowStatePending;
        item.lastLine = @"";
        progress(item);
    }
    dispatch_async(self.workQueue, ^{
        NSUInteger upgraded = 0, failed = 0;
        for (MCUpdateItem *item in items) {
            if (self->_cancelled.load()) {
                break;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                item.state = MCUpdateRowStateUpgrading;
                progress(item);
            });
            const updater::CommandResult r = updater::upgradeBrew(updater::runCommand, self->_environment, item->_core);
            const BOOL ok = r.exitCode == 0;
            NSString *line = ok ? @"" : lastLineOf(r.output);
            if (!ok && line.length == 0) {
                line = r.exitCode == -1 ? @"Timed out" : [NSString stringWithFormat:@"Exit code %d", r.exitCode];
            }
            ok ? ++upgraded : ++failed;
            dispatch_async(dispatch_get_main_queue(), ^{
                item.state = ok ? MCUpdateRowStateDone : MCUpdateRowStateFailed;
                item.lastLine = line;
                progress(item);
            });
        }
        const BOOL cancelled = self->_cancelled.load();
        dispatch_async(dispatch_get_main_queue(), ^{
            for (MCUpdateItem *item in items) {
                if (item.state == MCUpdateRowStatePending) {
                    item.state = MCUpdateRowStateIdle;
                    progress(item);
                }
            }
            self.busy = NO;
            completion(upgraded, failed, cancelled);
        });
    });
}

- (void)cancel {
    _cancelled.store(true);
}

@end
