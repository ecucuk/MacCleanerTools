#import "MCSettingsWindowController.h"

#import "MCSettings.h"

namespace {

NSTextField *note(NSString *text) {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.textColor = NSColor.secondaryLabelColor;
    label.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    label.preferredMaxLayoutWidth = 380;
    return label;
}

NSTextField *rowTitle(NSString *text) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.alignment = NSTextAlignmentRight;
    return label;
}

// A tab's content: a two-column grid (title | control), padded, sized to fit.
NSViewController *tab(NSString *identifier, NSString *title, NSArray<NSArray<NSView *> *> *rows) {
    NSGridView *grid = [NSGridView gridViewWithViews:rows];
    grid.rowSpacing = 10;
    grid.columnSpacing = 8;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    grid.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *container = [[NSView alloc] initWithFrame:NSZeroRect];
    [container addSubview:grid];
    [NSLayoutConstraint activateConstraints:@[
        [grid.topAnchor constraintEqualToAnchor:container.topAnchor constant:20],
        [grid.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-20],
        [grid.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:24],
        [grid.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-24],
        [container.widthAnchor constraintGreaterThanOrEqualToConstant:520],
    ]];

    NSViewController *controller = [[NSViewController alloc] init];
    controller.view = container;
    controller.title = title;
    controller.identifier = identifier;
    controller.preferredContentSize = container.fittingSize;
    return controller;
}

} // namespace

@interface MCSettingsWindowController ()
@property(nonatomic, strong) NSTabViewController *tabs;
@property(nonatomic, strong) NSButton *splashBox;
@property(nonatomic, strong) NSPopUpButton *launchPopUp;
@property(nonatomic, strong) NSButton *updatesBox;
@property(nonatomic, strong) NSPopUpButton *largeFilesPopUp;
@property(nonatomic, strong) NSButton *idleBox;
@property(nonatomic, strong) NSPopUpButton *appearancePopUp;
@property(nonatomic, strong) NSButton *offlineBox;
@end

@implementation MCSettingsWindowController

+ (instancetype)shared {
    static MCSettingsWindowController *shared;
    if (shared == nil) {
        shared = [[MCSettingsWindowController alloc] init];
    }
    return shared;
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 200)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
    window.releasedWhenClosed = NO;
    if ((self = [super initWithWindow:window])) {
        [self buildTabs];
        window.contentViewController = self.tabs;
        // The window title names the selected tab, as in System Settings.
        [self.tabs addObserver:self forKeyPath:@"selectedTabViewItemIndex" options:NSKeyValueObservingOptionInitial
                       context:nil];
        [window center];
    }
    return self;
}

- (void)buildTabs {
    self.splashBox = [NSButton checkboxWithTitle:@"Show the splash screen at launch" target:self
                                          action:@selector(changed:)];
    self.launchPopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.launchPopUp addItemsWithTitles:@[ @"Home", @"Last used tool" ]];
    self.launchPopUp.target = self;
    self.launchPopUp.action = @selector(changed:);
    self.updatesBox = [NSButton checkboxWithTitle:@"Check for MacCleaner updates automatically" target:self
                                           action:@selector(changed:)];

    NSPopUpButton *modePopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [modePopUp addItemWithTitle:@"Move to Trash"];
    modePopUp.enabled = NO; // documents the safety model; not a setting
    self.largeFilesPopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (NSNumber *megabytes in MCSettings.largeFilesChoicesMB) {
        [self.largeFilesPopUp addItemWithTitle:[MCSettings labelForMegabytes:megabytes.integerValue]];
        self.largeFilesPopUp.lastItem.tag = megabytes.integerValue;
    }
    self.largeFilesPopUp.target = self;
    self.largeFilesPopUp.action = @selector(changed:);
    self.idleBox = [NSButton checkboxWithTitle:@"Select idle helpers by default in Optimize" target:self
                                        action:@selector(changed:)];

    self.appearancePopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.appearancePopUp addItemsWithTitles:@[ @"System", @"Light", @"Dark" ]];
    self.appearancePopUp.target = self;
    self.appearancePopUp.action = @selector(changed:);

    self.offlineBox = [NSButton checkboxWithTitle:@"Offline mode" target:self action:@selector(changed:)];

    NSView *empty = [NSGridCell emptyContentView];
    self.tabs = [[NSTabViewController alloc] init];
    self.tabs.tabStyle = NSTabViewControllerTabStyleToolbar;
    NSArray<NSViewController *> *pages = @[
        tab(@"general", @"General", @[
            @[ rowTitle(@"Launch:"), self.splashBox ],
            @[ rowTitle(@"Open at launch:"), self.launchPopUp ],
            @[ rowTitle(@"Updates:"), self.updatesBox ],
        ]),
        tab(@"cleaning", @"Cleaning", @[
            @[ rowTitle(@"Storage Cleaner starts in:"), modePopUp ],
            @[ empty, note(@"MacCleaner always starts in Trash mode. Choose Delete permanently per clean.") ],
            @[ rowTitle(@"Large Files minimum size:"), self.largeFilesPopUp ],
            @[ rowTitle(@"Optimize:"), self.idleBox ],
            @[ empty, note(@"Idle helpers are alive but unused; closing one reloads its tab or window.") ],
        ]),
        tab(@"appearance", @"Appearance", @[
            @[ rowTitle(@"Appearance:"), self.appearancePopUp ],
        ]),
        tab(@"privacy", @"Privacy", @[
            @[ rowTitle(@"Network:"), self.offlineBox ],
            @[ empty, note(@"MacCleaner makes no network requests. Check for Updates and the Updater tool are "
                           @"turned off, and File Organizer uses only places it already looked up.") ],
        ]),
    ];
    NSDictionary<NSString *, NSString *> *symbols =
        @{ @"general" : @"gearshape", @"cleaning" : @"trash", @"appearance" : @"paintbrush", @"privacy" : @"hand.raised" };
    for (NSViewController *page in pages) {
        NSTabViewItem *item = [NSTabViewItem tabViewItemWithViewController:page];
        item.label = page.title;
        item.identifier = page.identifier;
        if (@available(macOS 11.0, *)) {
            item.image = [NSImage imageWithSystemSymbolName:symbols[page.identifier] accessibilityDescription:page.title];
        }
        [self.tabs addTabViewItem:item];
    }
    [self refresh];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change
                       context:(void *)context {
    const NSInteger index = self.tabs.selectedTabViewItemIndex;
    if (index >= 0 && index < (NSInteger)self.tabs.tabViewItems.count) {
        self.window.title = self.tabs.tabViewItems[(NSUInteger)index].label;
    }
}

- (void)refresh {
    self.splashBox.state = MCSettings.showSplash ? NSControlStateValueOn : NSControlStateValueOff;
    [self.launchPopUp selectItemAtIndex:MCSettings.launchTool];
    self.updatesBox.state = MCSettings.checkUpdatesAtLaunch ? NSControlStateValueOn : NSControlStateValueOff;
    [self.largeFilesPopUp selectItemWithTag:MCSettings.largeFilesMinSizeMB];
    self.idleBox.state = MCSettings.idleHelperRuleDefault ? NSControlStateValueOn : NSControlStateValueOff;
    [self.appearancePopUp selectItemAtIndex:MCSettings.appearance];
    self.offlineBox.state = MCSettings.offlineMode ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)changed:(id)sender {
    if (sender == self.splashBox) {
        MCSettings.showSplash = self.splashBox.state == NSControlStateValueOn;
    } else if (sender == self.launchPopUp) {
        MCSettings.launchTool = (MCLaunchTool)self.launchPopUp.indexOfSelectedItem;
    } else if (sender == self.updatesBox) {
        MCSettings.checkUpdatesAtLaunch = self.updatesBox.state == NSControlStateValueOn;
    } else if (sender == self.largeFilesPopUp) {
        MCSettings.largeFilesMinSizeMB = self.largeFilesPopUp.selectedTag;
    } else if (sender == self.idleBox) {
        MCSettings.idleHelperRuleDefault = self.idleBox.state == NSControlStateValueOn;
    } else if (sender == self.appearancePopUp) {
        MCSettings.appearance = (MCAppearance)self.appearancePopUp.indexOfSelectedItem;
    } else if (sender == self.offlineBox) {
        MCSettings.offlineMode = self.offlineBox.state == NSControlStateValueOn;
    }
}

- (void)showTab:(NSString *)identifier {
    [self refresh];
    const NSInteger index = [self.tabs.tabView indexOfTabViewItemWithIdentifier:identifier];
    if (index != NSNotFound) {
        self.tabs.selectedTabViewItemIndex = index;
    }
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
}

- (void)showWindow:(id)sender {
    [self refresh];
    [super showWindow:sender];
}

@end
