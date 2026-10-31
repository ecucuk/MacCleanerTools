#import "MCAntivirusViewController.h"

#import "MCHeroView.h"
#import "MCMalwareModel.h"
#import "MCTheme.h"
#import "MCToolBanner.h"

namespace {

NSString *const kSymbol = @"shield.lefthalf.filled";

NSString *severityTitle(MCMalwareSeverity severity) {
    switch (severity) {
        case MCMalwareSeverityDetected: return @"Detected";
        case MCMalwareSeveritySuspicious: return @"Suspicious";
        case MCMalwareSeverityInfo: return @"Info";
    }
    return @"";
}

NSColor *severityColor(MCMalwareSeverity severity) {
    switch (severity) {
        case MCMalwareSeverityDetected: return NSColor.systemRedColor;
        case MCMalwareSeveritySuspicious: return NSColor.systemOrangeColor;
        case MCMalwareSeverityInfo: return NSColor.secondaryLabelColor;
    }
    return NSColor.labelColor;
}

} // namespace

@interface MCAntivirusViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic, strong) MCMalwareModel *model;
@property(nonatomic, copy) NSArray<MCMalwareFinding *> *findings;
@property(nonatomic) BOOL hasResults;
@property(nonatomic) BOOL lastScanStopped; // partial results: never claim "no threats"

@property(nonatomic, strong) MCHeroView *hero;
@property(nonatomic, strong) MCToolBanner *banner;
@property(nonatomic, strong) NSTableView *tableView;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSButton *scanButton;
@property(nonatomic, strong) NSButton *revealButton;
@property(nonatomic, strong) NSButton *trashButton;
@end

@implementation MCAntivirusViewController

- (instancetype)init {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _model = [[MCMalwareModel alloc] init];
        _findings = @[];
    }
    return self;
}

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 720, 560)];

    // --- findings ---------------------------------------------------------
    self.tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    const struct {
        NSString *identifier, *title;
        CGFloat width;
    } columns[] = {
        {@"severity", @"Severity", 80}, {@"kind", @"Kind", 90}, {@"path", @"Path", 300}, {@"reason", @"Reason", 260}};
    for (const auto &column : columns) {
        NSTableColumn *tableColumn = [[NSTableColumn alloc] initWithIdentifier:column.identifier];
        tableColumn.title = column.title;
        tableColumn.width = column.width;
        // Uniform resizing would otherwise squeeze "Suspicious" to "Sus…".
        tableColumn.minWidth = MIN(column.width, (CGFloat)90);
        [self.tableView addTableColumn:tableColumn];
    }
    self.tableView.allowsMultipleSelection = YES;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.target = self;
    self.tableView.doubleAction = @selector(revealSelection:);
    self.tableView.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.documentView = self.tableView;
    scroll.hasVerticalScroller = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [MCTheme styleCard:scroll];

    // --- status and actions ----------------------------------------------
    // Compressible, so a long path truncates instead of Auto Layout growing the window.
    self.statusLabel = [NSTextField labelWithString:@""];
    self.statusLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    [self.statusLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                               forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.scanButton = [MCGlassButton buttonWithTitle:@"Scan Again" style:MCGlassButtonStylePill
                                                tool:MCToolAntivirus target:self action:@selector(scanOrStop:)];
    self.revealButton = [MCGlassButton buttonWithTitle:@"Reveal" style:MCGlassButtonStylePill
                                                  tool:MCToolAntivirus target:self action:@selector(revealSelection:)];
    self.trashButton = [MCGlassButton buttonWithTitle:@"Move to Trash" style:MCGlassButtonStylePillPrimary
                                                 tool:MCToolAntivirus target:self action:@selector(trashSelection:)];
    self.banner = [[MCToolBanner alloc] initWithTool:MCToolAntivirus symbol:kSymbol];
    self.banner.actions = @[ self.scanButton, self.revealButton, self.trashButton ];

    self.hero = [[MCHeroView alloc] initWithTool:MCToolAntivirus
                                          symbol:kSymbol
                                           title:@"Antivirus"
                                        subtitle:@"Check downloads, apps and login agents for known Mac malware."];
    self.hero.actions = @[
        [MCGlassButton buttonWithTitle:@"Scan" style:MCGlassButtonStyleRound tool:MCToolAntivirus
                                target:self action:@selector(scanOrStop:)],
        [MCGlassButton buttonWithTitle:@"Choose Folder…" style:MCGlassButtonStylePill tool:MCToolAntivirus
                                target:self action:@selector(chooseFolder:)],
    ];
    self.hero.scanningAccessory = [MCGlassButton buttonWithTitle:@"Stop" style:MCGlassButtonStylePill
                                                            tool:MCToolAntivirus target:self
                                                          action:@selector(scanOrStop:)];

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

- (NSUInteger)threatCount {
    NSUInteger count = 0;
    for (MCMalwareFinding *finding in self.findings) {
        count += finding.severity != MCMalwareSeverityInfo;
    }
    return count;
}

/// The start screen until the first scan finishes; afterwards the results stay.
- (void)updateState {
    const BOOL busy = self.model.busy;
    const NSUInteger threats = self.threatCount;
    self.banner.value = [NSString stringWithFormat:@"%lu", (unsigned long)threats];
    self.banner.caption = self.lastScanStopped ? @"found before the scan was stopped"
                          : threats == 0       ? @"No threats found"
                                               : @"threat(s) or suspicious item(s)";
    self.scanButton.title = busy ? @"Stop" : @"Scan Again";
    const BOOL selection = self.tableView.selectedRowIndexes.count > 0;
    self.revealButton.enabled = !busy && selection;
    self.trashButton.enabled = !busy && selection;

    const BOOL presented = !self.hasResults;
    [self.hero setPresented:presented];
    if (!presented) {
        return;
    }
    if (busy) {
        [self.hero showScanningWithStatus:@"Loading signatures…"];
    } else {
        [self.hero showIdleWithMessage:@"Scans Downloads, Desktop, Applications and launch agents. "
                                       @"Not a real-time antivirus; XProtect still runs."];
    }
}

- (void)setStatus:(NSString *)status {
    self.statusLabel.stringValue = status;
    if (self.hero.presented) {
        [self.hero setStatus:status];
    }
}

#pragma mark - Actions

- (void)scanOrStop:(id)sender {
    if (self.model.busy) {
        [self.model cancel];
        return;
    }
    [self scanFolder:nil];
}

- (void)chooseFolder:(id)sender {
    if (self.model.busy) {
        return;
    }
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.prompt = @"Scan";
    __weak MCAntivirusViewController *weakSelf = self;
    [panel beginSheetModalForWindow:self.view.window
                  completionHandler:^(NSModalResponse response) {
                      if (response == NSModalResponseOK && panel.URLs.count > 0) {
                          [weakSelf scanFolder:panel.URLs.firstObject.path];
                      }
                  }];
}

- (void)scanFolder:(nullable NSString *)folder {
    __weak MCAntivirusViewController *weakSelf = self;
    [self setStatus:@"Loading signatures…"];
    [self.model scanFolder:folder
        progress:^(NSString *status) {
            [weakSelf setStatus:status];
        }
        completion:^(NSArray<MCMalwareFinding *> *findings, uint64_t filesScanned, uint64_t skippedLarge,
                     NSUInteger ruleCount, BOOL cancelled) {
            MCAntivirusViewController *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            strongSelf.findings = findings;
            strongSelf.hasResults = YES;
            strongSelf.lastScanStopped = cancelled;
            [strongSelf.tableView reloadData];
            [strongSelf setStatus:[NSString stringWithFormat:@"%@%llu file(s) checked against %lu signatures%@. "
                                                             @"Double-click a row to reveal it.",
                                                             cancelled ? @"Stopped: only " : @"",
                                                             (unsigned long long)filesScanned, (unsigned long)ruleCount,
                                                             skippedLarge > 0
                                                                 ? [NSString stringWithFormat:@"; %llu over 64 MB skipped",
                                                                                              (unsigned long long)skippedLarge]
                                                                 : @""]];
            [strongSelf updateState];
        }];
    [self updateState];
}

- (NSArray<MCMalwareFinding *> *)selectedFindings {
    return [self.findings objectsAtIndexes:self.tableView.selectedRowIndexes];
}

- (void)revealSelection:(id)sender {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (MCMalwareFinding *finding in self.selectedFindings) {
        [urls addObject:[NSURL fileURLWithPath:finding.path]];
    }
    if (urls.count > 0) {
        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:urls];
    }
}

- (void)trashSelection:(id)sender {
    NSArray<MCMalwareFinding *> *selected = self.selectedFindings;
    if (self.model.busy || selected.count == 0) {
        return;
    }
    BOOL persistence = NO;
    for (MCMalwareFinding *finding in selected) {
        persistence = persistence || finding.isPersistence;
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"Move %lu item(s) to the Trash?", (unsigned long)selected.count];
    alert.informativeText =
        persistence ? @"You can put them back from the Trash. A launch agent that is already running stops at "
                      @"the next login."
                    : @"You can put them back from the Trash.";
    [alert addButtonWithTitle:@"Move to Trash"];
    [alert addButtonWithTitle:@"Cancel"];
    __weak MCAntivirusViewController *weakSelf = self;
    [alert beginSheetModalForWindow:self.view.window
                  completionHandler:^(NSModalResponse response) {
                      if (response == NSAlertFirstButtonReturn) {
                          [weakSelf performTrash:selected];
                      }
                  }];
}

- (void)performTrash:(NSArray<MCMalwareFinding *> *)selected {
    __weak MCAntivirusViewController *weakSelf = self;
    [self.model trashFindings:selected
                   completion:^(NSArray<MCMalwareFinding *> *trashed, NSArray<NSString *> *problems) {
                       MCAntivirusViewController *strongSelf = weakSelf;
                       if (strongSelf == nil) {
                           return;
                       }
                       NSMutableArray<MCMalwareFinding *> *remaining = [strongSelf.findings mutableCopy];
                       [remaining removeObjectsInArray:trashed];
                       strongSelf.findings = remaining;
                       [strongSelf.tableView reloadData];
                       [strongSelf setStatus:[NSString stringWithFormat:@"Moved %lu item(s) to the Trash; %lu refused.",
                                                                        (unsigned long)trashed.count,
                                                                        (unsigned long)problems.count]];
                       [strongSelf updateState];
                       if (problems.count > 0) {
                           NSAlert *alert = [[NSAlert alloc] init];
                           alert.messageText = [NSString stringWithFormat:@"%lu item(s) were not moved",
                                                                          (unsigned long)problems.count];
                           alert.informativeText = [[problems componentsJoinedByString:@"\n"]
                               stringByAppendingString:@"\n\nItems in /Applications or /Library need an administrator: "
                                                       @"remove them in Finder."];
                           [alert beginSheetModalForWindow:strongSelf.view.window completionHandler:nil];
                       }
                   }];
    [self updateState];
}

#pragma mark - NSTableView

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.findings.count;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    [self updateState];
}

- (nullable NSView *)tableView:(NSTableView *)tableView
            viewForTableColumn:(nullable NSTableColumn *)tableColumn
                           row:(NSInteger)row {
    MCMalwareFinding *finding = self.findings[(NSUInteger)row];
    NSString *identifier = tableColumn.identifier;
    NSTableCellView *cell = [tableView makeViewWithIdentifier:identifier owner:self];
    if (cell == nil) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = identifier;
        NSTextField *text = [NSTextField labelWithString:@""];
        text.translatesAutoresizingMaskIntoConstraints = NO;
        text.lineBreakMode = [identifier isEqualToString:@"path"] ? NSLineBreakByTruncatingMiddle
                                                                  : NSLineBreakByTruncatingTail;
        [cell addSubview:text];
        cell.textField = text;
        [NSLayoutConstraint activateConstraints:@[
            [text.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
            [text.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-2],
            [text.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }
    NSTextField *text = cell.textField;
    text.textColor = NSColor.labelColor;
    text.toolTip = nil;
    if ([identifier isEqualToString:@"severity"]) {
        text.stringValue = severityTitle(finding.severity);
        text.textColor = severityColor(finding.severity);
    } else if ([identifier isEqualToString:@"kind"]) {
        text.stringValue = finding.kind;
    } else if ([identifier isEqualToString:@"path"]) {
        text.stringValue = finding.path.stringByAbbreviatingWithTildeInPath;
        text.toolTip = finding.path;
    } else {
        text.stringValue = finding.reason;
        text.toolTip = finding.reason;
    }
    return cell;
}

@end
