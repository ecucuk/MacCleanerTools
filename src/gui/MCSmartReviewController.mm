#import "MCSmartReviewController.h"

#include "maccleaner/format.hpp"

namespace {

NSString *humanSize(unsigned long long bytes) {
    return [NSString stringWithUTF8String:maccleaner::humanReadableBytes(bytes).c_str()];
}

// Checkbox tags: Storage categories from 0, process candidates from here.
constexpr NSInteger kCandidateTagBase = 10000;

NSTextField *label(NSString *text, NSFont *font, NSColor *color) {
    NSTextField *field = [NSTextField labelWithString:text];
    field.font = font;
    field.textColor = color;
    field.lineBreakMode = NSLineBreakByTruncatingMiddle;
    // Paths and reasons vary: truncate, never widen the sheet.
    [field setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    return field;
}

} // namespace

/// Top-down document view for the scrolling list.
@interface MCSmartReviewFlippedView : NSView
@end

@implementation MCSmartReviewFlippedView
- (BOOL)isFlipped {
    return YES;
}
@end

@interface MCSmartReviewController ()
@property(nonatomic, strong) MCSmartOptimizer *optimizer;
@property(nonatomic, strong) NSTextField *totalLabel;
@property(nonatomic, strong) NSButton *applyButton;
@property(nonatomic, strong) NSButton *cancelButton;
@property(nonatomic, strong) NSProgressIndicator *spinner;
@end

@implementation MCSmartReviewController

- (instancetype)initWithOptimizer:(MCSmartOptimizer *)optimizer {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _optimizer = optimizer;
    }
    return self;
}

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 600, 520)];

    MCAuroraView *header = [[MCAuroraView alloc] initWithTool:MCToolSmartOptimize];
    NSImageView *badge = [NSImageView
        imageViewWithImage:[MCTheme badgeWithSymbol:[MCTheme symbolForTool:MCToolSmartOptimize]
                                               size:48
                                               tool:MCToolSmartOptimize]];
    NSTextField *title = label(@"Review Smart Optimize", [NSFont systemFontOfSize:20 weight:NSFontWeightBold],
                               NSColor.whiteColor);
    self.totalLabel = label(@"", [NSFont systemFontOfSize:13], [NSColor colorWithWhite:1 alpha:0.85]);
    NSStackView *titles = [NSStackView stackViewWithViews:@[ title, self.totalLabel ]];
    titles.orientation = NSUserInterfaceLayoutOrientationVertical;
    titles.alignment = NSLayoutAttributeLeading;
    titles.spacing = 2;
    NSStackView *headerRow = [NSStackView stackViewWithViews:@[ badge, titles ]];
    headerRow.spacing = 14;
    headerRow.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:headerRow];

    NSStackView *list = [[NSStackView alloc] initWithFrame:NSZeroRect];
    list.orientation = NSUserInterfaceLayoutOrientationVertical;
    list.alignment = NSLayoutAttributeLeading;
    list.spacing = 6;
    list.translatesAutoresizingMaskIntoConstraints = NO;
    [self fillList:list];

    MCSmartReviewFlippedView *document = [[MCSmartReviewFlippedView alloc] initWithFrame:NSZeroRect];
    document.translatesAutoresizingMaskIntoConstraints = NO;
    [document addSubview:list];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = NO;
    scroll.documentView = document;

    self.cancelButton = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
    self.cancelButton.keyEquivalent = @"\033";
    self.applyButton = [NSButton buttonWithTitle:@"Move to Trash & Quit Processes"
                                          target:self
                                          action:@selector(apply:)];
    self.applyButton.keyEquivalent = @"\r";
    self.spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.controlSize = NSControlSizeSmall;
    self.spinner.displayedWhenStopped = NO;
    NSTextField *trashNote = label(@"Files go to the Trash, so you can put them back.",
                                   [NSFont systemFontOfSize:NSFont.smallSystemFontSize],
                                   NSColor.secondaryLabelColor);
    NSStackView *buttons =
        [NSStackView stackViewWithViews:@[ trashNote, self.spinner, self.cancelButton, self.applyButton ]];
    buttons.spacing = 10;
    [buttons setCustomSpacing:20 afterView:trashNote];
    buttons.translatesAutoresizingMaskIntoConstraints = NO;

    for (NSView *view in @[ header, scroll, buttons ]) {
        [self.view addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [headerRow.topAnchor constraintEqualToAnchor:header.topAnchor constant:20],
        [headerRow.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-20],
        [headerRow.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],
        [headerRow.trailingAnchor constraintLessThanOrEqualToAnchor:header.trailingAnchor constant:-20],

        [scroll.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:8],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [document.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
        [list.topAnchor constraintEqualToAnchor:document.topAnchor constant:8],
        [list.bottomAnchor constraintEqualToAnchor:document.bottomAnchor constant:-8],
        [list.leadingAnchor constraintEqualToAnchor:document.leadingAnchor constant:20],
        [list.trailingAnchor constraintEqualToAnchor:document.trailingAnchor constant:-20],

        [buttons.topAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:12],
        [buttons.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:20],
        [buttons.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [buttons.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-16],
    ]];
    [self updateTotals];
}

#pragma mark List

- (void)addSection:(MCSmartStep)step to:(NSStackView *)list {
    NSTextField *heading = label([MCSmartOptimizer titleOfStep:step],
                                 [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], NSColor.labelColor);
    [list addArrangedSubview:heading];
    [list setCustomSpacing:4 afterView:heading];
    if (list.arrangedSubviews.count > 1) {
        [list setCustomSpacing:16 afterView:list.arrangedSubviews[list.arrangedSubviews.count - 2]];
    }
}

- (NSView *)row:(NSArray<NSView *> *)views to:(NSStackView *)list {
    NSStackView *row = [NSStackView stackViewWithViews:views];
    row.spacing = 8;
    [list addArrangedSubview:row];
    [row.widthAnchor constraintEqualToAnchor:list.widthAnchor].active = YES;
    return row;
}

- (NSButton *)checkbox:(NSString *)title checked:(BOOL)checked tag:(NSInteger)tag {
    NSButton *box = [NSButton checkboxWithTitle:title target:self action:@selector(toggle:)];
    box.state = checked ? NSControlStateValueOn : NSControlStateValueOff;
    box.tag = tag;
    box.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [box setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                  forOrientation:NSLayoutConstraintOrientationHorizontal];
    return box;
}

/// A step's own summary line, plus an Open button for a tool that has
/// something to look at.
- (void)reportRowForStep:(MCSmartStep)step tool:(MCTool)tool openable:(BOOL)openable to:(NSStackView *)list {
    NSTextField *summary = label([self.optimizer summaryOfStep:step], [NSFont systemFontOfSize:13],
                                 NSColor.secondaryLabelColor);
    NSMutableArray<NSView *> *views = [NSMutableArray arrayWithObject:summary];
    if (openable) {
        NSView *spacer = [[NSView alloc] initWithFrame:NSZeroRect];
        [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSButton *open = [NSButton buttonWithTitle:@"Open" target:self action:@selector(open:)];
        open.tag = tool;
        open.controlSize = NSControlSizeSmall;
        [views addObjectsFromArray:@[ spacer, open ]];
    }
    [self row:views to:list];
}

- (void)fillList:(NSStackView *)list {
    MCSmartOptimizer *optimizer = self.optimizer;

    [self addSection:MCSmartStepStorage to:list];
    NSInteger tag = 0;
    BOOL anyCategory = NO;
    for (MCCategoryNode *category in optimizer.scanModel.categories) {
        if (category.sizeBytes > 0) {
            anyCategory = YES;
            NSString *title = [NSString stringWithFormat:@"%@ — %@", category.label, humanSize(category.sizeBytes)];
            [self row:@[ [self checkbox:title
                                checked:category.selectionState != MCSelectionStateNone
                                    tag:tag] ]
                   to:list];
        }
        ++tag;
    }
    if (!anyCategory) {
        [self reportRowForStep:MCSmartStepStorage tool:MCToolCleaner openable:NO to:list];
    }

    [self addSection:MCSmartStepProcesses to:list];
    [optimizer.candidates enumerateObjectsUsingBlock:^(MCOptimizationCandidate *candidate, NSUInteger i, BOOL *) {
        NSString *title = [NSString stringWithFormat:@"%@ — %@ (%@)", candidate.name, candidate.reason,
                                                     humanSize(candidate.reclaimableBytes)];
        [self row:@[ [self checkbox:title checked:candidate.selected tag:kCandidateTagBase + (NSInteger)i] ]
               to:list];
    }];
    if (optimizer.candidates.count == 0) {
        [self reportRowForStep:MCSmartStepProcesses tool:MCToolPerformance openable:NO to:list];
    }

    // Report-only steps: open the tool to act on what they found.
    const struct {
        MCSmartStep step;
        MCTool tool;
        BOOL found;
    } reports[] = {
        {MCSmartStepLargeFiles, MCToolLargeFiles, optimizer.largeFiles.count > 0},
        {MCSmartStepPhotos, MCToolPhotos, optimizer.photoGroupCount > 0},
        {MCSmartStepUpdater, MCToolUpdater, optimizer.updateCount > 0},
        {MCSmartStepAntivirus, MCToolAntivirus, optimizer.findings.count > 0},
    };
    for (const auto &report : reports) {
        [self addSection:report.step to:list];
        [self reportRowForStep:report.step tool:report.tool openable:report.found to:list];
    }
}

#pragma mark Actions

- (void)toggle:(NSButton *)sender {
    const BOOL on = sender.state == NSControlStateValueOn;
    if (sender.tag >= kCandidateTagBase) {
        self.optimizer.candidates[(NSUInteger)(sender.tag - kCandidateTagBase)].selected = on;
    } else {
        [self.optimizer.scanModel.categories[(NSUInteger)sender.tag] setAllEntriesSelected:on];
    }
    [self updateTotals];
}

- (void)updateTotals {
    NSUInteger quit = 0;
    for (MCOptimizationCandidate *candidate in self.optimizer.candidates) {
        quit += candidate.selected ? 1 : 0;
    }
    const unsigned long long bytes = self.optimizer.scanModel.selectedBytes;
    self.applyButton.enabled = bytes > 0 || quit > 0;
    if (!self.applyButton.enabled) {
        self.totalLabel.stringValue = @"Your Mac is in good shape — nothing is selected.";
        return;
    }
    self.totalLabel.stringValue = [NSString stringWithFormat:@"%@ to the Trash, %lu %@ to quit", humanSize(bytes),
                                                             (unsigned long)quit,
                                                             quit == 1 ? @"process" : @"processes"];
}

- (void)cancel:(id)sender {
    [self dismissController:self];
}

- (void)open:(NSButton *)sender {
    void (^openTool)(MCTool) = self.openTool;
    [self dismissController:self];
    if (openTool != nil) {
        openTool((MCTool)sender.tag);
    }
}

- (void)apply:(id)sender {
    self.applyButton.enabled = NO;
    self.cancelButton.enabled = NO;
    [self.spinner startAnimation:nil];
    __weak MCSmartReviewController *weakSelf = self;
    [self.optimizer applyWithCompletion:^(NSString *summary) {
        MCSmartReviewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        [strongSelf.spinner stopAnimation:nil];
        void (^didApply)(NSString *) = strongSelf.didApply;
        [strongSelf dismissController:strongSelf];
        if (didApply != nil) {
            didApply(summary);
        }
    }];
}

@end
