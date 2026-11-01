// GUI entry point. Sets up NSApplication programmatically (no xib) and hands
// off to MCMainWindowController; all cleanup logic lives in maccleaner_core,
// shared with the mac_cleaner CLI.

#import <AppKit/AppKit.h>

#import "MCMainWindowController.h"
#import "MCSettings.h"
#import "MCSettingsWindowController.h"
#import "MCSplashWindow.h"
#import "MCUpdateChecker.h"

@interface MCAppDelegate : NSObject <NSApplicationDelegate, NSMenuItemValidation>
@property(nonatomic, strong) MCMainWindowController *windowController;
@property(nonatomic, strong) MCSplashWindow *splash;
@property(nonatomic, strong) NSMenu *viewMenu;
@end

@implementation MCAppDelegate

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    [MCSettings registerDefaults];
    [MCSettings applyAppearance];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // Floats above the main window, which is built and shown behind it, so
    // the splash adds no time to launch.
    if (MCSettings.showSplash) {
        self.splash = [[MCSplashWindow alloc] init];
        [self.splash showForSeconds:0.6];
    }

    self.windowController = [[MCMainWindowController alloc] init];
    [self fillViewMenu];
    [self.windowController showWindow:nil];
    [self.windowController.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    // After the splash and any welcome window, so the dialogs do not stack.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [MCUpdateChecker.shared checkAutomaticallyIfDue];
    });
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

// One item per sidebar row, so a new tool gets its menu item and shortcut
// without menu code: Home is ⌘0, the others ⌘1… in sidebar order.
- (void)fillViewMenu {
    NSArray<NSString *> *titles = self.windowController.toolTitles;
    NSInteger digit = 1;
    for (NSUInteger i = 0; i < titles.count; ++i) {
        const BOOL home = [self.windowController toolAtIndex:(NSInteger)i] == MCToolHome;
        NSString *key = home ? @"0" : (digit <= 9 ? [NSString stringWithFormat:@"%ld", (long)digit++] : @"");
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:titles[i] action:@selector(selectToolFromMenu:)
                                               keyEquivalent:key];
        item.target = self;
        item.tag = (NSInteger)i;
        [self.viewMenu insertItem:item atIndex:(NSInteger)i]; // above the separator
    }
}

- (void)selectToolFromMenu:(NSMenuItem *)sender {
    [self.windowController selectToolAtIndex:sender.tag];
    [self.windowController showWindow:nil];
}

#pragma mark Dialogs

- (IBAction)checkForUpdates:(id)sender {
    [MCUpdateChecker.shared checkManually];
}

- (IBAction)showSettings:(id)sender {
    [MCSettingsWindowController.shared showTab:@"general"];
}

// Each dialog lands in its own change; until then its item stays disabled
// (see validateMenuItem:) rather than doing nothing when clicked.
- (IBAction)showAbout:(id)sender {}
- (IBAction)showHelp:(id)sender {}
- (IBAction)showWelcomeTour:(id)sender {}
- (IBAction)showWhatsNew:(id)sender {}
- (IBAction)reportIssue:(id)sender {}
- (IBAction)showFullDiskAccess:(id)sender {}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    const SEL pending[] = {
        @selector(showAbout:),
        @selector(showHelp:),        @selector(showWelcomeTour:), @selector(showWhatsNew:),
        @selector(reportIssue:),     @selector(showFullDiskAccess:),
    };
    for (SEL action : pending) {
        if (item.action == action) {
            return NO;
        }
    }
    return YES;
}

@end

static NSMenuItem *addItem(NSMenu *menu, NSString *title, SEL action, NSString *key,
                           NSEventModifierFlags modifiers = NSEventModifierFlagCommand) {
    NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:key];
    item.keyEquivalentModifierMask = modifiers;
    return item;
}

static NSMenu *addSubmenu(NSMenu *mainMenu, NSString *title) {
    NSMenuItem *holder = [[NSMenuItem alloc] init];
    [mainMenu addItem:holder];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:title];
    holder.submenu = menu;
    return menu;
}

// The standard macOS menu bar. Items with a nil target go down the responder
// chain: the app delegate for the dialogs, AppKit for the rest. The View
// menu's tool items are added once the main window exists (fillViewMenu).
static NSMenu *makeMainMenu(MCAppDelegate *delegate) {
    NSMenu *mainMenu = [[NSMenu alloc] init];
    const NSEventModifierFlags cmd = NSEventModifierFlagCommand;

    NSMenu *app = addSubmenu(mainMenu, @"MacCleaner");
    addItem(app, @"About MacCleaner", @selector(showAbout:), @"");
    addItem(app, @"Check for Updates…", @selector(checkForUpdates:), @"");
    [app addItem:[NSMenuItem separatorItem]];
    addItem(app, @"Settings…", @selector(showSettings:), @",");
    [app addItem:[NSMenuItem separatorItem]];
    addItem(app, @"Hide MacCleaner", @selector(hide:), @"h");
    addItem(app, @"Hide Others", @selector(hideOtherApplications:), @"h", cmd | NSEventModifierFlagOption);
    addItem(app, @"Show All", @selector(unhideAllApplications:), @"");
    [app addItem:[NSMenuItem separatorItem]];
    addItem(app, @"Quit MacCleaner", @selector(terminate:), @"q");

    NSMenu *edit = addSubmenu(mainMenu, @"Edit");
    addItem(edit, @"Undo", @selector(undo:), @"z");
    addItem(edit, @"Redo", @selector(redo:), @"z", cmd | NSEventModifierFlagShift);
    [edit addItem:[NSMenuItem separatorItem]];
    addItem(edit, @"Cut", @selector(cut:), @"x");
    addItem(edit, @"Copy", @selector(copy:), @"c");
    addItem(edit, @"Paste", @selector(paste:), @"v");
    addItem(edit, @"Select All", @selector(selectAll:), @"a");
    [edit addItem:[NSMenuItem separatorItem]];
    addItem(edit, @"Find", @selector(focusSearchField:), @"f");

    NSMenu *view = addSubmenu(mainMenu, @"View");
    [view addItem:[NSMenuItem separatorItem]];
    addItem(view, @"Enter Full Screen", @selector(toggleFullScreen:), @"f", cmd | NSEventModifierFlagControl);
    delegate.viewMenu = view;

    NSMenu *window = addSubmenu(mainMenu, @"Window");
    addItem(window, @"Close", @selector(performClose:), @"w");
    addItem(window, @"Minimize", @selector(performMiniaturize:), @"m");
    addItem(window, @"Zoom", @selector(performZoom:), @"");
    [window addItem:[NSMenuItem separatorItem]];
    addItem(window, @"Bring All to Front", @selector(arrangeInFront:), @"");
    NSApp.windowsMenu = window;

    NSMenu *help = addSubmenu(mainMenu, @"Help");
    addItem(help, @"MacCleaner Help", @selector(showHelp:), @"?");
    addItem(help, @"Welcome Tour", @selector(showWelcomeTour:), @"");
    addItem(help, @"What's New", @selector(showWhatsNew:), @"");
    [help addItem:[NSMenuItem separatorItem]];
    addItem(help, @"Report an Issue…", @selector(reportIssue:), @"");
    [help addItem:[NSMenuItem separatorItem]];
    addItem(help, @"Full Disk Access…", @selector(showFullDiskAccess:), @"");
    NSApp.helpMenu = help; // AppKit adds the search field

    return mainMenu;
}

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyRegular;

        MCAppDelegate *delegate = [[MCAppDelegate alloc] init];
        app.mainMenu = makeMainMenu(delegate);
        app.delegate = delegate;

        [app run];
    }
    return 0;
}
