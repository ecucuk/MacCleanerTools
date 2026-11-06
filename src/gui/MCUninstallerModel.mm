#import "MCUninstallerModel.h"

#import <AppKit/AppKit.h>

#import "MCSettings.h"

#include "maccleaner/scanner.hpp"
#include "maccleaner/uninstaller.hpp"
#include "maccleaner/updater.hpp"

#include <atomic>
#include <cerrno>
#include <cstring>
#include <filesystem>

#include <sys/stat.h>
#include <set>
#include <string>
#include <vector>

#include <unistd.h>

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
            const char *text = nsError.localizedDescription.UTF8String; // nil error or description: NULL
            error = text != nullptr ? text : "unknown NSFileManager error";
        }
        return false;
    }
}

bool stillThere(const std::string &path) {
    struct stat st {};
    return ::lstat(path.c_str(), &st) == 0;
}

// Fallback to NSWorkspace: Finder asks for the password itself. Paths travel as
// argv, never as script text. Needs NSAppleEventsUsageDescription: macOS asks
// once for permission to control Finder.
std::string trashWithFinder(const std::vector<std::string> &paths, bool *cancelled) {
    std::vector<std::string> command = {
        "/usr/bin/osascript",
        "-e", "on run argv",
        "-e", "set targets to {}",
        "-e", "repeat with target in argv",
        "-e", "set end of targets to (POSIX file (contents of target)) as alias",
        "-e", "end repeat",
        "-e", "with timeout of 600 seconds",
        "-e", "tell application \"Finder\" to delete targets",
        "-e", "end timeout",
        "-e", "end run",
    };
    command.insert(command.end(), paths.begin(), paths.end());
    const auto result = updater::runCommand(command, 610);
    if (result.exitCode == 0) {
        return {};
    }
    if (result.output.find("-128") != std::string::npos) {
        *cancelled = true;
        return {};
    }
    if (result.output.find("-1743") != std::string::npos) {
        return "Allow MacCleaner to control Finder in Privacy & Security › Automation";
    }
    return result.output.empty() ? "Finder could not move the item" : result.output;
}

// macOS moves root-owned items to the Trash after its own password prompt:
// MacCleaner never sees the password and never runs as root. One call, so one
// prompt. Each result comes from the disk, not from what the call reported.
std::vector<uninstaller::RemovalResult> trashWithPassword(const std::vector<std::string> &paths) {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (const auto &path : paths) {
        NSString *nsPath = [NSString stringWithUTF8String:path.c_str()];
        if (nsPath != nil) {
            [urls addObject:[NSURL fileURLWithPath:nsPath]];
        }
    }
    __block bool cancelled = false;
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSWorkspace.sharedWorkspace recycleURLs:urls
                               completionHandler:^(NSDictionary<NSURL *, NSURL *> *, NSError *error) {
                                   cancelled = [error.domain isEqualToString:NSCocoaErrorDomain] &&
                                               error.code == NSUserCancelledError;
                                   dispatch_semaphore_signal(finished);
                               }];
    });
    dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);

    std::vector<std::string> remaining;
    for (const auto &path : paths) {
        if (stillThere(path)) {
            remaining.push_back(path);
        }
    }
    std::string failure;
    if (!remaining.empty() && !cancelled) {
        failure = trashWithFinder(remaining, &cancelled);
    }

    std::vector<uninstaller::RemovalResult> results;
    for (const auto &path : paths) {
        const bool ok = !stillThere(path);
        results.push_back({path, ok, ok ? "" : cancelled ? "Cancelled" : !failure.empty() ? failure : "Not moved"});
    }
    return results;
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
        _selected = YES;
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
    std::vector<uninstaller::AppInfo> _installed; // last listApps result, for findLeftovers
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
        self->_installed = uninstaller::listApps(self->_environment);
        for (const auto &app : self->_installed) {
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
        // Offline mode: brew info may fetch its API index, so skip it and
        // leave _brewRead false to read once offline mode goes off.
        if (!brew.empty() && !self->_brewRead && !MCSettings.offlineMode) {
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
        for (const auto &leftover : uninstaller::findLeftovers(self->_environment, app->_core, self->_installed)) {
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
        // The GUI quits by bundle ID; helpers inside the bundle can outlive the
        // main process for a moment, so give them up to ~1 s before the core checks.
        for (int i = 0; i < 10 && uninstaller::isAppRunning(app->_core.path); ++i) {
            usleep(100 * 1000);
        }
        std::string refusal;
        const auto results = uninstaller::uninstall(self->_environment, app->_core, selected, trashKeepingErrno,
                                                    uninstaller::isAppRunning, &refusal, trashWithPassword);
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
