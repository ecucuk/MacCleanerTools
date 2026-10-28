// Covers a list card when it has nothing to show: the scan animation while a
// scan runs, the tool's illustration once it is idle and empty. The owner
// decides which; this view only draws it.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCEmptyStateView : NSView

/// `illustration` names a bundled pair for +[MCTheme illustrationNamed:].
- (instancetype)initWithIllustration:(NSString *)illustration NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/// Puts `card` and this view (hidden until shown) on top of it in a new
/// container; lay out the container where the card would have gone.
- (NSView *)wrapCard:(NSScrollView *)card;

- (void)showIllustrationWithMessage:(NSString *)message;
- (void)showScanningWithMessage:(NSString *)message;
- (void)hide;

@end

NS_ASSUME_NONNULL_END
