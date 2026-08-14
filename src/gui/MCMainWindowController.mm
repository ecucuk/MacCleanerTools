#import "MCMainWindowController.h"

#import "MCScanModel.h"
#import "MCUsageSummaryView.h"
#import "MacCleanerViz-Swift.h"

#include "maccleaner/format.hpp"

/// The colour dot on a category row, matching that category's segment in the
/// bar above. Draws from the palette on demand so it follows light/dark.
@interface MCSwatchDotView : NSView
@property(nonatomic) NSInteger slot;
@end

@implementation MCSwatchDotView

- (void)drawRect:(NSRect)dirtyRect {
    [[MCUsageSummaryView colorForSlot:self.slot] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:self.bounds] fill];
}

- (void)setSlot:(NSInteger)slot {
    if (_slot != slot) {
        _slot = slot;
        self.needsDisplay = YES;
    }
}

@end

namespace {

// Cell subview tags. NSControl subclasses (button, text field) have a settable
// tag; the swatch dot is a plain NSView and is located by class instead.
constexpr NSInteger kCheckboxTag = 1;
constexpr NSInteger kPathTag = 2;

NSString *humanSize(unsigned long long bytes) {
    // Same formatter the CLI uses, so both front ends report identical numbers.
    return [NSString stringWithUTF8String:maccleaner::humanReadableBytes(bytes).c_str()];
}

NSString *const kNameColumn = @"name";
NSString *const kSizeColumn = @"size";

NSControlStateValue checkboxStateFor(MCSelectionState state) {
    switch (state) {
        case MCSelectionStateNone:
            return NSControlStateValueOff;
        case MCSelectionStatePartial:
            return NSControlStateValueMixed;
        case MCSelectionStateAll:
            return NSControlStateValueOn;
    }
    return NSControlStateValueOff;
}

} // namespace

@interface MCMainWindowController () <NSOutlineViewDataSource, NSOutlineViewDelegate>

@property(nonatomic, strong) MCScanModel *model;
@property(nonatomic, strong) MCActivityBridge *activity;

@property(nonatomic, strong) NSOutlineView *outlineView;
@property(nonatomic, strong) NSButton *scanButton;
@property(nonatomic, strong) NSButton *activityButton;
@property(nonatomic, strong) NSButton *cleanButton;
@property(nonatomic, strong) NSPopUpButton *modePopUp;
@property(nonatomic, strong) NSProgressIndicator *spinner;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSTextField *selectionLabel;
@property(nonatomic, strong) MCUsageSummaryView *summaryView;

/// Category label -> palette slot, so list rows can match the bar's segments.
@property(nonatomic, copy) NSDictionary<NSString *, NSNumber *> *slotByCategoryLabel;

@property(nonatomic) BOOL busy;

@end

@implementation MCMainWindowController

- (instancetype)init {
    NSRect frame = NSMakeRect(0, 0, 860, 560);
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"MacCleaner";
    window.minSize = NSMakeSize(640, 400);
    [window center];

    if ((self = [super initWithWindow:window])) {
        _model = [[MCScanModel alloc] init];
        _activity = [[MCActivityBridge alloc] init];

        __weak MCMainWindowController *weakSelf = self;
        // Both buttons in the activity window route back through the exact
        // same actions as the main window's own buttons -- including the
        // confirmation sheet on the clean path. No second delete path exists.
        _activity.onRescanRequested = ^{
            [weakSelf rescan:nil];
        };
        _activity.onCleanRequested = ^{
            [weakSelf clean:nil];
        };

        [self buildUI];
    }
    return self;
}

#pragma mark - Layout

- (void)buildUI {
    NSView *content = self.window.contentView;

    // --- top bar ---------------------------------------------------------
    self.scanButton = [NSButton buttonWithTitle:@"Rescan" target:self action:@selector(rescan:)];
    self.scanButton.bezelStyle = NSBezelStyleRounded;

    self.activityButton = [NSButton buttonWithTitle:@"Activity" target:self action:@selector(showActivity:)];
    self.activityButton.bezelStyle = NSBezelStyleRounded;

    self.modePopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.modePopUp addItemWithTitle:@"Move to Trash"];
    [self.modePopUp addItemWithTitle:@"Delete permanently"];
    self.modePopUp.target = self;
    self.modePopUp.action = @selector(modeChanged:);
    if (!self.model.trashIsRecoverable) {
        // This build has no native Trash backend, so "Move to Trash" would be
        // an irreversible delete wearing a reassuring label. Don't offer it.
        [self.modePopUp removeItemAtIndex:0];
        self.modePopUp.enabled = NO;
    }

    self.cleanButton = [NSButton buttonWithTitle:@"Clean Selected…" target:self action:@selector(clean:)];
    self.cleanButton.bezelStyle = NSBezelStyleRounded;
    self.cleanButton.keyEquivalent = @"\r";
    self.cleanButton.enabled = NO;

    self.spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.controlSize = NSControlSizeSmall;
    self.spinner.displayedWhenStopped = NO;

    NSStackView *topBar = [NSStackView stackViewWithViews:@[
        self.scanButton, self.activityButton, self.spinner, [self flexibleSpacer], self.modePopUp, self.cleanButton
    ]];
    topBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    topBar.spacing = 8;
    topBar.translatesAutoresizingMaskIntoConstraints = NO;

    // --- outline ---------------------------------------------------------
    self.outlineView = [[NSOutlineView alloc] initWithFrame:NSZeroRect];
    self.outlineView.dataSource = self;
    self.outlineView.delegate = self;
    self.outlineView.rowSizeStyle = NSTableViewRowSizeStyleDefault;
    self.outlineView.usesAlternatingRowBackgroundColors = YES;
    self.outlineView.allowsMultipleSelection = NO;
    self.outlineView.indentationPerLevel = 16;

    NSTableColumn *nameColumn = [[NSTableColumn alloc] initWithIdentifier:kNameColumn];
    nameColumn.title = @"Item";
    nameColumn.width = 600;
    nameColumn.minWidth = 260;
    [self.outlineView addTableColumn:nameColumn];
    self.outlineView.outlineTableColumn = nameColumn;

    NSTableColumn *sizeColumn = [[NSTableColumn alloc] initWithIdentifier:kSizeColumn];
    sizeColumn.title = @"Size";
    sizeColumn.width = 110;
    sizeColumn.minWidth = 80;
    [self.outlineView addTableColumn:sizeColumn];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.documentView = self.outlineView;
    scrollView.hasVerticalScroller = YES;
    scrollView.autohidesScrollers = YES;
    scrollView.borderType = NSBezelBorder;
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;

    // --- bottom bar ------------------------------------------------------
    self.statusLabel = [NSTextField labelWithString:@"Ready."];
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    self.statusLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    self.selectionLabel = [NSTextField labelWithString:@""];
    self.selectionLabel.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize
                                                                weight:NSFontWeightSemibold];

    NSStackView *bottomBar = [NSStackView stackViewWithViews:@[
        self.statusLabel, [self flexibleSpacer], self.selectionLabel
    ]];
    bottomBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bottomBar.spacing = 8;
    bottomBar.translatesAutoresizingMaskIntoConstraints = NO;

    self.summaryView = [[MCUsageSummaryView alloc] initWithFrame:NSZeroRect];
    self.summaryView.translatesAutoresizingMaskIntoConstraints = NO;

    [content addSubview:topBar];
    [content addSubview:self.summaryView];
    [content addSubview:scrollView];
    [content addSubview:bottomBar];

    const CGFloat margin = 16;
    [NSLayoutConstraint activateConstraints:@[
        [topBar.topAnchor constraintEqualToAnchor:content.topAnchor constant:margin],
        [topBar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:margin],
        [topBar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-margin],

        [self.summaryView.topAnchor constraintEqualToAnchor:topBar.bottomAnchor constant:14],
        [self.summaryView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:margin],
        [self.summaryView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-margin],

        [scrollView.topAnchor constraintEqualToAnchor:self.summaryView.bottomAnchor constant:14],
        [scrollView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:margin],
        [scrollView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-margin],

        [bottomBar.topAnchor constraintEqualToAnchor:scrollView.bottomAnchor constant:12],
        [bottomBar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:margin],
        [bottomBar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-margin],
        [bottomBar.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-margin],
    ]];

    [self updateSelectionSummary];
}

- (NSView *)flexibleSpacer {
    NSView *spacer = [[NSView alloc] initWithFrame:NSZeroRect];
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow
                        forOrientation:NSLayoutConstraintOrientationHorizontal];
    return spacer;
}

#pragma mark - Actions

- (void)startInitialScan {
    // The activity window ships open on first launch so the visualization is
    // discoverable; it remembers nothing, so closing it is one click.
    [self.activity showWindowRelativeTo:self.window];
    [self rescan:nil];
}

- (void)showActivity:(id)sender {
    [self.activity showWindowRelativeTo:self.window];
}

- (void)rescan:(id)sender {
    if (self.busy) {
        return;
    }
    [self setBusy:YES status:@"Scanning… (this walks every cache directory, so it can take a moment)"];
    [self.activity scanBegan];

    __weak MCMainWindowController *weakSelf = self;
    [self.model
        scanWithWillScanCategory:^(NSString *label, NSString *path) {
            [weakSelf.activity categoryScanBeganWithLabel:label path:path];
        }
        didScanCategory:^(MCCategoryNode *node) {
            if (node != nil) {
                [weakSelf.activity categoryScanFinishedWithLabel:node.label
                                                            bytes:node.sizeBytes
                                                       entryCount:(NSInteger)node.entries.count];
            }
        }
        completion:^{
            MCMainWindowController *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            [strongSelf.activity scanFinished];

            // Slot assignment first: the outline's category rows read it while
            // building their swatches, so it has to be current before reloadData.
            strongSelf.slotByCategoryLabel =
                [strongSelf.summaryView updateWithCategories:strongSelf.model.categories];

            // Categories stay collapsed: expanding all of them would dump hundreds
            // of cache folders on the user at launch.
            [strongSelf.outlineView reloadData];

            unsigned long long found = 0;
            for (MCCategoryNode *category in strongSelf.model.categories) {
                found += category.sizeBytes;
            }
            [strongSelf setBusy:NO
                         status:[NSString stringWithFormat:@"Found %@ across %lu categories.", humanSize(found),
                                                            (unsigned long)strongSelf.model.categories.count]];
            [strongSelf updateSelectionSummary];
        }];
}

- (void)modeChanged:(id)sender {
    [self updateSelectionSummary];
}

- (void)clean:(id)sender {
    if (self.busy || self.model.selectedCount == 0) {
        return;
    }

    const BOOL permanent = [self permanentModeSelected];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = permanent ? NSAlertStyleCritical : NSAlertStyleWarning;
    alert.messageText = permanent ? @"Permanently delete the selected items?"
                                   : @"Move the selected items to the Trash?";

    NSMutableString *info = [NSMutableString stringWithFormat:@"%lu item(s), %@.",
                                                                (unsigned long)self.model.selectedCount,
                                                                humanSize(self.model.selectedBytes)];
    if (permanent) {
        [info appendString:@"\n\nThis cannot be undone."];
    } else if (self.model.selectionIncludesForcedPermanent) {
        // Mirrors the CLI's warning: items already in the Trash can't be
        // trashed again, so those are deleted outright whatever the mode says.
        [info appendString:@"\n\nItems already in the Trash will be deleted permanently — "
                            @"they cannot be moved to the Trash again."];
    }
    alert.informativeText = info;

    [alert addButtonWithTitle:permanent ? @"Delete Permanently" : @"Move to Trash"];
    [alert addButtonWithTitle:@"Cancel"];
    // Make Cancel the safe default for the irreversible path: Return then
    // cancels instead of confirming.
    if (permanent) {
        alert.buttons.firstObject.keyEquivalent = @"";
        alert.buttons.lastObject.keyEquivalent = @"\r";
    }

    __weak MCMainWindowController *weakSelf = self;
    [alert beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse response) {
                      if (response != NSAlertFirstButtonReturn) {
                          return;
                      }
                      [weakSelf performCleanPermanently:permanent];
                  }];
}

- (void)performCleanPermanently:(BOOL)permanent {
    [self setBusy:YES status:permanent ? @"Deleting…" : @"Moving to Trash…"];
    [self.activity cleanBeganWithItemsTotal:(NSInteger)self.model.selectedCount
                                bytesPlanned:self.model.selectedBytes
                                   permanent:permanent];

    __weak MCMainWindowController *weakSelf = self;
    [self.model cleanSelectedPermanently:permanent
        entryProgress:^(NSString *path, BOOL succeeded, BOOL skippedBySafety, NSString *message,
                        unsigned long long bytesFreedSoFar, NSUInteger itemsDone, NSUInteger) {
            [weakSelf.activity cleanItemFinishedWithPath:path
                                                succeeded:succeeded
                                          skippedBySafety:skippedBySafety
                                                  message:message
                                          bytesFreedSoFar:bytesFreedSoFar
                                                itemsDone:(NSInteger)itemsDone];
        }
        completion:^(MCCleanSummary *summary) {
            MCMainWindowController *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            [strongSelf.activity cleanFinishedWithBytesFreed:summary.bytesFreed];
            [strongSelf setBusy:NO
                         status:[NSString stringWithFormat:@"Freed %@.", humanSize(summary.bytesFreed)]];
            [strongSelf presentSummary:summary];
            // The tree on screen now describes deleted
            // paths, so re-scan rather than patch it up.
            [strongSelf rescan:nil];
        }];
}

- (void)presentSummary:(MCCleanSummary *)summary {
    NSAlert *alert = [[NSAlert alloc] init];
    const BOOL clean = summary.failedCount == 0 && summary.skippedCount == 0;
    alert.alertStyle = clean ? NSAlertStyleInformational : NSAlertStyleWarning;
    alert.messageText = [NSString stringWithFormat:@"Freed %@", humanSize(summary.bytesFreed)];

    NSMutableString *info = [NSMutableString
        stringWithFormat:@"%lu removed", (unsigned long)summary.succeededCount];
    if (summary.skippedCount > 0) {
        [info appendFormat:@", %lu skipped by the safety check", (unsigned long)summary.skippedCount];
    }
    if (summary.failedCount > 0) {
        [info appendFormat:@", %lu failed", (unsigned long)summary.failedCount];
    }
    [info appendString:@"."];
    alert.informativeText = info;

    if (summary.problems.count > 0) {
        // Details go in the disclosure accessory so a handful of skips don't
        // turn into a wall of text in the main alert.
        NSTextView *details = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 460, 120)];
        details.string = [summary.problems componentsJoinedByString:@"\n"];
        details.editable = NO;
        details.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];

        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 460, 120)];
        scroll.documentView = details;
        scroll.hasVerticalScroller = YES;
        scroll.borderType = NSBezelBorder;
        alert.accessoryView = scroll;
    }

    [alert addButtonWithTitle:@"OK"];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

#pragma mark - State

- (BOOL)permanentModeSelected {
    if (!self.model.trashIsRecoverable) {
        return YES; // only one item in the popup, and it is the permanent one
    }
    return self.modePopUp.indexOfSelectedItem == 1;
}

- (void)setBusy:(BOOL)busy status:(NSString *)status {
    self.busy = busy;
    self.statusLabel.stringValue = status;
    self.scanButton.enabled = !busy;
    self.outlineView.enabled = !busy;
    if (busy) {
        [self.spinner startAnimation:nil];
        self.cleanButton.enabled = NO;
    } else {
        [self.spinner stopAnimation:nil];
        [self updateSelectionSummary];
    }
}

- (void)updateSelectionSummary {
    const NSUInteger count = self.model.selectedCount;
    if (count == 0) {
        self.selectionLabel.stringValue = @"Nothing selected";
        self.selectionLabel.textColor = NSColor.secondaryLabelColor;
    } else {
        self.selectionLabel.stringValue =
            [NSString stringWithFormat:@"%lu selected · %@", (unsigned long)count,
                                        humanSize(self.model.selectedBytes)];
        self.selectionLabel.textColor = NSColor.labelColor;
    }
    self.cleanButton.enabled = !self.busy && count > 0;
    [self.activity selectionChangedWithCount:(NSInteger)count bytes:self.model.selectedBytes];
}

#pragma mark - Checkbox handling

- (void)toggleItem:(NSButton *)sender {
    const NSInteger row = [self.outlineView rowForView:sender];
    if (row < 0) {
        return;
    }
    id item = [self.outlineView itemAtRow:row];

    // Deliberately ignoring sender.state. A checkbox with allowsMixedState
    // auto-cycles Off -> On -> Mixed -> Off, so reading the state back made the
    // click after a deselect land on Mixed, which this handler then read as
    // "not On" and treated as another deselect -- the category checkbox
    // appeared dead and could not be re-selected. The model is the only source
    // of truth for what a click means; the button is re-set from it below.
    if ([item isKindOfClass:[MCCategoryNode class]]) {
        MCCategoryNode *category = item;
        // Anything short of fully selected selects everything; only a full
        // selection clears. That makes a half-selected category one click from
        // "all", which is what the mixed checkbox invites you to expect.
        const BOOL selectAll = category.selectionState != MCSelectionStateAll;
        [category setAllEntriesSelected:selectAll];
        // Children's checkboxes are now stale; reload the subtree rather than
        // the whole view so scroll position and expansion state survive.
        [self.outlineView reloadItem:category reloadChildren:YES];
    } else if ([item isKindOfClass:[MCEntryNode class]]) {
        MCEntryNode *entry = item;
        entry.selected = !entry.selected;
        [self.outlineView reloadItem:entry reloadChildren:NO];
        // The parent may have flipped to/from the mixed state.
        id parent = [self.outlineView parentForItem:item];
        if (parent != nil) {
            [self.outlineView reloadItem:parent reloadChildren:NO];
        }
    }

    [self updateSelectionSummary];
}

#pragma mark - NSOutlineViewDataSource

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(nullable id)item {
    if (item == nil) {
        return (NSInteger)self.model.categories.count;
    }
    if ([item isKindOfClass:[MCCategoryNode class]]) {
        return (NSInteger)((MCCategoryNode *)item).entries.count;
    }
    return 0;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(nullable id)item {
    if (item == nil) {
        return self.model.categories[(NSUInteger)index];
    }
    return ((MCCategoryNode *)item).entries[(NSUInteger)index];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item {
    return [item isKindOfClass:[MCCategoryNode class]] && ((MCCategoryNode *)item).entries.count > 0;
}

#pragma mark - NSOutlineViewDelegate

- (NSView *)outlineView:(NSOutlineView *)outlineView
     viewForTableColumn:(nullable NSTableColumn *)tableColumn
                   item:(id)item {
    const BOOL isCategory = [item isKindOfClass:[MCCategoryNode class]];

    if ([tableColumn.identifier isEqualToString:kSizeColumn]) {
        NSTextField *field = [outlineView makeViewWithIdentifier:kSizeColumn owner:self];
        if (field == nil) {
            field = [NSTextField labelWithString:@""];
            field.identifier = kSizeColumn;
            field.alignment = NSTextAlignmentRight;
            field.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize
                                                          weight:NSFontWeightRegular];
        }
        const unsigned long long size =
            isCategory ? ((MCCategoryNode *)item).sizeBytes : ((MCEntryNode *)item).sizeBytes;
        field.stringValue = humanSize(size);
        field.textColor = isCategory ? NSColor.labelColor : NSColor.secondaryLabelColor;
        return field;
    }

    // Two lines per row: the name, and underneath it the full path. This is a
    // tool that deletes things -- "Google" is not enough to decide on, the user
    // has to be able to see exactly which directory is about to go.
    NSTableCellView *cell = [outlineView makeViewWithIdentifier:kNameColumn owner:self];
    NSButton *checkbox = nil;
    MCSwatchDotView *dot = nil;
    NSTextField *pathLabel = nil;
    if (cell == nil) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = kNameColumn;

        checkbox = [NSButton checkboxWithTitle:@"" target:self action:@selector(toggleItem:)];
        checkbox.translatesAutoresizingMaskIntoConstraints = NO;
        checkbox.tag = kCheckboxTag;
        [cell addSubview:checkbox];

        // Plain NSView has no settable tag, so this one is found by class below.
        dot = [[MCSwatchDotView alloc] initWithFrame:NSZeroRect];
        dot.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:dot];

        NSTextField *label = [NSTextField labelWithString:@""];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview:label];
        cell.textField = label;

        pathLabel = [NSTextField labelWithString:@""];
        pathLabel.translatesAutoresizingMaskIntoConstraints = NO;
        // Truncate in the middle: the interesting parts of these paths are the
        // ~/Library root and the leaf, not the middle.
        pathLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        pathLabel.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
        pathLabel.textColor = NSColor.secondaryLabelColor;
        pathLabel.tag = kPathTag;
        [cell addSubview:pathLabel];

        [NSLayoutConstraint activateConstraints:@[
            [checkbox.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor],
            [checkbox.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],

            [dot.leadingAnchor constraintEqualToAnchor:checkbox.trailingAnchor constant:4],
            [dot.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [dot.widthAnchor constraintEqualToConstant:8],
            [dot.heightAnchor constraintEqualToConstant:8],

            [label.leadingAnchor constraintEqualToAnchor:dot.trailingAnchor constant:6],
            [label.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
            [label.topAnchor constraintEqualToAnchor:cell.topAnchor constant:4],

            [pathLabel.leadingAnchor constraintEqualToAnchor:label.leadingAnchor],
            [pathLabel.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
            [pathLabel.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:1],
        ]];
    } else {
        checkbox = [cell viewWithTag:kCheckboxTag];
        pathLabel = [cell viewWithTag:kPathTag];
        for (NSView *sub in cell.subviews) {
            if ([sub isKindOfClass:[MCSwatchDotView class]]) {
                dot = (MCSwatchDotView *)sub;
                break;
            }
        }
    }

    // allowsMixedState must be set before the state itself, or a Mixed value
    // gets clamped to On.
    if (isCategory) {
        MCCategoryNode *category = item;
        checkbox.allowsMixedState = YES;
        checkbox.state = checkboxStateFor(category.selectionState);
        cell.textField.stringValue = category.label;
        cell.textField.font = [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightSemibold];
        cell.textField.textColor = NSColor.labelColor;
        pathLabel.stringValue = category.path;
        // Ties the row to its segment in the bar above.
        dot.hidden = NO;
        dot.slot = [self.slotByCategoryLabel[category.label] integerValue];
        cell.toolTip = category.path;
    } else {
        MCEntryNode *entry = item;
        checkbox.allowsMixedState = NO;
        checkbox.state = entry.selected ? NSControlStateValueOn : NSControlStateValueOff;
        cell.textField.stringValue = entry.isDirectory ? [entry.name stringByAppendingString:@"/"] : entry.name;
        cell.textField.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
        cell.textField.textColor = NSColor.labelColor;
        pathLabel.stringValue = entry.path;
        dot.hidden = YES;
        cell.toolTip = entry.path;
    }

    return cell;
}

- (CGFloat)outlineView:(NSOutlineView *)outlineView heightOfRowByItem:(id)item {
    return 38; // two lines: name + path
}

@end
