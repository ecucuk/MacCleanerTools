#import "MCUpdaterViewController.h"

#import "MCHeroView.h"
#import "MCSettings.h"
#import "MCTheme.h"
#import "MCToolBanner.h"
#import "MCUpdaterModel.h"

NSString *const MCUpdaterCachedCountKey = @"MCUpdaterCachedCount";

namespace {

NSString *const kSelectColumn = @"select";
NSString *const kNameColumn = @"name";
NSString *const kInstalledColumn = @"installed";
NSString *const kLatestColumn = @"latest";
NSString *const kActionColumn = @"action";

// A label whose text changes: compressible, so long text truncates instead
// of Auto Layout growing the window.
NSTextField *changingLabel(NSString *text) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [label setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    return label;
}

NSString *stateText(MCUpdateItem *item) {
    switch (item.state) {
        case MCUpdateRowStatePending: return @"Waiting";
        case MCUpdateRowStateUpgrading: return @"Updating…";
        case MCUpdateRowStateDone: return @"Updated";
        case MCUpdateRowStateFailed: return @"Failed";
        case MCUpdateRowStateIdle: break;
    }
    return item.pinned ? @"Pinned" : @"";
}

} // namespace

@interface MCUpdaterViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic, strong) MCUpdaterModel *model;
/// Table rows: an MCUpdateSourceStatus header, then that source's items.
@property(nonatomic, copy) NSArray *rows;
@property(nonatomic) BOOL hasChecked;
@property(nonatomic) BOOL upgrading;

@property(nonatomic, strong) MCHeroView *hero;
@property(nonatomic, strong) MCToolBanner *banner;
@property(nonatomic, strong) NSTableView *tableView;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSButton *checkButton;
@property(nonatomic, strong) NSButton *updateButton;
@property(nonatomic, strong) NSButton *heroCheckButton;
@end

@implementation MCUpdaterViewController

- (instancetype)init {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _model = [[MCUpdaterModel alloc] init];
        _rows = @[];
    }
    return self;
}

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 720, 560)];

    self.tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    const struct {
        NSString *identifier, *title;
        CGFloat width;
    } columns[] = {
        {kSelectColumn, @"", 24},
        {kNameColumn, @"Name", 220},
        {kInstalledColumn, @"Installed", 110},
        {kLatestColumn, @"Available", 110},
        {kActionColumn, @"", 150},
    };
    for (const auto &c : columns) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:c.identifier];
        column.title = c.title;
        column.width = c.width;
        if (c.identifier != kNameColumn) {
            column.resizingMask = NSTableColumnNoResizing; // only Name takes the spare width
        }
        [self.tableView addTableColumn:column];
    }
    self.tableView.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 24;

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.documentView = self.tableView;
    scroll.hasVerticalScroller = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [MCTheme styleCard:scroll];

    self.statusLabel = changingLabel(@"");
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.checkButton = [MCGlassButton buttonWithTitle:@"Check Again" style:MCGlassButtonStylePill
                                                 tool:MCToolUpdater target:self action:@selector(check:)];
    self.updateButton = [MCGlassButton buttonWithTitle:@"Update Selected" style:MCGlassButtonStylePillPrimary
                                                  tool:MCToolUpdater target:self action:@selector(updateOrStop:)];
    self.banner = [[MCToolBanner alloc] initWithTool:MCToolUpdater symbol:[MCTheme symbolForTool:MCToolUpdater]];
    self.banner.actions = @[ self.checkButton, self.updateButton ];

    self.hero = [[MCHeroView alloc] initWithTool:MCToolUpdater
                                          symbol:[MCTheme symbolForTool:MCToolUpdater]
                                           title:@"Updater"
                                        subtitle:@"Find outdated Homebrew, MacPorts, App Store and Sparkle apps."];
    self.heroCheckButton = [MCGlassButton buttonWithTitle:@"Check" style:MCGlassButtonStyleRound tool:MCToolUpdater
                                                   target:self action:@selector(check:)];
    self.hero.actions = @[ self.heroCheckButton ];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(updateState)
                                               name:MCSettingsDidChangeNotification
                                             object:nil];
    self.hero.scanningAccessory = [MCGlassButton buttonWithTitle:@"Stop" style:MCGlassButtonStylePill
                                                            tool:MCToolUpdater target:self action:@selector(stop:)];

    for (NSView *view in @[ self.banner, scroll, self.statusLabel, self.hero ]) {
        [self.view addSubview:view];
    }
    const CGFloat margin = 16;
    [NSLayoutConstraint activateConstraints:@[
        [self.banner.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.banner.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [self.banner.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],

        [scroll.topAnchor constraintEqualToAnchor:self.banner.bottomAnchor constant:12],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],

        [self.statusLabel.topAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:12],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],
        [self.statusLabel.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-margin],

        [self.hero.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.hero.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.hero.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.hero.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    [self updateState];
}

- (NSArray<MCUpdateItem *> *)selectedItems {
    NSMutableArray<MCUpdateItem *> *selected = [NSMutableArray array];
    for (MCUpdateItem *item in self.model.items) {
        if (item.selected && item.upgradable && item.state != MCUpdateRowStateDone) {
            [selected addObject:item];
        }
    }
    return selected;
}

- (NSUInteger)pendingCount {
    NSUInteger pending = 0;
    for (MCUpdateItem *item in self.model.items) {
        pending += item.state != MCUpdateRowStateDone ? 1 : 0;
    }
    return pending;
}

/// The start screen until the first check; afterwards the results stay.
- (void)updateState {
    const BOOL busy = self.model.busy;
    const NSUInteger pending = self.pendingCount;
    self.banner.value = [NSString stringWithFormat:@"%lu", (unsigned long)pending];
    self.banner.caption = pending == 1 ? @"update available" : @"updates available";
    // While a check runs, Check Again turns into its Stop.
    self.checkButton.title = busy && !self.upgrading ? @"Stop" : @"Check Again";
    // Offline mode: nothing may start a check or an upgrade (both use the
    // network); a running one can still be stopped.
    const BOOL offline = MCSettings.offlineMode;
    self.checkButton.enabled = !self.upgrading && (busy || !offline);
    self.heroCheckButton.enabled = !offline;
    self.updateButton.title = self.upgrading ? @"Stop" : @"Update Selected";
    self.updateButton.enabled = self.upgrading || (!busy && !offline && self.selectedItems.count > 0);
    NSString *const offlineText = @"Offline mode is on — Settings › Privacy";
    if (offline && !busy) {
        self.statusLabel.stringValue = offlineText;
    } else if ([self.statusLabel.stringValue isEqualToString:offlineText]) {
        self.statusLabel.stringValue = @"";
    }

    const BOOL presented = !self.hasChecked;
    [self.hero setPresented:presented];
    if (!presented) {
        return;
    }
    if (busy) {
        [self.hero showScanningWithStatus:@"Checking Homebrew, the App Store and app feeds…"];
    } else if (offline) {
        [self.hero showIdleWithMessage:@"Offline mode is on — Settings › Privacy"];
    } else {
        [self.hero showIdleWithMessage:@"Runs brew update and asks the App Store and app feeds for versions"];
    }
}

- (void)rebuildRows {
    NSMutableArray *rows = [NSMutableArray array];
    for (MCUpdateSourceStatus *source in self.model.sources) {
        [rows addObject:source];
        for (MCUpdateItem *item in self.model.items) {
            if (item.source == source.source) {
                [rows addObject:item];
            }
        }
    }
    self.rows = rows;
    [self.tableView reloadData];
}

#pragma mark - Actions

- (void)check:(id)sender {
    if (self.model.busy) {
        if (!self.upgrading) {
            [self.model cancel];
        }
        return;
    }
    if (MCSettings.offlineMode) {
        return;
    }
    self.statusLabel.stringValue = @"Checking…";
    [self.model checkWithCompletion:^{
        self.hasChecked = YES;
        for (MCUpdateItem *item in self.model.items) {
            item.selected = item.upgradable;
        }
        [self rebuildRows];
        NSUInteger failedSources = 0;
        BOOL stopped = NO;
        for (MCUpdateSourceStatus *source in self.model.sources) {
            failedSources += source.error.length > 0 ? 1 : 0;
            stopped = stopped || source.skipped;
        }
        if (!stopped) {
            [NSUserDefaults.standardUserDefaults setInteger:(NSInteger)self.pendingCount forKey:MCUpdaterCachedCountKey];
        }
        self.statusLabel.stringValue =
            stopped             ? @"Stopped. Sources marked skipped were not fully checked."
            : failedSources > 0 ? [NSString stringWithFormat:@"Checked. %lu source(s) reported an error.",
                                                             (unsigned long)failedSources]
                                : @"Checked.";
        [self updateState];
    }];
    [self updateState];
}

- (void)stop:(id)sender {
    [self.model cancel];
}

- (void)updateOrStop:(id)sender {
    if (self.upgrading) {
        [self.model cancel];
        self.statusLabel.stringValue = @"Stopping after the current item…";
        return;
    }
    NSArray<MCUpdateItem *> *items = self.selectedItems;
    if (items.count == 0 || MCSettings.offlineMode) {
        return;
    }
    self.upgrading = YES;
    [self.model upgradeItems:items
        progress:^(MCUpdateItem *item) {
            if (item.state == MCUpdateRowStateUpgrading) {
                self.statusLabel.stringValue = [NSString stringWithFormat:@"Updating %@…", item.name];
            }
            [self reloadItem:item];
        }
        completion:^(NSUInteger upgraded, NSUInteger failed, BOOL cancelled) {
            self.upgrading = NO;
            [NSUserDefaults.standardUserDefaults setInteger:(NSInteger)self.pendingCount forKey:MCUpdaterCachedCountKey];
            NSString *outcome = [NSString stringWithFormat:@"%lu updated, %lu failed", (unsigned long)upgraded,
                                                           (unsigned long)failed];
            self.statusLabel.stringValue = cancelled ? [outcome stringByAppendingString:@". Stopped."] : outcome;
            [self updateState];
        }];
    [self updateState];
}

- (void)reloadItem:(MCUpdateItem *)item {
    const NSUInteger row = [self.rows indexOfObjectIdenticalTo:item];
    if (row != NSNotFound) {
        [self.tableView reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:row]
                                  columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, (NSUInteger)self.tableView.numberOfColumns)]];
    }
}

- (void)toggleSelected:(NSButton *)sender {
    MCUpdateItem *item = self.rows[(NSUInteger)sender.tag];
    item.selected = sender.state == NSControlStateValueOn;
    [self updateState];
}

- (void)rowAction:(NSButton *)sender {
    MCUpdateItem *item = self.rows[(NSUInteger)sender.tag];
    switch (item.source) {
        case MCUpdateSourceAppStore: {
            NSString *url = [NSString stringWithFormat:@"macappstore://apps.apple.com/app/id%@", item.storeId];
            [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:url]];
            break;
        }
        case MCUpdateSourceSparkle:
            [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:item.appPath isDirectory:YES]];
            self.statusLabel.stringValue =
                [NSString stringWithFormat:@"Opened %@. Use its Check for Updates command if it does not ask.", item.name];
            break;
        case MCUpdateSourceHomebrew:
        case MCUpdateSourceMacPorts:
            [NSPasteboard.generalPasteboard clearContents];
            [NSPasteboard.generalPasteboard setString:item.manualCommand forType:NSPasteboardTypeString];
            self.statusLabel.stringValue =
                [NSString stringWithFormat:@"Copied “%@”. Paste it in Terminal.", item.manualCommand];
            break;
    }
}

#pragma mark - NSTableViewDataSource / Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.rows.count;
}

- (BOOL)tableView:(NSTableView *)tableView isGroupRow:(NSInteger)row {
    return [self.rows[(NSUInteger)row] isKindOfClass:MCUpdateSourceStatus.class];
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    return NO; // rows act through their checkbox and button
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    id object = self.rows[(NSUInteger)row];
    if ([object isKindOfClass:MCUpdateSourceStatus.class]) {
        MCUpdateSourceStatus *source = object;
        BOOL any = NO;
        for (MCUpdateItem *item in self.model.items) {
            any = any || item.source == source.source;
        }
        NSString *detail = !source.available         ? @" — not installed"
                           : source.skipped          ? @" — skipped (stopped)"
                           : source.error.length > 0 ? [@" — " stringByAppendingString:source.error]
                           : any                     ? @""
                                                     : @" — up to date";
        NSTextField *header = changingLabel([source.title stringByAppendingString:detail]);
        header.font = [NSFont boldSystemFontOfSize:NSFont.smallSystemFontSize];
        header.toolTip = source.error.length > 0 ? source.error : nil;
        return header;
    }

    MCUpdateItem *item = object;
    NSString *identifier = tableColumn.identifier;
    if ([identifier isEqualToString:kSelectColumn]) {
        if (!item.upgradable) {
            return nil;
        }
        NSButton *box = [NSButton checkboxWithTitle:@"" target:self action:@selector(toggleSelected:)];
        box.state = item.selected ? NSControlStateValueOn : NSControlStateValueOff;
        box.enabled = item.state == MCUpdateRowStateIdle || item.state == MCUpdateRowStateFailed;
        box.tag = row;
        return box;
    }
    if ([identifier isEqualToString:kActionColumn]) {
        NSString *title = nil;
        switch (item.source) {
            case MCUpdateSourceAppStore: title = @"Open in App Store"; break;
            case MCUpdateSourceSparkle: title = @"Open App"; break;
            case MCUpdateSourceMacPorts: title = @"Copy Command"; break;
            case MCUpdateSourceHomebrew:
                title = item.state == MCUpdateRowStateFailed ? @"Copy Command" : nil;
                break;
        }
        if (title == nil) {
            NSTextField *state = changingLabel(stateText(item));
            state.textColor = NSColor.secondaryLabelColor;
            return state;
        }
        NSButton *button = [NSButton buttonWithTitle:title target:self action:@selector(rowAction:)];
        button.controlSize = NSControlSizeSmall;
        button.bezelStyle = NSBezelStyleRounded;
        button.tag = row;
        button.toolTip = item.lastLine.length > 0 ? item.lastLine : item.manualCommand;
        return button;
    }

    NSString *text = [identifier isEqualToString:kNameColumn]        ? item.name
                     : [identifier isEqualToString:kInstalledColumn] ? item.installedVersion
                                                                     : item.latestVersion;
    if ([identifier isEqualToString:kNameColumn] && item.isCask) {
        text = [text stringByAppendingString:@" (cask)"];
    }
    NSTextField *field = changingLabel(text);
    field.toolTip = item.appPath.length > 0 ? item.appPath : nil;
    if (![identifier isEqualToString:kNameColumn]) {
        field.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize weight:NSFontWeightRegular];
    }
    return field;
}

@end
