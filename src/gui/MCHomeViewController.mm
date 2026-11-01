#import "MCHomeViewController.h"

#import "MCScanModel.h"
#import "MCSmartOptimizer.h"
#import "MCSmartReviewController.h"
#import "MCUpdaterViewController.h"

#include "maccleaner/format.hpp"
#include "maccleaner/processes.hpp"

namespace {

NSString *humanSize(unsigned long long bytes) {
    return [NSString stringWithUTF8String:maccleaner::humanReadableBytes(bytes).c_str()];
}

constexpr NSInteger kColumns = 2;

} // namespace

#pragma mark - Card

/// One tool: its badge, its name and a one-line summary. The whole card is
/// the button.
@interface MCHomeCard : NSView
@property(nonatomic) MCTool tool;
@property(nonatomic, strong) NSTextField *titleLabel;
@property(nonatomic, strong) NSTextField *summaryLabel;
@property(nonatomic, copy) void (^onPress)(MCTool tool);
@property(nonatomic) BOOL hovered;
@end

@implementation MCHomeCard

- (instancetype)initWithTool:(MCTool)tool title:(NSString *)title symbol:(NSString *)symbolName {
    if ((self = [super initWithFrame:NSZeroRect])) {
        _tool = tool;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.wantsLayer = YES;
        self.layer.cornerRadius = 14;

        NSImageView *badge = [NSImageView imageViewWithImage:[MCTheme badgeWithSymbol:symbolName size:44 tool:tool]];
        badge.translatesAutoresizingMaskIntoConstraints = NO;

        _titleLabel = [NSTextField labelWithString:title];
        _titleLabel.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];

        _summaryLabel = [NSTextField labelWithString:@""];
        _summaryLabel.textColor = NSColor.secondaryLabelColor;
        _summaryLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        // The summary changes with every refresh: truncate, never widen the window.
        [_summaryLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                forOrientation:NSLayoutConstraintOrientationHorizontal];

        NSStackView *text = [NSStackView stackViewWithViews:@[ _titleLabel, _summaryLabel ]];
        text.orientation = NSUserInterfaceLayoutOrientationVertical;
        text.alignment = NSLayoutAttributeLeading;
        text.spacing = 4;
        text.translatesAutoresizingMaskIntoConstraints = NO;

        NSImageView *chevron = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"chevron.right"
                                                                         accessibilityDescription:nil]];
        chevron.contentTintColor = NSColor.tertiaryLabelColor;
        chevron.translatesAutoresizingMaskIntoConstraints = NO;

        [self addSubview:badge];
        [self addSubview:text];
        [self addSubview:chevron];
        [NSLayoutConstraint activateConstraints:@[
            [self.heightAnchor constraintEqualToConstant:76],
            [badge.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
            [badge.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [badge.widthAnchor constraintEqualToConstant:44],
            [badge.heightAnchor constraintEqualToConstant:44],
            [text.leadingAnchor constraintEqualToAnchor:badge.trailingAnchor constant:12],
            [text.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [text.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor constant:-8],
            [chevron.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
            [chevron.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
    }
    return self;
}

- (BOOL)wantsUpdateLayer {
    return YES;
}

// Semantic colours resolve against the current appearance only here.
- (void)updateLayer {
    self.layer.backgroundColor = NSColor.controlBackgroundColor.CGColor;
    self.layer.borderWidth = self.hovered ? 1.5 : 1;
    self.layer.borderColor =
        self.hovered ? [MCTheme startColorForTool:self.tool].CGColor : NSColor.separatorColor.CGColor;
    self.layer.shadowColor = [MCTheme startColorForTool:self.tool].CGColor;
    self.layer.shadowOffset = CGSizeMake(0, -4);
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) {
        if (area.owner == self) {
            [self removeTrackingArea:area];
        }
    }
    [self addTrackingArea:[[NSTrackingArea alloc]
                              initWithRect:NSZeroRect
                                   options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow |
                                           NSTrackingInVisibleRect
                                     owner:self
                                  userInfo:nil]];
}

- (void)mouseEntered:(NSEvent *)event {
    [self setHovered:YES animated:YES];
}

- (void)mouseExited:(NSEvent *)event {
    [self setHovered:NO animated:YES];
}

/// Lifts the card: a little larger, a glow in the tool's colour.
- (void)setHovered:(BOOL)hovered animated:(BOOL)animated {
    self.hovered = hovered;
    self.needsDisplay = YES; // border, via -updateLayer
    const CGSize size = self.bounds.size;
    // A view's layer scales about its origin: move the centre there and back.
    CATransform3D lift = CATransform3DIdentity;
    if (hovered && !MCTheme.reduceMotion) {
        lift = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0);
        lift = CATransform3DScale(lift, 1.03, 1.03, 1);
        lift = CATransform3DTranslate(lift, -size.width / 2, -size.height / 2, 0);
    }
    const float opacity = hovered ? 0.35f : 0;
    const CGFloat radius = hovered ? 14 : 6;
    if (animated) {
        for (NSString *key in @[ @"transform", @"shadowOpacity", @"shadowRadius" ]) {
            CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:key];
            animation.fromValue = [self.layer.presentationLayer valueForKey:key];
            animation.duration = 0.15;
            [self.layer addAnimation:animation forKey:key];
        }
    }
    self.layer.transform = lift;
    self.layer.shadowOpacity = opacity;
    self.layer.shadowRadius = radius;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

- (void)mouseDown:(NSEvent *)event {
    // Swallow it, so the click lands in mouseUp and not on the window.
}

- (void)mouseUp:(NSEvent *)event {
    if (NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.bounds)) {
        [self accessibilityPerformPress];
    }
}

- (BOOL)isAccessibilityElement {
    return YES;
}

- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilityButtonRole;
}

- (NSString *)accessibilityLabel {
    return [NSString stringWithFormat:@"%@, %@", self.titleLabel.stringValue, self.summaryLabel.stringValue];
}

- (BOOL)accessibilityPerformPress {
    if (self.onPress != nil) {
        self.onPress(self.tool);
    }
    return YES;
}

@end

#pragma mark - Home

@interface MCHomeViewController ()
@property(nonatomic, strong) NSMutableArray<MCHomeCard *> *cards;
@property(nonatomic, strong) MCScanModel *scanModel;
@property(nonatomic) BOOL scanning;

@property(nonatomic, strong) MCSmartOptimizer *optimizer;
@property(nonatomic, strong) MCGlassButton *optimizeButton;
@property(nonatomic, strong) MCGlassButton *stopButton;
@property(nonatomic, strong) NSButton *photosCheckbox;
@property(nonatomic, strong) NSTextField *resultLabel;
@property(nonatomic, strong) NSView *stepCard;
@property(nonatomic, strong) NSArray<NSStackView *> *stepRows;
@end

@implementation MCHomeViewController

- (instancetype)init {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _cards = [NSMutableArray array];
        _scanModel = [[MCScanModel alloc] init];
        _optimizer = [[MCSmartOptimizer alloc] init];
    }
    return self;
}

- (void)addCardForTool:(MCTool)tool title:(NSString *)title symbol:(NSString *)symbolName {
    MCHomeCard *card = [[MCHomeCard alloc] initWithTool:tool title:title symbol:symbolName];
    __weak MCHomeViewController *weakSelf = self;
    card.onPress = ^(MCTool pressed) {
        if (weakSelf.openTool != nil) {
            weakSelf.openTool(pressed);
        }
    };
    [self.cards addObject:card];
}

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 720, 560)];

    NSView *banner = [self smartOptimizeBand];

    NSStackView *grid = [[NSStackView alloc] initWithFrame:NSZeroRect];
    grid.orientation = NSUserInterfaceLayoutOrientationVertical;
    grid.alignment = NSLayoutAttributeWidth;
    grid.spacing = 12;
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSUInteger i = 0; i < self.cards.count; i += kColumns) {
        NSMutableArray<NSView *> *row = [NSMutableArray array];
        for (NSUInteger j = i; j < i + kColumns; ++j) {
            // An empty view fills the last row, so its card keeps one column's width.
            [row addObject:j < self.cards.count ? self.cards[j] : [[NSView alloc] initWithFrame:NSZeroRect]];
        }
        NSStackView *rowStack = [NSStackView stackViewWithViews:row];
        rowStack.distribution = NSStackViewDistributionFillEqually;
        rowStack.spacing = 12;
        [grid addArrangedSubview:rowStack];
    }

    [self.view addSubview:banner];
    [self.view addSubview:grid];
    const CGFloat margin = 16;
    [NSLayoutConstraint activateConstraints:@[
        [banner.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [banner.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [banner.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],
        [grid.topAnchor constraintEqualToAnchor:banner.bottomAnchor constant:16],
        [grid.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [grid.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],
        [grid.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.bottomAnchor constant:-margin],
    ]];

    for (MCHomeCard *card in self.cards) {
        card.summaryLabel.stringValue = [self staticSummaryForTool:card.tool];
    }
}

#pragma mark Smart Optimize

namespace {

NSTextField *whiteLabel(NSString *text, NSFont *font, CGFloat alpha) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = font;
    label.textColor = [NSColor colorWithWhite:1 alpha:alpha];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    // Summaries change while a run goes: truncate, never widen the window.
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    return label;
}

NSString *symbolForState(MCSmartStepState state) {
    switch (state) {
        case MCSmartStepStateWaiting: return @"circle.dotted";
        case MCSmartStepStateRunning: return @"circle.dotted"; // a spinner shows instead
        case MCSmartStepStateDone: return @"checkmark.circle.fill";
        case MCSmartStepStateSkipped: return @"minus.circle";
        case MCSmartStepStateFailed: return @"exclamationmark.triangle.fill";
    }
    return @"circle";
}

} // namespace

/// The top of Home: the Smart Optimize aurora with its text on the left,
/// the step list (while a run goes) in the middle and the round button.
- (NSView *)smartOptimizeBand {
    MCAuroraView *band = [[MCAuroraView alloc] initWithTool:MCToolSmartOptimize];
    band.layer.cornerRadius = 16;
    band.layer.masksToBounds = YES;

    NSTextField *title = whiteLabel(@"Smart Optimize", [NSFont systemFontOfSize:24 weight:NSFontWeightBold], 1);
    NSTextField *subtitle = whiteLabel(@"Runs every tool, then shows one review.\nNothing changes until you confirm.",
                                       [NSFont systemFontOfSize:13], 0.85);
    subtitle.maximumNumberOfLines = 2;
    self.photosCheckbox = [NSButton checkboxWithTitle:@"" target:nil action:nil];
    self.photosCheckbox.attributedTitle = [[NSAttributedString alloc]
        initWithString:@"Also look for similar photos"
            attributes:@{NSForegroundColorAttributeName : NSColor.whiteColor,
                         NSFontAttributeName : [NSFont systemFontOfSize:13]}];
    self.resultLabel = whiteLabel(@"", [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], 1);
    self.resultLabel.hidden = YES;
    NSStackView *text = [NSStackView stackViewWithViews:@[ title, subtitle, self.photosCheckbox, self.resultLabel ]];
    text.orientation = NSUserInterfaceLayoutOrientationVertical;
    text.alignment = NSLayoutAttributeLeading;
    text.spacing = 6;
    [text setCustomSpacing:12 afterView:subtitle];

    NSMutableArray<NSStackView *> *rows = [NSMutableArray array];
    for (NSInteger i = 0; i < MCSmartStepCount; ++i) {
        NSImageView *icon = [[NSImageView alloc] initWithFrame:NSZeroRect];
        icon.contentTintColor = NSColor.whiteColor;
        NSProgressIndicator *spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
        spinner.style = NSProgressIndicatorStyleSpinning;
        spinner.controlSize = NSControlSizeSmall;
        spinner.hidden = YES;
        NSTextField *name = whiteLabel([MCSmartOptimizer titleOfStep:(MCSmartStep)i],
                                       [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold], 1);
        [name setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh
                                       forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSTextField *detail = whiteLabel(@"", [NSFont systemFontOfSize:11], 0.8);
        NSStackView *row = [NSStackView stackViewWithViews:@[ icon, spinner, name, detail ]];
        row.spacing = 6;
        [NSLayoutConstraint activateConstraints:@[
            [icon.widthAnchor constraintEqualToConstant:16],
            [spinner.widthAnchor constraintEqualToConstant:16],
            [name.widthAnchor constraintEqualToConstant:96],
        ]];
        [rows addObject:row];
    }
    self.stepRows = rows;
    NSStackView *list = [NSStackView stackViewWithViews:rows];
    list.orientation = NSUserInterfaceLayoutOrientationVertical;
    list.alignment = NSLayoutAttributeLeading;
    list.spacing = 3;
    list.edgeInsets = NSEdgeInsetsMake(8, 14, 8, 14);
    self.stepCard = [MCTheme glassViewWithCornerRadius:14 content:list];
    self.stepCard.hidden = YES;

    self.optimizeButton = [MCGlassButton buttonWithTitle:@"Optimize"
                                                   style:MCGlassButtonStyleRound
                                                    tool:MCToolSmartOptimize
                                                  target:self
                                                  action:@selector(startSmartOptimize:)];
    self.stopButton = [MCGlassButton buttonWithTitle:@"Stop"
                                               style:MCGlassButtonStylePill
                                                tool:MCToolSmartOptimize
                                              target:self
                                              action:@selector(stopSmartOptimize:)];
    self.stopButton.hidden = YES;
    NSStackView *actions = [NSStackView stackViewWithViews:@[ self.optimizeButton, self.stopButton ]];
    actions.orientation = NSUserInterfaceLayoutOrientationVertical;

    for (NSView *view in @[ text, self.stepCard, actions ]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [band addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [band.heightAnchor constraintEqualToConstant:148],
        [text.leadingAnchor constraintEqualToAnchor:band.leadingAnchor constant:24],
        [text.centerYAnchor constraintEqualToAnchor:band.centerYAnchor],
        [text.widthAnchor constraintLessThanOrEqualToConstant:300],
        [text.widthAnchor constraintGreaterThanOrEqualToConstant:250], // the step card yields first
        [self.stepCard.leadingAnchor constraintGreaterThanOrEqualToAnchor:text.trailingAnchor constant:16],
        [self.stepCard.centerYAnchor constraintEqualToAnchor:band.centerYAnchor],
        [self.stepCard.trailingAnchor constraintEqualToAnchor:actions.leadingAnchor constant:-20],
        [actions.trailingAnchor constraintEqualToAnchor:band.trailingAnchor constant:-28],
        [actions.centerYAnchor constraintEqualToAnchor:band.centerYAnchor],
    ]];
    // The card fills what is left between the text and the button. An
    // equality, not a width: a preferred width would count in the window's
    // fitting size and widen the window at launch.
    NSLayoutConstraint *fill = [self.stepCard.leadingAnchor constraintEqualToAnchor:text.trailingAnchor constant:24];
    fill.priority = NSLayoutPriorityDefaultLow + 10; // over the step list's own hugging
    fill.active = YES;
    return band;
}

- (void)updateStepRow:(MCSmartStep)step {
    NSStackView *row = self.stepRows[(NSUInteger)step];
    NSImageView *icon = row.arrangedSubviews[0];
    NSProgressIndicator *spinner = (NSProgressIndicator *)row.arrangedSubviews[1];
    NSTextField *detail = (NSTextField *)row.arrangedSubviews[3];
    const MCSmartStepState state = [self.optimizer stateOfStep:step];
    const BOOL running = state == MCSmartStepStateRunning;
    icon.hidden = running;
    spinner.hidden = !running;
    if (running) {
        [spinner startAnimation:nil];
    } else {
        [spinner stopAnimation:nil];
    }
    icon.image = [NSImage imageWithSystemSymbolName:symbolForState(state) accessibilityDescription:nil];
    detail.stringValue = [self.optimizer summaryOfStep:step];
    const CGFloat alpha = state == MCSmartStepStateWaiting ? 0.45 : 1;
    if (row.alphaValue != alpha && !MCTheme.reduceMotion) {
        // Steps light up one after another as the run reaches them.
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.25;
            row.animator.alphaValue = alpha;
        }];
    } else {
        row.alphaValue = alpha;
    }
}

- (void)startSmartOptimize:(id)sender {
    if (self.optimizer.running) {
        return;
    }
    self.optimizeButton.enabled = NO;
    self.photosCheckbox.enabled = NO;
    self.stopButton.hidden = NO;
    self.stopButton.enabled = YES;
    self.stepCard.hidden = NO;
    self.resultLabel.hidden = YES;
    __weak MCHomeViewController *weakSelf = self;
    [self.optimizer runIncludingPhotos:self.photosCheckbox.state == NSControlStateValueOn
        stepChanged:^(MCSmartStep step) {
            [weakSelf updateStepRow:step];
        }
        completion:^(BOOL) {
            [weakSelf smartOptimizeFinished];
        }];
}

- (void)stopSmartOptimize:(id)sender {
    self.stopButton.enabled = NO;
    [self.optimizer stop];
}

- (void)smartOptimizeFinished {
    self.optimizeButton.enabled = YES;
    self.photosCheckbox.enabled = YES;
    self.stopButton.hidden = YES;

    MCSmartReviewController *review = [[MCSmartReviewController alloc] initWithOptimizer:self.optimizer];
    __weak MCHomeViewController *weakSelf = self;
    review.openTool = ^(MCTool tool) {
        if (weakSelf.openTool != nil) {
            weakSelf.openTool(tool);
        }
    };
    review.didApply = ^(NSString *summary) {
        MCHomeViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        // Stays until the next run: the outcome of what the user confirmed.
        strongSelf.resultLabel.stringValue = summary;
        strongSelf.resultLabel.hidden = NO;
        strongSelf.stepCard.hidden = YES;
        [strongSelf refreshSummaries];
    };
    [self presentViewControllerAsSheet:review];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    [self refreshSummaries];
}

#pragma mark Summaries

- (NSString *)staticSummaryForTool:(MCTool)tool {
    switch (tool) {
        case MCToolCleaner: return @"Caches, logs and build artifacts";
        case MCToolLargeFiles: return @"Find what takes up your disk";
        case MCToolPhotos: return @"Find duplicate and blurry photos";
        case MCToolOrganizer: return @"Sort a folder by type or place";
        case MCToolPerformance: return @"Processes, CPU and memory";
        case MCToolAntivirus: return @"Scan for known malware";
        case MCToolUpdater: {
            // Cached from the last complete check: a live check is too slow for Home.
            NSNumber *cached = [NSUserDefaults.standardUserDefaults objectForKey:MCUpdaterCachedCountKey];
            if (cached == nil) {
                return @"Homebrew, App Store and app updates";
            }
            return cached.integerValue == 0 ? @"Up to date at last check"
                                            : [NSString stringWithFormat:@"%ld update(s) at last check",
                                                                         (long)cached.integerValue];
        }
        case MCToolUninstaller: return @"Remove apps and their leftovers";
        case MCToolHome:
        case MCToolSmartOptimize: return @"";
    }
    return @"";
}

- (void)setSummary:(NSString *)summary forTool:(MCTool)tool {
    for (MCHomeCard *card in self.cards) {
        if (card.tool == tool) {
            card.summaryLabel.stringValue = summary;
        }
    }
}

- (void)refreshSummaries {
    [self setSummary:[self staticSummaryForTool:MCToolUpdater] forTool:MCToolUpdater];
    if (!self.scanning) {
        self.scanning = YES;
        [self setSummary:@"Scanning…" forTool:MCToolCleaner];
        __weak MCHomeViewController *weakSelf = self;
        [self.scanModel scanWithWillScanCategory:nil
                                 didScanCategory:nil
                                      completion:^{
                                          MCHomeViewController *strongSelf = weakSelf;
                                          if (strongSelf == nil) {
                                              return;
                                          }
                                          strongSelf.scanning = NO;
                                          unsigned long long total = 0;
                                          for (MCCategoryNode *category in strongSelf.scanModel.categories) {
                                              total += category.sizeBytes;
                                          }
                                          [strongSelf setSummary:[NSString stringWithFormat:@"%@ reclaimable",
                                                                                            humanSize(total)]
                                                         forTool:MCToolCleaner];
                                      }];
    }

    __weak MCHomeViewController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSURL *home = [NSURL fileURLWithPath:NSHomeDirectory()];
        NSDictionary<NSURLResourceKey, id> *values =
            [home resourceValuesForKeys:@[ NSURLVolumeAvailableCapacityForImportantUsageKey, NSURLVolumeTotalCapacityKey ]
                                  error:nil];
        NSNumber *available = values[NSURLVolumeAvailableCapacityForImportantUsageKey];
        NSNumber *total = values[NSURLVolumeTotalCapacityKey];
        const maccleaner::MemoryUsage memory = maccleaner::sampleMemoryUsage();

        dispatch_async(dispatch_get_main_queue(), ^{
            if (available != nil && total != nil) {
                [weakSelf setSummary:[NSString stringWithFormat:@"%@ free of %@",
                                                                humanSize(available.unsignedLongLongValue),
                                                                humanSize(total.unsignedLongLongValue)]
                             forTool:MCToolLargeFiles];
            }
            if (memory.totalBytes > 0) {
                [weakSelf setSummary:[NSString stringWithFormat:@"%@ of %@ memory used", humanSize(memory.usedBytes),
                                                                humanSize(memory.totalBytes)]
                             forTool:MCToolPerformance];
            }
        });
    });
}

@end
