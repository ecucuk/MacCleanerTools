#import "MCUsageSummaryView.h"

#include "maccleaner/format.hpp"

namespace {

NSString *humanSize(unsigned long long bytes) {
    return [NSString stringWithUTF8String:maccleaner::humanReadableBytes(bytes).c_str()];
}

/// Part-to-whole stops reading at roughly six segments, so five categories get
/// their own colour and everything smaller folds into "Other".
constexpr NSInteger kMaxNamedSegments = 5;
constexpr NSInteger kOtherSlot = kMaxNamedSegments;

constexpr CGFloat kBarHeight = 22;   // spec caps bar thickness at 24
constexpr CGFloat kBarRadius = 4;    // rounded data-ends
constexpr CGFloat kSegmentGap = 2;   // surface-coloured gap between fills

/// A validated categorical palette: fixed slot order, each step chosen for its
/// own surface rather than light being auto-darkened into dark.
NSColor *paletteColor(NSInteger slot) {
    // {light, dark} per slot, in slot order.
    static const struct {
        CGFloat lr, lg, lb;
        CGFloat dr, dg, db;
    } kSlots[] = {
        {0x2a / 255.0, 0x78 / 255.0, 0xd6 / 255.0, 0x39 / 255.0, 0x87 / 255.0, 0xe5 / 255.0}, // blue
        {0xeb / 255.0, 0x68 / 255.0, 0x34 / 255.0, 0xd9 / 255.0, 0x59 / 255.0, 0x26 / 255.0}, // orange
        {0x1b / 255.0, 0xaf / 255.0, 0x7a / 255.0, 0x19 / 255.0, 0x9e / 255.0, 0x70 / 255.0}, // aqua
        {0xed / 255.0, 0xa1 / 255.0, 0x00 / 255.0, 0xc9 / 255.0, 0x85 / 255.0, 0x00 / 255.0}, // yellow
        {0xe8 / 255.0, 0x7b / 255.0, 0xa4 / 255.0, 0xd5 / 255.0, 0x51 / 255.0, 0x81 / 255.0}, // magenta
        {0x00 / 255.0, 0x83 / 255.0, 0x00 / 255.0, 0x00 / 255.0, 0x83 / 255.0, 0x00 / 255.0}, // green ("Other")
    };
    constexpr NSInteger kSlotCount = sizeof(kSlots) / sizeof(kSlots[0]);

    const NSInteger index = (slot < 0 || slot >= kSlotCount) ? kOtherSlot : slot;
    const auto &entry = kSlots[index];

    // A dynamic colour re-resolves per appearance, so the palette follows a
    // light/dark switch with no redraw plumbing of our own.
    return [NSColor colorWithName:nil
                  dynamicProvider:^NSColor *(NSAppearance *appearance) {
                      NSAppearanceName match =
                          [appearance bestMatchFromAppearancesWithNames:@[
                              NSAppearanceNameAqua, NSAppearanceNameDarkAqua
                          ]];
                      const BOOL dark = [match isEqualToString:NSAppearanceNameDarkAqua];
                      return dark ? [NSColor colorWithSRGBRed:entry.dr green:entry.dg blue:entry.db alpha:1.0]
                                  : [NSColor colorWithSRGBRed:entry.lr green:entry.lg blue:entry.lb alpha:1.0];
                  }];
}

} // namespace

#pragma mark - Bar

/// One segment of the composition bar.
@interface MCBarSegment : NSObject
@property(nonatomic, copy) NSString *label;
@property(nonatomic) unsigned long long bytes;
@property(nonatomic) NSInteger slot;
@end

@implementation MCBarSegment
@end

/// Legend swatch. Draws itself from the palette rather than caching a resolved
/// CGColor in a layer, so a light/dark switch repaints it for free.
@interface MCSwatchView : NSView
@property(nonatomic) NSInteger slot;
@end

@implementation MCSwatchView

- (NSSize)intrinsicContentSize {
    return NSMakeSize(10, 10);
}

- (void)drawRect:(NSRect)dirtyRect {
    [paletteColor(self.slot) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:3 yRadius:3] fill];
}

@end

@interface MCBarView : NSView
@property(nonatomic, copy) NSArray<MCBarSegment *> *segments;
@property(nonatomic) unsigned long long total;
@end

@implementation MCBarView

- (void)setSegments:(NSArray<MCBarSegment *> *)segments {
    _segments = [segments copy];
    self.needsDisplay = YES;
}

- (NSSize)intrinsicContentSize {
    return NSMakeSize(NSViewNoIntrinsicMetric, kBarHeight);
}

- (BOOL)isFlipped {
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    const NSRect bar = NSMakeRect(0, 0, NSWidth(self.bounds), kBarHeight);

    [NSGraphicsContext saveGraphicsState];
    // Clipping to the rounded outline gives rounded outer ends while interior
    // segment joins stay square -- no per-segment corner bookkeeping, and no
    // border stroke (a stroke around a mark is exactly what the gap replaces).
    NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:bar xRadius:kBarRadius yRadius:kBarRadius];
    [outline addClip];

    // Track: what an empty / all-clean state looks like, and what shows through
    // the 2px gaps between segments.
    [[NSColor quaternaryLabelColor] setFill];
    NSRectFill(bar);

    if (self.total == 0 || self.segments.count == 0) {
        [NSGraphicsContext restoreGraphicsState];
        return;
    }

    const CGFloat width = NSWidth(bar);
    CGFloat x = 0;
    for (NSUInteger i = 0; i < self.segments.count; ++i) {
        MCBarSegment *segment = self.segments[i];
        const BOOL last = (i == self.segments.count - 1);

        CGFloat share = width * (CGFloat)((double)segment.bytes / (double)self.total);
        // A category worth a fraction of a pixel would vanish entirely; give it
        // a visible minimum. The legend and the list carry the exact bytes, so
        // the small distortion this introduces costs no information.
        if (share < kSegmentGap + 1 && segment.bytes > 0) {
            share = kSegmentGap + 1;
        }

        CGFloat drawWidth = last ? (width - x) : (share - kSegmentGap);
        if (drawWidth <= 0) {
            x += share;
            continue;
        }

        [paletteColor(segment.slot) setFill];
        NSRectFill(NSMakeRect(x, 0, drawWidth, kBarHeight));
        x += share;
        if (x >= width) {
            break;
        }
    }

    [NSGraphicsContext restoreGraphicsState];
}

@end

#pragma mark - Summary view

@interface MCUsageSummaryView ()
@property(nonatomic, strong) NSTextField *headline;
@property(nonatomic, strong) NSTextField *caption;
@property(nonatomic, strong) MCBarView *bar;
@property(nonatomic, strong) NSStackView *legend;
@end

@implementation MCUsageSummaryView

- (instancetype)initWithFrame:(NSRect)frameRect {
    if ((self = [super initWithFrame:frameRect])) {
        [self build];
    }
    return self;
}

- (void)build {
    self.headline = [NSTextField labelWithString:@"—"];
    self.headline.font = [NSFont monospacedDigitSystemFontOfSize:28 weight:NSFontWeightBold];
    self.headline.textColor = NSColor.labelColor;

    self.caption = [NSTextField labelWithString:@"reclaimable"];
    self.caption.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    self.caption.textColor = NSColor.secondaryLabelColor;

    NSStackView *headlineRow = [NSStackView stackViewWithViews:@[ self.headline, self.caption ]];
    headlineRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    headlineRow.alignment = NSLayoutAttributeFirstBaseline;
    headlineRow.spacing = 6;

    self.bar = [[MCBarView alloc] initWithFrame:NSZeroRect];
    self.bar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.bar.heightAnchor constraintEqualToConstant:kBarHeight].active = YES;

    self.legend = [NSStackView stackViewWithViews:@[]];
    self.legend.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self.legend.spacing = 14;
    self.legend.alignment = NSLayoutAttributeCenterY;

    NSStackView *column = [NSStackView stackViewWithViews:@[ headlineRow, self.bar, self.legend ]];
    column.orientation = NSUserInterfaceLayoutOrientationVertical;
    column.alignment = NSLayoutAttributeLeading;
    column.spacing = 8;
    column.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:column];

    [NSLayoutConstraint activateConstraints:@[
        [column.topAnchor constraintEqualToAnchor:self.topAnchor],
        [column.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [column.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [column.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [self.bar.widthAnchor constraintEqualToAnchor:column.widthAnchor],
    ]];
}

+ (NSColor *)colorForSlot:(NSInteger)slot {
    return paletteColor(slot);
}

- (NSDictionary<NSString *, NSNumber *> *)updateWithCategories:(NSArray<MCCategoryNode *> *)categories {
    // Largest first, so slot assignment (and therefore colour) is driven by
    // size rather than by scan order.
    NSArray<MCCategoryNode *> *sorted =
        [categories sortedArrayUsingComparator:^NSComparisonResult(MCCategoryNode *a, MCCategoryNode *b) {
            if (a.sizeBytes == b.sizeBytes) {
                return NSOrderedSame;
            }
            return a.sizeBytes > b.sizeBytes ? NSOrderedAscending : NSOrderedDescending;
        }];

    unsigned long long total = 0;
    for (MCCategoryNode *category in sorted) {
        total += category.sizeBytes;
    }

    NSMutableDictionary<NSString *, NSNumber *> *slotByLabel = [NSMutableDictionary dictionary];
    NSMutableArray<MCBarSegment *> *segments = [NSMutableArray array];
    unsigned long long otherBytes = 0;

    for (NSUInteger i = 0; i < sorted.count; ++i) {
        MCCategoryNode *category = sorted[i];
        if ((NSInteger)i < kMaxNamedSegments) {
            MCBarSegment *segment = [[MCBarSegment alloc] init];
            segment.label = category.label;
            segment.bytes = category.sizeBytes;
            segment.slot = (NSInteger)i;
            [segments addObject:segment];
            slotByLabel[category.label] = @((NSInteger)i);
        } else {
            otherBytes += category.sizeBytes;
            slotByLabel[category.label] = @(kOtherSlot);
        }
    }

    if (otherBytes > 0) {
        MCBarSegment *other = [[MCBarSegment alloc] init];
        other.label = @"Other";
        other.bytes = otherBytes;
        other.slot = kOtherSlot;
        [segments addObject:other];
    }

    self.headline.stringValue = humanSize(total);
    self.caption.stringValue = sorted.count == 0
                                    ? @"nothing found to clean"
                                    : [NSString stringWithFormat:@"reclaimable across %lu categories",
                                                                  (unsigned long)sorted.count];
    self.bar.total = total;
    self.bar.segments = segments;
    [self rebuildLegendWithSegments:segments];

    return slotByLabel;
}

- (void)rebuildLegendWithSegments:(NSArray<MCBarSegment *> *)segments {
    for (NSView *view in [self.legend.arrangedSubviews copy]) {
        [self.legend removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    for (MCBarSegment *segment in segments) {
        // Swatch + text: identity is never carried by colour alone, which is
        // what the light-surface contrast warning requires.
        MCSwatchView *swatch = [[MCSwatchView alloc] initWithFrame:NSZeroRect];
        swatch.slot = segment.slot;
        swatch.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [swatch.widthAnchor constraintEqualToConstant:10],
            [swatch.heightAnchor constraintEqualToConstant:10],
        ]];

        NSTextField *label = [NSTextField labelWithString:[NSString stringWithFormat:@"%@ · %@", segment.label,
                                                                                       humanSize(segment.bytes)]];
        label.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        label.textColor = NSColor.secondaryLabelColor;
        label.lineBreakMode = NSLineBreakByTruncatingTail;

        NSStackView *item = [NSStackView stackViewWithViews:@[ swatch, label ]];
        item.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        item.spacing = 5;
        item.alignment = NSLayoutAttributeCenterY;
        [self.legend addArrangedSubview:item];
    }
}

@end
