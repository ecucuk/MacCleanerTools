#import "MCUninstallerModel.h"

#include "maccleaner/scanner.hpp"
#include "maccleaner/uninstaller.hpp"
#include "maccleaner/updater.hpp"

#include <atomic>
#include <cerrno>
#include <cstring>
#include <filesystem>
#include <set>
#include <string>
#include <vector>

using namespace maccleaner;
namespace fs = std::filesystem;

namespace {

NSString *toNSString(const std::string &value) {
    NSString *result = [NSString stringWithUTF8String:value.c_str()];
    return result != nil ? result : @"(unprintable)";
}

// Our own NSFileManager call instead of trash::moveToTrash, because that one
// flattens the NSError to text and the view must tell EPERM (TCC: Full Disk
// Access) apart from other failures. EPERM becomes strerror(EPERM), the same
// text the core writes when its lstat hits EPERM.
bool trashKeepingErrno(const fs::path &path, std::string &error) {
    @autoreleasepool {
        NSString *nsPath = [NSString stringWithUTF8String:path.c_str()];
        if (nsPath == nil) {
            error = "path is not valid UTF-8";
            return false;
        }
        NSError *nsError = nil;
        if ([NSFileManager.defaultManager trashItemAtURL:[NSURL fileURLWithPath:nsPath] resultingItemURL:nil
                                                   error:&nsError]) {
            return true;
        }
        NSError *underlying = nsError.userInfo[NSUnderlyingErrorKey];
        if ([underlying.domain isEqualToString:NSPOSIXErrorDomain] && underlying.code == EPERM) {
            error = std::strerror(EPERM);
        } else {
            error = nsError != nil ? std::string(nsError.localizedDescription.UTF8String) : "unknown NSFileManager error";
        }
        return false;
    }
}

} // namespace

@interface MCAppRow () {
@public
    uninstaller::AppInfo _core;
}
@end

@implementation MCAppRow
- (instancetype)initWithCore:(const uninstaller::AppInfo &)core {
    if ((self = [super init])) {
        _core = core;
        _path = toNSString(core.path);
        _name = toNSString(core.name);
        _bundleId = toNSString(core.bundleId);
        _version = toNSString(core.version);
    }
    return self;
}
@end

@interface MCLeftoverRow () {
@public
    uninstaller::Leftover _core;
}
@end

@implementation MCLeftoverRow
- (instancetype)initWithCore:(const uninstaller::Leftover &)core {
    if ((self = [super init])) {
        _core = core;
        _path = toNSString(core.path);
        _kind = toNSString(uninstaller::toString(core.kind));
        _sizeBytes = core.sizeBytes;
        _needsAdmin = core.needsAdmin;
        _selected = !core.needsAdmin;
    }
    return self;
}
@end

@implementation MCRemovalRow
- (instancetype)initWithCore:(const uninstaller::RemovalResult &)core sizeBytes:(uint64_t)sizeBytes {
    if ((self = [super init])) {
        _path = toNSString(core.path);
        _ok = core.ok;
        _error = core.error == std::strerror(EPERM) ? @"Needs Full Disk Access" : toNSString(core.error);
        _sizeBytes = sizeBytes;
    }
    return self;
}
@end

@interface MCUninstallerModel () {
    // Both belong to the work queue.
    uninstaller::Environment _environment;
    std::set<std::string> _brewApps; // "Foo.app" bundle names of installed casks
    bool _brewRead;
    // Bumped by each load; an older size walk stops when it sees a newer one.
    std::atomic<unsigned> _generation;
}
@property(nonatomic, strong) dispatch_queue_t workQueue;
@property(nonatomic, strong) dispatch_queue_t sizeQueue;
@end

@implementation MCUninstallerModel

- (instancetype)init {
    if ((self = [super init])) {
        _workQueue = dispatch_queue_create("com.maccleaner.uninstaller", DISPATCH_QUEUE_SERIAL);
        _sizeQueue = dispatch_queue_create("com.maccleaner.uninstaller.sizes", DISPATCH_QUEUE_SERIAL);
        _brewRead = false;
        _generation.store(0);
        dispatch_async(_workQueue, ^{ self->_environment = uninstaller::defaultEnvironment(); });
    }
    return self;
}

- (void)loadApps:(void (^)(NSArray<MCAppRow *> *))done sizeUpdated:(void (^)(MCAppRow *))sizeUpdated {
    const unsigned generation = ++_generation;
    dispatch_async(self.workQueue, ^{
        NSMutableArray<MCAppRow *> *apps = [NSMutableArray array];
        for (const auto &app : uninstaller::listApps(self->_environment)) {
            [apps addObject:[[MCAppRow alloc] initWithCore:app]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(apps); });

        dispatch_async(self.sizeQueue, ^{
            for (MCAppRow *app in apps) {
                if (self->_generation.load() != generation) {
                    return;
                }
                const uint64_t size = directorySizeBytes(fs::path(app->_core.path));
                dispatch_async(dispatch_get_main_queue(), ^{
                    app.sizeBytes = size;
                    sizeUpdated(app);
                });
            }
        });

        // Read the installed casks once per tool session, right after the list,
        // so the first review rarely waits for brew.
        const std::string brew = updater::defaultEnvironment().brewPath;
        if (!brew.empty() && !self->_brewRead) {
            self->_brewRead = true;
            const auto info = updater::runCommand({brew, "info", "--cask", "--json=v2", "--installed"}, 60);
            if (info.exitCode == 0) {
                self->_brewApps = updater::parseBrewCaskApps(info.output);
            }
        }
    });
}

- (void)loadLeftoversForApp:(MCAppRow *)app done:(void (^)(NSArray<MCLeftoverRow *> *))done {
    dispatch_async(self.workQueue, ^{
        NSMutableArray<MCLeftoverRow *> *items = [NSMutableArray array];
        for (const auto &leftover : uninstaller::findLeftovers(self->_environment, app->_core)) {
            [items addObject:[[MCLeftoverRow alloc] initWithCore:leftover]];
        }
        const BOOL homebrew = self->_brewApps.count(fs::path(app->_core.path).filename().string()) > 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            app.homebrew = homebrew;
            done(items);
        });
    });
}

- (void)uninstallApp:(MCAppRow *)app
               items:(NSArray<MCLeftoverRow *> *)items
                done:(void (^)(NSArray<MCRemovalRow *> *, NSString *_Nullable))done {
    dispatch_async(self.workQueue, ^{
        std::vector<uninstaller::Leftover> selected;
        for (MCLeftoverRow *item in items) {
            selected.push_back(item->_core);
        }
        std::string refusal;
        const auto results = uninstaller::uninstall(self->_environment, app->_core, selected, trashKeepingErrno,
                                                    uninstaller::isAppRunning, &refusal);
        NSMutableArray<MCRemovalRow *> *rows = [NSMutableArray array];
        for (const auto &result : results) {
            uint64_t size = 0;
            for (const auto &item : selected) {
                if (item.path == result.path) {
                    size = item.sizeBytes;
                }
            }
            [rows addObject:[[MCRemovalRow alloc] initWithCore:result sizeBytes:size]];
        }
        NSString *why = refusal.empty() ? nil : toNSString(refusal);
        dispatch_async(dispatch_get_main_queue(), ^{ done(rows, why); });
    });
}

@end
