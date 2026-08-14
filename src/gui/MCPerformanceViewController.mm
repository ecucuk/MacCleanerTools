#import "MCPerformanceViewController.h"

#import "MCOptimizeSheetController.h"
#import "MCProcessModel.h"

#include "maccleaner/format.hpp"

namespace {

NSString *humanSize(unsigned long long bytes) {
    return [NSString stringWithUTF8String:maccleaner::humanReadableBytes(bytes).c_str()];
}

NSString *const kCpuColumn = @"cpu";
NSString *const kMemColumn = @"mem";
NSString *const kNameColumn = @"name";
NSString *const kKindColumn = @"kind";
NSString *const kUptimeColumn = @"uptime";
NSString *const kPidColumn = @"pid";

// "Heavy" thresholds: what earns the red/orange highlight and a place in
// the Heavy filter. Deliberately conservative -- flagging half the process
// list would make the flag meaningless.
constexpr double kHeavyCpuPercent = 50.0;
constexpr unsigned long long kHeavyMemoryBytes = 1ull << 30; // 1 GB
constexpr NSTimeInterval kLongRunningSeconds = 24 * 60 * 60;
constexpr double kLongRunningCpuPercent = 10.0;

constexpr NSTimeInterval kRefreshInterval = 2.0;

enum FilterTag : NSInteger {
    FilterAll = 0,
    FilterHeavy,
    FilterApps,
    FilterBackground,
};

BOOL isHeavy(MCProcessItem *item) {
    if (item.cpuPercent >= kHeavyCpuPercent || item.memoryBytes >= kHeavyMemoryBytes) {
        return YES;
    }
    // "Long-running and loaded": old *and* still burning CPU. Age alone is
    // not a problem -- every login item is old by definition.
    return item.uptimeSeconds >= kLongRunningSeconds && item.cpuPercent >= kLongRunningCpuPercent;
}

NSString *formatUptime(NSTimeInterval seconds) {
    const unsigned long long total = (unsigned long long)MAX(0.0, seconds);
    const unsigned long long days = total / 86400;
    const unsigned long long hours = (total % 86400) / 3600;
    const unsigned long long minutes = (total % 3600) / 60;
    if (days > 0) {
        return [NSString stringWithFormat:@"%llud %lluh", days, hours];
    }
    if (hours > 0) {
        return [NSString stringWithFormat:@"%lluh %02llum", hours, minutes];
    }
    if (minutes > 0) {
        return [NSString stringWithFormat:@"%llum", minutes];
    }
    return [NSString stringWithFormat:@"%llus", total];
}

NSString *kindLabel(MCProcessKind kind) {
    switch (kind) {
        case MCProcessKindApp: return @"App";
        case MCProcessKindSystem: return @"System";
        case MCProcessKindBackground: return @"Background";
    }
    return @"?";
}

} // namespace

@interface MCPerformanceViewController () <NSTableViewDataSource, NSTableViewDelegate>

@property(nonatomic, strong) MCProcessModel *model;
@property(nonatomic, copy) NSArray<MCProcessItem *> *allItems;   // latest full refresh
@property(nonatomic, copy) NSArray<MCProcessItem *> *items;      // filtered + sorted, what the table shows

@property(nonatomic, strong) NSPopUpButton *filterPopUp;
@property(nonatomic, strong) NSButton *optimizeButton;
@property(nonatomic, strong) NSProgressIndicator *optimizeSpinner;
@property(nonatomic, strong) NSButton *pauseButton;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSTableView *tableView;
@property(nonatomic, strong) NSButton *quitButton;
@property(nonatomic, strong) NSButton *forceQuitButton;

@property(nonatomic, strong, nullable) NSTimer *refreshTimer;
@property(nonatomic) BOOL paused;

// An outcome message ("Closed 3 processes…") that has to survive the next
// refresh: the 2s cycle rewrites the status line with process counts, which
// would otherwise erase the result of the action the user just took before
// they could read it.
@property(nonatomic, copy, nullable) NSString *stickyStatus;
@property(nonatomic, strong, nullable) NSDate *stickyStatusUntil;

@end

@implementation MCPerformanceViewController

- (instancetype)init {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _model = [[MCProcessModel alloc] init];
        _allItems = @[];
        _items = @[];
    }
    return self;
}

#pragma mark - Layout

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 720, 560)];

    // --- top bar ---------------------------------------------------------
    self.filterPopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.filterPopUp addItemWithTitle:@"All Processes"];
    self.filterPopUp.lastItem.tag = FilterAll;
    [self.filterPopUp addItemWithTitle:@"Heavy / Long-Running"];
    self.filterPopUp.lastItem.tag = FilterHeavy;
    [self.filterPopUp addItemWithTitle:@"Apps"];
    self.filterPopUp.lastItem.tag = FilterApps;
    [self.filterPopUp addItemWithTitle:@"Background & System"];
    self.filterPopUp.lastItem.tag = FilterBackground;
    self.filterPopUp.target = self;
    self.filterPopUp.action = @selector(filterChanged:);

    self.pauseButton = [NSButton buttonWithTitle:@"Pause" target:self action:@selector(togglePaused:)];
    self.pauseButton.bezelStyle = NSBezelStyleRounded;

    // The headline action of the tool: one click to find what can be
    // reclaimed. It opens a review sheet rather than acting immediately --
    // see MCOptimizeSheetController for why that is not negotiable.
    self.optimizeButton = [NSButton buttonWithTitle:@"Optimize…" target:self action:@selector(optimize:)];
    self.optimizeButton.bezelStyle = NSBezelStyleRounded;
    self.optimizeButton.keyEquivalent = @"\r";
    self.optimizeButton.toolTip = @"Find processes that can be closed safely";

    self.optimizeSpinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.optimizeSpinner.style = NSProgressIndicatorStyleSpinning;
    self.optimizeSpinner.controlSize = NSControlSizeSmall;
    self.optimizeSpinner.displayedWhenStopped = NO;

    NSView *topSpacer = [[NSView alloc] initWithFrame:NSZeroRect];
    [topSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow
                          forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *topBar = [NSStackView stackViewWithViews:@[
        self.filterPopUp, self.optimizeButton, self.optimizeSpinner, topSpacer, self.pauseButton
    ]];
    topBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    topBar.spacing = 8;
    topBar.translatesAutoresizingMaskIntoConstraints = NO;

    // --- table -----------------------------------------------------------
    self.tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.usesAlternatingRowBackgroundColors = YES;
    self.tableView.allowsMultipleSelection = YES;

    struct ColumnSpec {
        NSString *identifier;
        NSString *title;
        CGFloat width;
        NSString *sortKey;
        BOOL ascending;
    };
    const ColumnSpec specs[] = {
        {kCpuColumn, @"CPU %", 70, @"cpuPercent", NO},
        {kMemColumn, @"Memory", 90, @"memoryBytes", NO},
        {kNameColumn, @"Name", 220, @"name", YES},
        {kKindColumn, @"Kind", 90, nil, YES},
        {kUptimeColumn, @"Uptime", 80, @"uptimeSeconds", NO},
        {kPidColumn, @"PID", 60, @"pid", YES},
    };
    for (const ColumnSpec &spec : specs) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:spec.identifier];
        column.title = spec.title;
        column.width = spec.width;
        column.minWidth = spec.width * 0.6;
        if (spec.sortKey != nil) {
            column.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:spec.sortKey
                                                                            ascending:spec.ascending];
        }
        [self.tableView addTableColumn:column];
    }
    // CPU-heavy first is what a performance tool opens on.
    self.tableView.sortDescriptors =
        @[ [NSSortDescriptor sortDescriptorWithKey:@"cpuPercent" ascending:NO] ];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.documentView = self.tableView;
    scrollView.hasVerticalScroller = YES;
    scrollView.autohidesScrollers = YES;
    scrollView.borderType = NSBezelBorder;
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;

    // --- bottom bar ------------------------------------------------------
    self.statusLabel = [NSTextField labelWithString:@"Sampling…"];
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    self.statusLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.statusLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.quitButton = [NSButton buttonWithTitle:@"Quit Process…" target:self action:@selector(quitSelection:)];
    self.quitButton.bezelStyle = NSBezelStyleRounded;
    self.quitButton.enabled = NO;

    self.forceQuitButton = [NSButton buttonWithTitle:@"Force Quit…" target:self
                                               action:@selector(forceQuitSelection:)];
    self.forceQuitButton.bezelStyle = NSBezelStyleRounded;
    self.forceQuitButton.enabled = NO;

    NSView *bottomSpacer = [[NSView alloc] initWithFrame:NSZeroRect];
    [bottomSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow
                             forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *bottomBar = [NSStackView stackViewWithViews:@[
        self.statusLabel, bottomSpacer, self.quitButton, self.forceQuitButton
    ]];
    bottomBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bottomBar.spacing = 8;
    bottomBar.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:topBar];
    [self.view addSubview:scrollView];
    [self.view addSubview:bottomBar];

    const CGFloat margin = 16;
    [NSLayoutConstraint activateConstraints:@[
        [topBar.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:margin],
        [topBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [topBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],

        [scrollView.topAnchor constraintEqualToAnchor:topBar.bottomAnchor constant:12],
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],

        [bottomBar.topAnchor constraintEqualToAnchor:scrollView.bottomAnchor constant:12],
        [bottomBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [bottomBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],
        [bottomBar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-margin],
    ]];
}

#pragma mark - Refresh lifecycle

- (void)viewWillAppear {
    [super viewWillAppear];
    [self refreshNow];
    [self startTimer];
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
    // The tool is hidden (other tool selected / window closing): sampling
    // 500 processes every 2s for an invisible table is pure waste.
    [self stopTimer];
}

- (void)startTimer {
    if (self.refreshTimer != nil || self.paused) {
        return;
    }
    __weak MCPerformanceViewController *weakSelf = self;
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:kRefreshInterval
                                                         repeats:YES
                                                           block:^(NSTimer *) {
                                                               [weakSelf refreshNow];
                                                           }];
    self.refreshTimer.tolerance = 0.5;
}

- (void)stopTimer {
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)togglePaused:(id)sender {
    self.paused = !self.paused;
    self.pauseButton.title = self.paused ? @"Resume" : @"Pause";
    if (self.paused) {
        [self stopTimer];
    } else {
        [self refreshNow];
        [self startTimer];
    }
}

- (void)filterChanged:(id)sender {
    [self rebuildDisplayedItems];
}

- (void)refreshNow {
    __weak MCPerformanceViewController *weakSelf = self;
    [self.model refreshWithCompletion:^(NSArray<MCProcessItem *> *items) {
        MCPerformanceViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        strongSelf.allItems = items;
        [strongSelf rebuildDisplayedItems];
    }];
}

/// Filter + sort + reload, preserving selection by pid. Rows churn on every
/// 2s refresh; losing the user's selection mid-aim at a runaway process
/// would make the kill buttons unusable.
- (void)rebuildDisplayedItems {
    const NSInteger filter = self.filterPopUp.selectedTag;
    NSMutableArray<MCProcessItem *> *filtered = [NSMutableArray array];
    NSUInteger heavyCount = 0;
    for (MCProcessItem *item in self.allItems) {
        const BOOL heavy = isHeavy(item);
        if (heavy) {
            ++heavyCount;
        }
        switch (filter) {
            case FilterAll: [filtered addObject:item]; break;
            case FilterHeavy:
                if (heavy) {
                    [filtered addObject:item];
                }
                break;
            case FilterApps:
                if (item.kind == MCProcessKindApp) {
                    [filtered addObject:item];
                }
                break;
            case FilterBackground:
                if (item.kind != MCProcessKindApp) {
                    [filtered addObject:item];
                }
                break;
        }
    }

    NSArray<NSSortDescriptor *> *descriptors = self.tableView.sortDescriptors;
    if (descriptors.count > 0) {
        [filtered sortUsingDescriptors:descriptors];
    }

    NSMutableSet<NSNumber *> *selectedPids = [NSMutableSet set];
    for (MCProcessItem *item in [self selectedItems]) {
        [selectedPids addObject:@(item.pid)];
    }

    self.items = filtered;
    [self.tableView reloadData];

    if (selectedPids.count > 0) {
        NSMutableIndexSet *toSelect = [NSMutableIndexSet indexSet];
        [self.items enumerateObjectsUsingBlock:^(MCProcessItem *item, NSUInteger index, BOOL *) {
            if ([selectedPids containsObject:@(item.pid)]) {
                [toSelect addIndex:index];
            }
        }];
        [self.tableView selectRowIndexes:toSelect byExtendingSelection:NO];
    }

    if (self.stickyStatus != nil && self.stickyStatusUntil != nil &&
        [self.stickyStatusUntil timeIntervalSinceNow] > 0) {
        self.statusLabel.stringValue = self.stickyStatus;
    } else {
        self.stickyStatus = nil;
        self.stickyStatusUntil = nil;
        self.statusLabel.stringValue =
            [NSString stringWithFormat:@"%lu process(es) · %lu heavy%@",
                                        (unsigned long)self.allItems.count, (unsigned long)heavyCount,
                                        self.paused ? @" · paused" : @""];
    }
    [self updateActionButtons];
}

/// Shows `message` and keeps it on screen across the next few refreshes.
- (void)setStickyStatusMessage:(NSString *)message {
    self.stickyStatus = message;
    self.stickyStatusUntil = [NSDate dateWithTimeIntervalSinceNow:8];
    self.statusLabel.stringValue = message;
}

#pragma mark - Optimize

- (void)optimize:(id)sender {
    self.optimizeButton.enabled = NO;
    [self.optimizeSpinner startAnimation:nil];
    self.statusLabel.stringValue = @"Looking for processes that can be closed…";

    __weak MCPerformanceViewController *weakSelf = self;
    [self.model findOptimizationCandidatesWithCompletion:^(NSArray<MCOptimizationCandidate *> *candidates) {
        MCPerformanceViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        [strongSelf.optimizeSpinner stopAnimation:nil];
        strongSelf.optimizeButton.enabled = YES;

        if (candidates.count == 0) {
            // The honest answer, and the common one on a healthy Mac.
            // Inventing work here is what turns an optimizer into a
            // placebo -- or worse, into something that closes things that
            // were doing their job.
            [strongSelf setStickyStatusMessage:@"Nothing to reclaim."];
            NSAlert *alert = [[NSAlert alloc] init];
            alert.alertStyle = NSAlertStyleInformational;
            alert.messageText = @"Nothing to optimize";
            alert.informativeText = @"No leftover helpers, finished processes or idle update "
                                     @"agents were found. Everything running right now is either "
                                     @"in use or doing its job.";
            [alert addButtonWithTitle:@"OK"];
            [alert beginSheetModalForWindow:strongSelf.view.window completionHandler:nil];
            return;
        }

        MCOptimizeSheetController *sheet = [[MCOptimizeSheetController alloc]
            initWithCandidates:candidates
                      onConfirm:^(NSArray<MCOptimizationCandidate *> *accepted) {
                          [weakSelf applyOptimization:accepted];
                      }];
        [strongSelf presentViewControllerAsSheet:sheet];
    }];
}

- (void)applyOptimization:(NSArray<MCOptimizationCandidate *> *)accepted {
    NSMutableArray<NSString *> *problems = [NSMutableArray array];
    NSUInteger closed = 0;
    unsigned long long reclaimed = 0;

    for (MCOptimizationCandidate *candidate in accepted) {
        NSString *error = nil;
        // Graceful only: these are helpers and agents, and SIGTERM lets
        // them shut down properly. The optimizer never escalates to
        // SIGKILL on its own -- that stays a deliberate manual action.
        if ([self.model killPid:candidate.pid force:NO error:&error]) {
            ++closed;
            reclaimed += candidate.reclaimableBytes;
        } else {
            [problems addObject:[NSString stringWithFormat:@"%@ — %@", candidate.name,
                                                            error != nil ? error : @"unknown error"]];
        }
    }

    [self setStickyStatusMessage:[NSString stringWithFormat:@"Closed %lu process(es) · %@ reclaimed",
                                                              (unsigned long)closed, humanSize(reclaimed)]];

    if (problems.count > 0) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = @"Some processes could not be closed";
        alert.informativeText = [problems componentsJoinedByString:@"\n"];
        [alert addButtonWithTitle:@"OK"];
        [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [self refreshNow];
                   });
}

#pragma mark - Selection / kill

- (NSArray<MCProcessItem *> *)selectedItems {
    NSMutableArray<MCProcessItem *> *selected = [NSMutableArray array];
    [self.tableView.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *) {
        if (index < self.items.count) {
            [selected addObject:self.items[index]];
        }
    }];
    return selected;
}

- (void)updateActionButtons {
    BOOL anyKillable = NO;
    for (MCProcessItem *item in [self selectedItems]) {
        if (item.killable) {
            anyKillable = YES;
            break;
        }
    }
    self.quitButton.enabled = anyKillable;
    self.forceQuitButton.enabled = anyKillable;
}

- (void)quitSelection:(id)sender {
    [self confirmAndKillForce:NO];
}

- (void)forceQuitSelection:(id)sender {
    [self confirmAndKillForce:YES];
}

- (void)confirmAndKillForce:(BOOL)force {
    NSMutableArray<MCProcessItem *> *targets = [NSMutableArray array];
    for (MCProcessItem *item in [self selectedItems]) {
        if (item.killable) {
            [targets addObject:item];
        }
    }
    if (targets.count == 0) {
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = force ? NSAlertStyleCritical : NSAlertStyleWarning;
    alert.messageText = force ? @"Force quit the selected processes?"
                               : @"Quit the selected processes?";

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    BOOL anySystem = NO;
    for (MCProcessItem *item in targets) {
        if (names.count < 8) {
            [names addObject:[NSString stringWithFormat:@"%@ (pid %d)", item.name, item.pid]];
        }
        anySystem |= (item.kind == MCProcessKindSystem);
    }
    if (targets.count > names.count) {
        [names addObject:[NSString stringWithFormat:@"… and %lu more",
                                                     (unsigned long)(targets.count - names.count)]];
    }

    NSMutableString *info = [NSMutableString stringWithString:[names componentsJoinedByString:@"\n"]];
    if (force) {
        [info appendString:@"\n\nForce quit gives processes no chance to save or clean up."];
    }
    if (anySystem) {
        [info appendString:@"\n\nSome of these are macOS services; the system may restart them "
                            @"automatically, and quitting them can temporarily affect system features."];
    }
    alert.informativeText = info;

    [alert addButtonWithTitle:force ? @"Force Quit" : @"Quit"];
    [alert addButtonWithTitle:@"Cancel"];
    if (force) {
        // Return must cancel, not force-quit.
        alert.buttons.firstObject.keyEquivalent = @"";
        alert.buttons.lastObject.keyEquivalent = @"\r";
    }

    __weak MCPerformanceViewController *weakSelf = self;
    [alert beginSheetModalForWindow:self.view.window
                  completionHandler:^(NSModalResponse response) {
                      if (response == NSAlertFirstButtonReturn) {
                          [weakSelf performKill:targets force:force];
                      }
                  }];
}

- (void)performKill:(NSArray<MCProcessItem *> *)targets force:(BOOL)force {
    NSMutableArray<NSString *> *problems = [NSMutableArray array];
    NSUInteger killed = 0;

    for (MCProcessItem *item in targets) {
        NSString *error = nil;
        if ([self.model killPid:item.pid force:force error:&error]) {
            ++killed;
        } else {
            [problems addObject:[NSString stringWithFormat:@"%@ — %@", item.name,
                                                            error != nil ? error : @"unknown error"]];
        }
    }

    if (problems.count > 0) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = @"Some processes could not be quit";
        alert.informativeText = [problems componentsJoinedByString:@"\n"];
        [alert addButtonWithTitle:@"OK"];
        [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
    }

    [self setStickyStatusMessage:[NSString stringWithFormat:@"Sent %@ to %lu process(es).",
                                                              force ? @"SIGKILL" : @"SIGTERM",
                                                              (unsigned long)killed]];
    // SIGTERM is asynchronous -- give processes a beat to exit before the
    // list refreshes, so the user sees them actually gone (or still there).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [self refreshNow];
                   });
}

#pragma mark - NSTableViewDataSource / Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.items.count;
}

- (void)tableView:(NSTableView *)tableView sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)oldDescriptors {
    [self rebuildDisplayedItems];
}

- (NSView *)tableView:(NSTableView *)tableView
    viewForTableColumn:(NSTableColumn *)tableColumn
                    row:(NSInteger)row {
    MCProcessItem *item = self.items[(NSUInteger)row];
    NSString *identifier = tableColumn.identifier;

    NSTextField *field = [tableView makeViewWithIdentifier:identifier owner:self];
    if (field == nil) {
        field = [NSTextField labelWithString:@""];
        field.identifier = identifier;
        field.lineBreakMode = NSLineBreakByTruncatingTail;
        if ([identifier isEqualToString:kCpuColumn] || [identifier isEqualToString:kMemColumn] ||
            [identifier isEqualToString:kUptimeColumn] || [identifier isEqualToString:kPidColumn]) {
            field.alignment = NSTextAlignmentRight;
            field.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize
                                                          weight:NSFontWeightRegular];
        }
    }

    if ([identifier isEqualToString:kCpuColumn]) {
        field.stringValue = [NSString stringWithFormat:@"%.1f", item.cpuPercent];
        field.textColor = item.cpuPercent >= kHeavyCpuPercent ? NSColor.systemRedColor : NSColor.labelColor;
    } else if ([identifier isEqualToString:kMemColumn]) {
        field.stringValue = humanSize(item.memoryBytes);
        field.textColor =
            item.memoryBytes >= kHeavyMemoryBytes ? NSColor.systemOrangeColor : NSColor.labelColor;
    } else if ([identifier isEqualToString:kNameColumn]) {
        field.stringValue = item.name;
        field.textColor = item.killable ? NSColor.labelColor : NSColor.tertiaryLabelColor;
        field.toolTip = item.killable
                             ? item.path
                             : [NSString stringWithFormat:@"%@ — %@", item.path,
                                                           item.notKillableReason != nil ? item.notKillableReason
                                                                                          : @""];
    } else if ([identifier isEqualToString:kKindColumn]) {
        field.stringValue = kindLabel(item.kind);
        field.textColor = NSColor.secondaryLabelColor;
    } else if ([identifier isEqualToString:kUptimeColumn]) {
        field.stringValue = formatUptime(item.uptimeSeconds);
        field.textColor = item.uptimeSeconds >= kLongRunningSeconds ? NSColor.secondaryLabelColor
                                                                     : NSColor.labelColor;
    } else {
        field.stringValue = [NSString stringWithFormat:@"%d", item.pid];
        field.textColor = NSColor.secondaryLabelColor;
    }
    return field;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    [self updateActionButtons];
}

@end
