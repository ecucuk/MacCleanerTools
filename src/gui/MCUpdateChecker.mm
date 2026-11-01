#import "MCUpdateChecker.h"

#import "MCSettings.h"
#import "MCSettingsWindowController.h"

#include "maccleaner/http.hpp"
#include "maccleaner/selfupdate.hpp"

using namespace maccleaner;

namespace {

NSString *toNSString(const std::string &s) {
    NSString *string = [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
    return string != nil ? string : @"";
}

constexpr NSTimeInterval kAutomaticInterval = 24 * 60 * 60; // unauthenticated API: 60 requests/hour
constexpr double kTimeoutSeconds = 10;

} // namespace

/// What one fetch found; built on the work queue, read on main.
@interface MCUpdateOutcome : NSObject
@property(nonatomic) BOOL succeeded;   // 200 with a valid release, or 404
@property(nonatomic) BOOL newer;
@property(nonatomic, copy) NSString *version;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *notes;
@property(nonatomic, copy) NSString *pageUrl;
@property(nonatomic, copy) NSString *error; // set when !succeeded
@end

@implementation MCUpdateOutcome
@end

@interface MCUpdateChecker ()
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic) BOOL running;
@end

@implementation MCUpdateChecker

+ (instancetype)shared {
    static MCUpdateChecker *shared;
    if (shared == nil) {
        shared = [[MCUpdateChecker alloc] init];
        shared.queue = dispatch_queue_create("com.maccleaner.updatecheck", DISPATCH_QUEUE_SERIAL);
    }
    return shared;
}

- (void)checkManually {
    if (MCSettings.offlineMode) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Offline mode is on";
        alert.informativeText = @"MacCleaner makes no network requests while offline mode is on.";
        [alert addButtonWithTitle:@"Open Settings"];
        [alert addButtonWithTitle:@"OK"];
        if ([alert runModal] == NSAlertFirstButtonReturn) {
            [MCSettingsWindowController.shared showTab:@"privacy"];
        }
        return;
    }
    [self fetchThen:^(MCUpdateOutcome *outcome) {
        [self report:outcome];
    }];
}

- (void)checkAutomaticallyIfDue {
    if (MCSettings.offlineMode || !MCSettings.checkUpdatesAtLaunch) {
        return;
    }
    NSDate *last = MCSettings.lastUpdateCheck;
    if (last != nil && -last.timeIntervalSinceNow < kAutomaticInterval) {
        return;
    }
    [self fetchThen:^(MCUpdateOutcome *outcome) {
        if (outcome.newer && !(MCSettings.skippedVersion != nil && [outcome.version isEqualToString:MCSettings.skippedVersion])) {
            [self report:outcome];
        }
    }];
}

- (void)fetchThen:(void (^)(MCUpdateOutcome *))completion {
    if (self.running) {
        return; // one request at a time
    }
    self.running = YES;
    NSString *current = MCSettings.appVersion;
    dispatch_async(self.queue, ^{
        const std::string version = current.UTF8String != nullptr ? current.UTF8String : "0";
        const auto response = http::get(std::string(selfupdate::kLatestReleaseUrl),
                                        {{"Accept", "application/vnd.github+json"},
                                         {"User-Agent", "MacCleaner/" + version}},
                                        kTimeoutSeconds);
        MCUpdateOutcome *outcome = [[MCUpdateOutcome alloc] init];
        if (!response) {
            outcome.error = @"Could not reach GitHub. Check your internet connection.";
        } else if (response->status == 404) { // no release published yet
            outcome.succeeded = YES;
        } else if (response->status == 403 || response->status == 429) {
            outcome.error = @"GitHub rate limit reached. Try again later.";
        } else if (const auto release = response->status == 200 ? selfupdate::parseLatestRelease(response->body)
                                                                : std::nullopt) {
            outcome.succeeded = YES;
            outcome.newer = selfupdate::isNewer(release->version, version);
            outcome.version = toNSString(release->version);
            outcome.name = toNSString(release->name);
            outcome.notes = toNSString(release->notes);
            outcome.pageUrl = toNSString(release->pageUrl);
        } else {
            outcome.error = @"Could not read the release information.";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.running = NO;
            if (outcome.succeeded) {
                MCSettings.lastUpdateCheck = [NSDate date];
            }
            completion(outcome);
        });
    });
}

- (void)report:(MCUpdateOutcome *)outcome {
    NSAlert *alert = [[NSAlert alloc] init];
    if (!outcome.succeeded) {
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = @"Could not check for updates";
        alert.informativeText = outcome.error;
        [alert runModal];
        return;
    }
    if (!outcome.newer) {
        alert.messageText = @"You're up to date";
        alert.informativeText = [NSString stringWithFormat:@"MacCleaner %@ is the latest version.", MCSettings.appVersion];
        [alert runModal];
        return;
    }

    alert.messageText = [NSString stringWithFormat:@"%@ is available", outcome.name];
    alert.informativeText = [NSString stringWithFormat:@"You have version %@. The new version is %@.",
                                                       MCSettings.appVersion, outcome.version];
    if (outcome.notes.length > 0) {
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 380, 160)];
        scroll.hasVerticalScroller = YES;
        scroll.borderType = NSBezelBorder;
        NSTextView *text = [[NSTextView alloc] initWithFrame:scroll.bounds];
        text.editable = NO;
        text.string = outcome.notes; // plain text: no markdown rendering on macOS 11
        text.textContainerInset = NSMakeSize(4, 4);
        text.autoresizingMask = NSViewWidthSizable;
        scroll.documentView = text;
        [text sizeToFit];
        const CGFloat height = MIN(240, MAX(80, NSHeight(text.frame)));
        scroll.frame = NSMakeRect(0, 0, 380, height);
        alert.accessoryView = scroll;
    }
    [alert addButtonWithTitle:@"Download"];
    [alert addButtonWithTitle:@"Later"];
    [alert addButtonWithTitle:@"Skip This Version"];
    const NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
        // parseLatestRelease accepted only https://github.com/ URLs.
        NSURL *url = [NSURL URLWithString:outcome.pageUrl];
        if (url != nil) {
            [NSWorkspace.sharedWorkspace openURL:url];
        }
    } else if (response == NSAlertThirdButtonReturn) {
        MCSettings.skippedVersion = outcome.version;
    }
}

@end
