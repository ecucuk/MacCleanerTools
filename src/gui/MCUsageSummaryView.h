// The headline area above the list: total reclaimable space as a hero number,
// a stacked composition bar showing how that total splits across categories,
// and a legend naming each segment with its size.
//
// Form choice: the question this answers is "what is using the space I could
// reclaim", i.e. part-to-whole against a single total -- the same thing the
// macOS Storage bar shows. Part-to-whole reads at a glance only up to ~6
// segments, so the largest categories get their own slot and the remainder
// folds into "Other" rather than becoming unreadable slivers.
//
// Colour is categorical (identity, not magnitude): a fixed slot order, never
// cycled or generated. On a light surface several slots sit below 3:1 contrast,
// which obliges visible labels rather than colour-alone identity -- hence the
// legend text and the matching size column in the list below.

#import <AppKit/AppKit.h>

#import "MCScanModel.h"

NS_ASSUME_NONNULL_BEGIN

@interface MCUsageSummaryView : NSView

/// Recomputes the bar and legend. Returns category label -> colour slot, so
/// the outline below can show a swatch matching each category's segment.
- (NSDictionary<NSString *, NSNumber *> *)updateWithCategories:(NSArray<MCCategoryNode *> *)categories;

/// The categorical palette. Slots are assigned largest-category-first and are
/// stable for a given scan; `slot` beyond the last one returns the "Other"
/// colour rather than wrapping around.
+ (NSColor *)colorForSlot:(NSInteger)slot;

@end

NS_ASSUME_NONNULL_END
