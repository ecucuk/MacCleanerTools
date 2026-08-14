// GUI entry point. Sets up NSApplication programmatically (no xib) and hands
// off to MCMainWindowController; all cleanup logic lives in maccleaner_core,
// shared with the mac_cleaner CLI.

#import <AppKit/AppKit.h>

#import "MCMainWindowController.h"

@interface MCAppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) MCMainWindowController *windowController;
@end

@implementation MCAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.windowController = [[MCMainWindowController alloc] init];
    [self.windowController showWindow:nil];
    [self.windowController.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self.windowController startInitialScan];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

@end

// A minimal menu bar. Without one, the app has no Quit item and no working
// ⌘Q / ⌘W, which macOS users will reasonably expect.
static NSMenu *makeMainMenu(void) {
    NSMenu *mainMenu = [[NSMenu alloc] init];

    NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:appMenuItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"About MacCleaner"
                        action:@selector(orderFrontStandardAboutPanel:)
                 keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide MacCleaner" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItemWithTitle:@"Quit MacCleaner" action:@selector(terminate:) keyEquivalent:@"q"];
    appMenuItem.submenu = appMenu;

    NSMenuItem *windowMenuItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:windowMenuItem];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenu addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
    [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    windowMenuItem.submenu = windowMenu;

    return mainMenu;
}

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        app.mainMenu = makeMainMenu();

        MCAppDelegate *delegate = [[MCAppDelegate alloc] init];
        app.delegate = delegate;

        [app run];
    }
    return 0;
}
