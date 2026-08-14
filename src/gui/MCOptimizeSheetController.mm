#import "MCOptimizeSheetController.h"

#import "MCProcessModel.h"

#include "maccleaner/format.hpp"

namespace {

NSString *humanSize(unsigned long long bytes) {
    return [NSString stringWithUTF8String:maccleaner::humanReadableBytes(bytes).c_str()];
}

NSString *const kCheckColumn = @"check";
NSString *const kNameColumn = @"name";
NSString *const kReasonColumn = @"reason";
NSString *const kSizeColumn = @"size";

constexpr NSInteger kCheckboxTag = 1;

} // namespace

@interface MCOptimizeSheetController () <NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic, copy) NSArray<MCOptimizationCandidate *> *candidates;
@property(nonatomic, copy) void (^onConfirm)(NSArray<MCOptimizationCandidate *> *);
@property(nonatomic, strong) NSTableView *tableView;
@property(nonatomic, strong) NSTextField *summaryLabel;
@property(nonatomic, strong) NSButton *selectAllButton;
@property(nonatomic, strong) NSButton *confirmButton;
@end

@implementation MCOptimizeSheetController

- (instancetype)initWithCandidates:(NSArray<MCOptimizationCandidate *> *)candidates
                          onConfirm:(void (^)(NSArray<MCOptimizationCandidate *> *))onConfirm {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _candidates = candidates;
        _onConfirm = onConfirm;
    }
    return self;
}

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 620, 380)];

    NSTextField *title = [NSTextField labelWithString:@"These processes can be closed"];
    title.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];

    NSTextField *subtitle = [NSTextField
        wrappingLabelWithString:@"Checked rows are finished, left behind by an app you quit, or "
                                 @"update checkers that start again by themselves. Unchecked rows "
                                 @"are still alive but idle — closing those frees more memory, at "
                                 @"the cost of a reload when you go back to them."];
    subtitle.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    subtitle.textColor = NSColor.secondaryLabelColor;
    subtitle.preferredMaxLayoutWidth = 560;
    [subtitle setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                        forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.usesAlternatingRowBackgroundColors = YES;
    self.tableView.allowsEmptySelection = YES;
    self.tableView.rowHeight = 24;

    struct ColumnSpec {
        NSString *identifier;
        NSString *title;
        CGFloat width;
    };
    const ColumnSpec specs[] = {
        {kCheckColumn, @"", 22},
        {kNameColumn, @"Process", 170},
        {kReasonColumn, @"Why", 290},
        {kSizeColumn, @"Memory", 80},
    };
    for (const ColumnSpec &spec : specs) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:spec.identifier];
        column.title = spec.title;
        column.width = spec.width;
        column.minWidth = spec.width * 0.5;
        [self.tableView addTableColumn:column];
    }

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.documentView = self.tableView;
    scrollView.hasVerticalScroller = YES;
    scrollView.borderType = NSBezelBorder;
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;

    self.summaryLabel = [NSTextField labelWithString:@""];
    self.summaryLabel.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize
                                                               weight:NSFontWeightMedium];

    // With only opt-in proposals on offer every row starts unchecked, which
    // would otherwise leave the user looking at a greyed-out primary button
    // and no obvious way forward.
    self.selectAllButton = [NSButton buttonWithTitle:@"Select All" target:self action:@selector(toggleSelectAll:)];
    self.selectAllButton.bezelStyle = NSBezelStyleRounded;

    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
    cancel.bezelStyle = NSBezelStyleRounded;
    cancel.keyEquivalent = @"\033"; // Esc

    self.confirmButton = [NSButton buttonWithTitle:@"Close Selected" target:self action:@selector(confirm:)];
    self.confirmButton.bezelStyle = NSBezelStyleRounded;
    self.confirmButton.keyEquivalent = @"\r";

    NSView *spacer = [[NSView alloc] initWithFrame:NSZeroRect];
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow
                       forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *buttons = [NSStackView stackViewWithViews:@[
        self.summaryLabel, spacer, self.selectAllButton, cancel, self.confirmButton
    ]];
    buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttons.spacing = 8;
    buttons.translatesAutoresizingMaskIntoConstraints = NO;

    title.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:title];
    [self.view addSubview:subtitle];
    [self.view addSubview:scrollView];
    [self.view addSubview:buttons];

    const CGFloat margin = 20;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:margin],
        [title.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [title.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],

        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
        [subtitle.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [subtitle.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],

        [scrollView.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:12],
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],

        [buttons.topAnchor constraintEqualToAnchor:scrollView.bottomAnchor constant:12],
        [buttons.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [buttons.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],
        [buttons.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-margin],
    ]];

    [self updateSummary];
}

#pragma mark - Actions

- (void)toggleCandidate:(NSButton *)sender {
    const NSInteger row = [self.tableView rowForView:sender];
    if (row < 0 || (NSUInteger)row >= self.candidates.count) {
        return;
    }
    self.candidates[(NSUInteger)row].selected = (sender.state == NSControlStateValueOn);
    [self updateSummary];
}

- (void)toggleSelectAll:(id)sender {
    // One button, two directions: "Select All" until everything is checked,
    // then "Deselect All".
    const BOOL selectEverything = ![self allSelected];
    for (MCOptimizationCandidate *candidate in self.candidates) {
        candidate.selected = selectEverything;
    }
    [self.tableView reloadData];
    [self updateSummary];
}

- (BOOL)allSelected {
    for (MCOptimizationCandidate *candidate in self.candidates) {
        if (!candidate.selected) {
            return NO;
        }
    }
    return YES;
}

- (void)updateSummary {
    NSUInteger count = 0;
    unsigned long long bytes = 0;
    unsigned long long available = 0;
    for (MCOptimizationCandidate *candidate in self.candidates) {
        available += candidate.reclaimableBytes;
        if (candidate.selected) {
            ++count;
            bytes += candidate.reclaimableBytes;
        }
    }

    // With nothing checked, say what is on offer rather than the useless
    // "Nothing selected" -- the user opened this sheet to find out.
    self.summaryLabel.stringValue =
        count == 0 ? [NSString stringWithFormat:@"%@ available · check rows to close them",
                                                 humanSize(available)]
                    : [NSString stringWithFormat:@"%lu selected · %@", (unsigned long)count, humanSize(bytes)];
    self.selectAllButton.title = [self allSelected] ? @"Deselect All" : @"Select All";
    self.confirmButton.enabled = count > 0;
}

- (void)cancel:(id)sender {
    [self dismissController:nil];
}

- (void)confirm:(id)sender {
    NSMutableArray<MCOptimizationCandidate *> *accepted = [NSMutableArray array];
    for (MCOptimizationCandidate *candidate in self.candidates) {
        if (candidate.selected) {
            [accepted addObject:candidate];
        }
    }
    void (^callback)(NSArray<MCOptimizationCandidate *> *) = self.onConfirm;
    [self dismissController:nil];
    if (callback != nil && accepted.count > 0) {
        callback(accepted);
    }
}

#pragma mark - NSTableViewDataSource / Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.candidates.count;
}

- (NSView *)tableView:(NSTableView *)tableView
    viewForTableColumn:(NSTableColumn *)tableColumn
                    row:(NSInteger)row {
    MCOptimizationCandidate *candidate = self.candidates[(NSUInteger)row];
    NSString *identifier = tableColumn.identifier;

    if ([identifier isEqualToString:kCheckColumn]) {
        NSTableCellView *cell = [tableView makeViewWithIdentifier:kCheckColumn owner:self];
        NSButton *checkbox = nil;
        if (cell == nil) {
            cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
            cell.identifier = kCheckColumn;
            checkbox = [NSButton checkboxWithTitle:@"" target:self action:@selector(toggleCandidate:)];
            checkbox.tag = kCheckboxTag;
            checkbox.translatesAutoresizingMaskIntoConstraints = NO;
            [cell addSubview:checkbox];
            [NSLayoutConstraint activateConstraints:@[
                [checkbox.centerXAnchor constraintEqualToAnchor:cell.centerXAnchor],
                [checkbox.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            ]];
        } else {
            checkbox = [cell viewWithTag:kCheckboxTag];
        }
        checkbox.state = candidate.selected ? NSControlStateValueOn : NSControlStateValueOff;
        return cell;
    }

    NSTextField *field = [tableView makeViewWithIdentifier:identifier owner:self];
    if (field == nil) {
        field = [NSTextField labelWithString:@""];
        field.identifier = identifier;
        field.lineBreakMode = NSLineBreakByTruncatingTail;
        if ([identifier isEqualToString:kSizeColumn]) {
            field.alignment = NSTextAlignmentRight;
            field.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize
                                                          weight:NSFontWeightRegular];
        }
    }

    if ([identifier isEqualToString:kNameColumn]) {
        field.stringValue = candidate.name;
        // Opt-in rows read as secondary: they are alive and doing something,
        // and the eye should land on the safe proposals first.
        field.textColor = candidate.recommended ? NSColor.labelColor : NSColor.secondaryLabelColor;
        field.toolTip = [NSString stringWithFormat:@"%@\npid %d", candidate.path, candidate.pid];
    } else if ([identifier isEqualToString:kReasonColumn]) {
        field.stringValue = candidate.reason;
        field.textColor = candidate.recommended ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor;
        field.toolTip = candidate.kindLabel;
    } else {
        field.stringValue = humanSize(candidate.reclaimableBytes);
        field.textColor = NSColor.secondaryLabelColor;
    }
    return field;
}

@end
