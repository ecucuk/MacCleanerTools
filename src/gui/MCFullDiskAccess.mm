#import "MCFullDiskAccess.h"

#import "MCSettings.h"

#include <cerrno>
#include <cstring>

static BOOL gShownThisLaunch = NO;

@implementation MCFullDiskAccess

+ (BOOL)isAccessError:(NSString *)text {
    if (text.length == 0) {
        return NO;
    }
    NSString *eperm = [NSString stringWithUTF8String:std::strerror(EPERM)];
    return [text containsString:eperm] || [text containsString:@"Needs Full Disk Access"];
}

+ (void)presentIfNeededForWindow:(NSWindow *)window {
    if (gShownThisLaunch || MCSettings.fullDiskAccessHintSuppressed) {
        return;
    }
    gShownThisLaunch = YES;
    [self present:window offerSuppress:YES];
}

+ (void)presentForWindow:(NSWindow *)window {
    [self present:window offerSuppress:NO];
}

+ (void)present:(NSWindow *)window offerSuppress:(BOOL)offerSuppress {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"MacCleaner needs Full Disk Access for some folders";
    alert.informativeText =
        @"macOS protects some folders, such as Mail, Safari and app containers, even from apps you run. "
        @"Without Full Disk Access, MacCleaner cannot read or remove items in them and skips them.\n\n"
        @"In System Settings, turn on MacCleaner under Privacy & Security › Full Disk Access, then quit and "
        @"reopen MacCleaner.";
    [alert addButtonWithTitle:@"Open System Settings"];
    [alert addButtonWithTitle:@"Not Now"];
    alert.showsSuppressionButton = offerSuppress;
    alert.suppressionButton.title = @"Don't show again";

    void (^handle)(NSModalResponse) = ^(NSModalResponse response) {
        if (offerSuppress && alert.suppressionButton.state == NSControlStateValueOn) {
            MCSettings.fullDiskAccessHintSuppressed = YES;
        }
        if (response == NSAlertFirstButtonReturn) {
            [self openSystemSettings];
        }
    };
    if (window != nil && window.attachedSheet == nil) {
        [alert beginSheetModalForWindow:window completionHandler:handle];
    } else {
        handle([alert runModal]);
    }
}

+ (void)openSystemSettings {
    NSURL *url =
        [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"];
    [NSWorkspace.sharedWorkspace openURL:url];
}

@end
