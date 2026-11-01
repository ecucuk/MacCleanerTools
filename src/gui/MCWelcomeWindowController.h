// The welcome tour (first launch) and What's New (first launch of a new
// version), in one paged window. Both reopen from the Help menu.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCWelcomeWindowController : NSWindowController
+ (instancetype)shared;
- (void)showTour;
- (void)showWhatsNew;
/// At launch: the tour if it was never shown, else What's New if the
/// version changed since the last launch. Records both.
- (void)showAtLaunchIfNeeded;
@end

NS_ASSUME_NONNULL_END
