#import "MCUninstallerViewController.h"

#import "MCFullDiskAccess.h"
#import "MCHeroView.h"
#import "MCTheme.h"
#import "MCToolBanner.h"
#import "MCUninstallerModel.h"

#include "maccleaner/format.hpp"

namespace {

NSString *const kAppColumn = @"app";
NSString *const kVersionColumn = @"version";
NSString *const kSizeColumn = @"size";
NSString *const kSelectColumn = @"select";
NSString *const kKindColumn = @"kind";
NSString *const kPathColumn = @"path";
NSString *const kNoteColumn = @"note";
const NSTimeInterval kQuitTimeout = 10;

NSString *const kHomebrewNote = @"Installed with Homebrew. Also remove it with `brew uninstall --cask` "
                                @"(see `brew list --cask`), or Homebrew will think it is still installed.";

NSString *bytesText(uint64_t bytes) {
    return [NSString stringWithUTF8String:maccleaner::humanReadableBytes(bytes).c_str()];
}

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

NSTableView *makeTable(id<NSTableViewDataSource, NSTableViewDelegate> owner, NSString *flexible,
                       NSArray<NSArray *> *columns) {
    NSTableView *table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    for (NSArray *c in columns) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:c[0]];
        column.title = c[1];
        column.width = [c[2] doubleValue];
        if (![c[0] isEqualToString:flexible]) {
            column.resizingMask = NSTableColumnNoResizing; // only one column takes the spare width
        }
        [table addTableColumn:column];
    }
    table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    table.dataSource = owner;
    table.delegate = owner;
    table.rowHeight = 24;
    return table;
}

NSScrollView *cardFor(NSTableView *table) {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.documentView = table;
    scroll.hasVerticalScroller = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [MCTheme styleCard:scroll];
    return scroll;
}

} // namespace

@interface MCUninstallerViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic, strong) MCUninstallerModel *model;
@property(nonatomic, copy) NSArray<MCAppRow *> *apps;
@property(nonatomic, copy) NSArray<MCAppRow *> *visibleApps; // `apps` through the search field
@property(nonatomic, strong, nullable) MCAppRow *reviewedApp;
@property(nonatomic, copy) NSArray<MCLeftoverRow *> *reviewRows;
/// Row path -> outcome text, after an uninstall.
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *outcomes;
@property(nonatomic) BOOL loading;
@property(nonatomic) BOOL hasLoaded;
@property(nonatomic) BOOL uninstalling; // the quit wait and the removal
@property(nonatomic) BOOL ignoreSelection;

@property(nonatomic, strong) MCHeroView *hero;
@property(nonatomic, strong) MCToolBanner *banner;
@property(nonatomic, strong) NSSearchField *searchField;
@property(nonatomic, strong) NSTableView *appTable;
@property(nonatomic, strong) NSTableView *reviewTable;
@property(nonatomic, strong) NSTextField *homebrewLabel;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSButton *rescanButton;
@property(nonatomic, strong) NSButton *uninstallButton;
@end

@implementation MCUninstallerViewController

- (instancetype)init {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _model = [[MCUninstallerModel alloc] init];
        _apps = @[];
        _visibleApps = @[];
        _reviewRows = @[];
        _outcomes = @{};
    }
    return self;
}

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 720, 560)];

    self.appTable = makeTable(self, kAppColumn, @[
        @[ kAppColumn, @"App", @260 ], @[ kVersionColumn, @"Version", @110 ], @[ kSizeColumn, @"Size", @90 ]
    ]);
    self.reviewTable = makeTable(self, kPathColumn, @[
        @[ kSelectColumn, @"", @24 ], @[ kKindColumn, @"Kind", @110 ], @[ kPathColumn, @"Path", @260 ],
        @[ kSizeColumn, @"Size", @80 ], @[ kNoteColumn, @"", @150 ]
    ]);
    NSScrollView *appScroll = cardFor(self.appTable);
    NSScrollView *reviewScroll = cardFor(self.reviewTable);

    self.searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    self.searchField.placeholderString = @"Search apps";
    self.searchField.target = self;
    self.searchField.action = @selector(search:);
    self.searchField.translatesAutoresizingMaskIntoConstraints = NO;

    self.homebrewLabel = [NSTextField wrappingLabelWithString:@""];
    [self.homebrewLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                 forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.homebrewLabel.textColor = NSColor.systemOrangeColor;
    self.homebrewLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.statusLabel = changingLabel(@"");
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.rescanButton = [MCGlassButton buttonWithTitle:@"Rescan" style:MCGlassButtonStylePill
                                                  tool:MCToolUninstaller target:self action:@selector(scan:)];
    self.uninstallButton = [MCGlassButton buttonWithTitle:@"Uninstall" style:MCGlassButtonStylePillPrimary
                                                     tool:MCToolUninstaller target:self action:@selector(uninstall:)];
    self.banner = [[MCToolBanner alloc] initWithTool:MCToolUninstaller symbol:[MCTheme symbolForTool:MCToolUninstaller]];
    self.banner.actions = @[ self.rescanButton, self.uninstallButton ];

    self.hero = [[MCHeroView alloc] initWithTool:MCToolUninstaller
                                          symbol:[MCTheme symbolForTool:MCToolUninstaller]
                                           title:@"Uninstaller"
                                        subtitle:@"Remove apps together with their support files, caches and preferences."];
    self.hero.actions = @[ [MCGlassButton buttonWithTitle:@"Scan" style:MCGlassButtonStyleRound
                                                     tool:MCToolUninstaller target:self action:@selector(scan:)] ];

    for (NSView *view in @[ self.banner, self.searchField, appScroll, reviewScroll, self.homebrewLabel,
                            self.statusLabel, self.hero ]) {
        [self.view addSubview:view];
    }
    const CGFloat margin = 16;
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray array];
    for (NSView *view in @[ self.banner, self.searchField, appScroll, reviewScroll, self.homebrewLabel,
                            self.statusLabel ]) {
        [constraints addObject:[view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin]];
        [constraints addObject:[view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin]];
    }
    [constraints addObjectsFromArray:@[
        [self.banner.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.searchField.topAnchor constraintEqualToAnchor:self.banner.bottomAnchor constant:12],
        [appScroll.topAnchor constraintEqualToAnchor:self.searchField.bottomAnchor constant:8],
        [reviewScroll.topAnchor constraintEqualToAnchor:appScroll.bottomAnchor constant:12],
        [reviewScroll.heightAnchor constraintEqualToAnchor:appScroll.heightAnchor],
        [self.homebrewLabel.topAnchor constraintEqualToAnchor:reviewScroll.bottomAnchor constant:8],
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.homebrewLabel.bottomAnchor constant:8],
        [self.statusLabel.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-margin],

        [self.hero.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.hero.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.hero.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.hero.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
    [NSLayoutConstraint activateConstraints:constraints];

    [self updateState];
}

- (NSArray<MCLeftoverRow *> *)checkedRows {
    NSMutableArray<MCLeftoverRow *> *rows = [NSMutableArray array];
    for (MCLeftoverRow *row in self.reviewRows) {
        if (row.selected && !row.needsAdmin) {
            [rows addObject:row];
        }
    }
    return rows;
}

/// The start screen until the first scan; afterwards the results stay.
- (void)updateState {
    if (self.outcomes.count == 0) {
        self.banner.value = [NSString stringWithFormat:@"%lu", (unsigned long)self.apps.count];
        self.banner.caption = self.apps.count == 1 ? @"app installed" : @"apps installed";
    }
    self.rescanButton.enabled = !self.loading && !self.uninstalling;
    self.uninstallButton.enabled = !self.loading && !self.uninstalling && self.reviewedApp != nil &&
                                   self.outcomes.count == 0 && self.checkedRows.count > 0;
    self.homebrewLabel.stringValue = self.reviewedApp.homebrew ? kHomebrewNote : @"";

    const BOOL presented = !self.hasLoaded;
    [self.hero setPresented:presented];
    if (!presented) {
        return;
    }
    if (self.loading) {
        [self.hero showScanningWithStatus:@"Reading installed apps…"];
    } else {
        [self.hero showIdleWithMessage:@"Lists your apps. Nothing is removed until you click Uninstall."];
    }
}

#pragma mark - Actions

- (void)scan:(id)sender {
    if (self.loading || self.uninstalling) {
        return;
    }
    self.loading = YES;
    self.statusLabel.stringValue = @"Reading installed apps…";
    [self updateState];
    __weak MCUninstallerViewController *weakSelf = self;
    [self.model loadApps:^(NSArray<MCAppRow *> *apps) {
        MCUninstallerViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        strongSelf.loading = NO;
        strongSelf.hasLoaded = YES;
        strongSelf.apps = apps;
        [strongSelf showReviewForApp:nil rows:@[]];
        [strongSelf applySearch];
        strongSelf.statusLabel.stringValue = @"Select an app to see what it left on this Mac.";
        [strongSelf updateState];
    }
        sizeUpdated:^(MCAppRow *app) {
            [weakSelf reloadApp:app];
        }];
}

// ⌘F, forwarded by the main window.
- (void)focusSearchField:(id)sender {
    if (!self.searchField.hidden) {
        [self.view.window makeFirstResponder:self.searchField];
    }
}

- (void)search:(id)sender {
    [self applySearch];
}

- (void)applySearch {
    NSString *query = self.searchField.stringValue;
    if (query.length == 0) {
        self.visibleApps = self.apps;
    } else {
        NSPredicate *match = [NSPredicate predicateWithFormat:@"name CONTAINS[cd] %@ OR bundleId CONTAINS[cd] %@",
                                                              query, query];
        self.visibleApps = [self.apps filteredArrayUsingPredicate:match];
    }
    // Keep the reviewed app selected if it is still visible; never start a new review here.
    self.ignoreSelection = YES;
    [self.appTable reloadData];
    const NSUInteger row = self.reviewedApp != nil ? [self.visibleApps indexOfObjectIdenticalTo:self.reviewedApp]
                                                   : NSNotFound;
    if (row != NSNotFound) {
        [self.appTable selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    } else {
        [self.appTable deselectAll:nil];
    }
    self.ignoreSelection = NO;
}

- (void)reloadApp:(MCAppRow *)app {
    const NSUInteger row = [self.visibleApps indexOfObjectIdenticalTo:app];
    if (row != NSNotFound) {
        [self.appTable reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:row]
                                 columnIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)[self.appTable
                                                                                 columnWithIdentifier:kSizeColumn]]];
    }
}

- (void)showReviewForApp:(nullable MCAppRow *)app rows:(NSArray<MCLeftoverRow *> *)rows {
    self.reviewedApp = app;
    self.reviewRows = rows;
    self.outcomes = @{};
    [self.reviewTable reloadData];
    [self updateState];
}

- (void)startReviewOfApp:(MCAppRow *)app {
    [self showReviewForApp:app rows:@[]];
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Looking for files of %@…", app.name];
    __weak MCUninstallerViewController *weakSelf = self;
    [self.model loadLeftoversForApp:app
                               done:^(NSArray<MCLeftoverRow *> *rows) {
                                   MCUninstallerViewController *strongSelf = weakSelf;
                                   if (strongSelf == nil || strongSelf.reviewedApp != app || strongSelf.uninstalling) {
                                       return; // the user picked another app meanwhile
                                   }
                                   [strongSelf showReviewForApp:app rows:rows];
                                   uint64_t total = 0;
                                   for (MCLeftoverRow *row in rows) {
                                       total += row.needsAdmin ? 0 : row.sizeBytes;
                                   }
                                   strongSelf.statusLabel.stringValue =
                                       [NSString stringWithFormat:@"%@: %lu item(s), %@ removable.", app.name,
                                                                  (unsigned long)rows.count, bytesText(total)];
                               }];
}

- (void)toggleSelected:(NSButton *)sender {
    self.reviewRows[(NSUInteger)sender.tag].selected = sender.state == NSControlStateValueOn;
    [self updateState];
}

- (void)uninstall:(id)sender {
    MCAppRow *app = self.reviewedApp;
    NSArray<MCLeftoverRow *> *rows = self.checkedRows;
    if (app == nil || rows.count == 0 || self.uninstalling) {
        return;
    }
    NSArray<NSRunningApplication *> *running = [NSRunningApplication runningApplicationsWithBundleIdentifier:app.bundleId];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"Move %lu item(s) of %@ to the Trash?", (unsigned long)rows.count,
                                                   app.name];
    alert.informativeText = running.count > 0
                                ? [NSString stringWithFormat:@"%@ is open. It will be asked to quit first. You can "
                                                             @"put the items back from the Trash.", app.name]
                                : @"You can put the items back from the Trash.";
    [alert addButtonWithTitle:@"Uninstall"];
    [alert addButtonWithTitle:@"Cancel"];
    __weak MCUninstallerViewController *weakSelf = self;
    [alert beginSheetModalForWindow:self.view.window
                  completionHandler:^(NSModalResponse response) {
                      if (response != NSAlertFirstButtonReturn) {
                          return;
                      }
                      MCUninstallerViewController *strongSelf = weakSelf;
                      strongSelf.uninstalling = YES;
                      [strongSelf updateState];
                      for (NSRunningApplication *instance in running) {
                          [instance terminate];
                      }
                      if (running.count > 0) {
                          strongSelf.statusLabel.stringValue = [NSString stringWithFormat:@"Waiting for %@ to quit…",
                                                                                          app.name];
                      }
                      [strongSelf waitForQuit:running
                                     deadline:[NSDate dateWithTimeIntervalSinceNow:kQuitTimeout]
                                         then:^(BOOL quit) {
                                             [weakSelf finishUninstallOf:app rows:rows quit:quit];
                                         }];
                  }];
}

/// Polls every 0.25 s until each instance has terminated or `deadline` passes.
- (void)waitForQuit:(NSArray<NSRunningApplication *> *)instances
           deadline:(NSDate *)deadline
               then:(void (^)(BOOL quit))then {
    BOOL quit = YES;
    for (NSRunningApplication *instance in instances) {
        quit = quit && instance.terminated;
    }
    if (quit || deadline.timeIntervalSinceNow <= 0) {
        then(quit);
        return;
    }
    __weak MCUninstallerViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf waitForQuit:instances deadline:deadline then:then];
    });
}

- (void)finishUninstallOf:(MCAppRow *)app rows:(NSArray<MCLeftoverRow *> *)rows quit:(BOOL)quit {
    if (!quit) {
        self.uninstalling = NO;
        self.statusLabel.stringValue = [NSString stringWithFormat:@"%@ did not quit", app.name];
        [self updateState];
        return;
    }
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Moving %@ to the Trash…", app.name];
    __weak MCUninstallerViewController *weakSelf = self;
    [self.model uninstallApp:app
                       items:rows
                        done:^(NSArray<MCRemovalRow *> *results, NSString *refusal) {
                            MCUninstallerViewController *strongSelf = weakSelf;
                            if (strongSelf == nil) {
                                return;
                            }
                            strongSelf.uninstalling = NO;
                            if (refusal != nil) {
                                strongSelf.statusLabel.stringValue = refusal;
                                [strongSelf updateState];
                                return;
                            }
                            [strongSelf showResults:results ofApp:app];
                        }];
}

- (void)showResults:(NSArray<MCRemovalRow *> *)results ofApp:(MCAppRow *)app {
    uint64_t freed = 0;
    NSUInteger failed = 0;
    BOOL bundleGone = NO;
    NSMutableDictionary<NSString *, NSString *> *outcomes = [NSMutableDictionary dictionary];
    for (MCRemovalRow *result in results) {
        outcomes[result.path] = result.ok ? @"Moved to Trash" : result.error;
        freed += result.ok ? result.sizeBytes : 0;
        failed += result.ok ? 0 : 1;
        bundleGone = bundleGone || (result.ok && [result.path isEqualToString:app.path]);
    }
    self.outcomes = outcomes;
    [self.reviewTable reloadData];
    if (bundleGone) {
        NSMutableArray<MCAppRow *> *apps = [self.apps mutableCopy];
        [apps removeObjectIdenticalTo:app];
        self.apps = apps;
        [self applySearch];
    }
    self.banner.value = bytesText(freed);
    self.banner.caption = [NSString stringWithFormat:bundleGone ? @"freed · %@ moved to the Trash"
                                                                : @"freed · leftovers of %@ moved to the Trash",
                                                                app.name];
    self.statusLabel.stringValue =
        failed == 0 ? [NSString stringWithFormat:@"Moved %lu item(s) to the Trash.", (unsigned long)results.count]
                    : [NSString stringWithFormat:@"Moved %lu item(s) to the Trash; %lu failed (see the list).",
                                                 (unsigned long)(results.count - failed), (unsigned long)failed];
    [self updateState];
    for (MCRemovalRow *result in results) {
        if (!result.ok && [MCFullDiskAccess isAccessError:result.error]) {
            [MCFullDiskAccess presentIfNeededForWindow:self.view.window];
            break;
        }
    }
}

#pragma mark - NSTableViewDataSource / Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)(tableView == self.appTable ? self.visibleApps.count : self.reviewRows.count);
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    return tableView == self.appTable && !self.uninstalling; // review rows act through their checkbox
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (notification.object != self.appTable || self.ignoreSelection) {
        return;
    }
    const NSInteger row = self.appTable.selectedRow;
    if (row >= 0 && self.visibleApps[(NSUInteger)row] != self.reviewedApp) {
        [self startReviewOfApp:self.visibleApps[(NSUInteger)row]];
    }
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSString *identifier = tableColumn.identifier;
    if (tableView == self.appTable) {
        MCAppRow *app = self.visibleApps[(NSUInteger)row];
        if ([identifier isEqualToString:kAppColumn]) {
            NSImageView *icon = [NSImageView imageViewWithImage:[NSWorkspace.sharedWorkspace iconForFile:app.path]];
            icon.imageScaling = NSImageScaleProportionallyUpOrDown;
            [icon.widthAnchor constraintEqualToConstant:18].active = YES;
            [icon.heightAnchor constraintEqualToConstant:18].active = YES;
            NSTextField *name = changingLabel(app.name);
            NSStackView *cell = [NSStackView stackViewWithViews:@[ icon, name ]];
            cell.spacing = 6;
            cell.toolTip = [NSString stringWithFormat:@"%@\n%@", app.bundleId, app.path];
            return cell;
        }
        NSTextField *field = changingLabel([identifier isEqualToString:kVersionColumn] ? app.version
                                           : app.sizeBytes > 0                       ? bytesText(app.sizeBytes)
                                                                                     : @"");
        field.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize weight:NSFontWeightRegular];
        return field;
    }

    MCLeftoverRow *item = self.reviewRows[(NSUInteger)row];
    if ([identifier isEqualToString:kSelectColumn]) {
        NSButton *box = [NSButton checkboxWithTitle:@"" target:self action:@selector(toggleSelected:)];
        box.state = item.selected && !item.needsAdmin ? NSControlStateValueOn : NSControlStateValueOff;
        box.enabled = !item.needsAdmin && self.outcomes.count == 0 && !self.uninstalling;
        box.tag = row;
        return box;
    }
    NSString *outcome = self.outcomes[item.path];
    NSString *text = [identifier isEqualToString:kKindColumn] ? item.kind
                     : [identifier isEqualToString:kPathColumn]
                         ? item.path.stringByAbbreviatingWithTildeInPath
                     : [identifier isEqualToString:kSizeColumn] ? bytesText(item.sizeBytes)
                     : outcome != nil                           ? outcome
                     : item.needsAdmin                          ? @"Needs admin"
                                                                : @"";
    NSTextField *field = changingLabel(text);
    if ([identifier isEqualToString:kPathColumn]) {
        field.lineBreakMode = NSLineBreakByTruncatingMiddle;
        field.toolTip = item.path;
    } else if ([identifier isEqualToString:kSizeColumn]) {
        field.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize weight:NSFontWeightRegular];
    } else if ([identifier isEqualToString:kNoteColumn]) {
        field.toolTip = text.length > 0 ? text : nil;
        field.textColor = outcome != nil && ![outcome isEqualToString:@"Moved to Trash"] ? NSColor.systemRedColor
                                                                                          : NSColor.secondaryLabelColor;
    }
    if (item.needsAdmin) {
        field.textColor = NSColor.tertiaryLabelColor;
    }
    return field;
}

@end
