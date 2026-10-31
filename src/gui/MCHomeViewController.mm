#import "MCHomeViewController.h"

#import "MCScanModel.h"
#import "MCToolBanner.h"

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
            [self.heightAnchor constraintEqualToConstant:84],
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
    self.layer.borderWidth = 1;
    self.layer.borderColor = NSColor.separatorColor.CGColor;
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
@end

@implementation MCHomeViewController

- (instancetype)init {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _cards = [NSMutableArray array];
        _scanModel = [[MCScanModel alloc] init];
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

    MCToolBanner *banner = [[MCToolBanner alloc] initWithTool:MCToolHome symbol:@"sparkles"];
    banner.value = @"MacCleaner";
    banner.caption = @"Pick a tool to start.";

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
        case MCToolHome: return @"";
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
