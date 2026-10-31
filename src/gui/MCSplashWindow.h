// The launch splash: the app icon, name and version on the Home gradient, in
// a small borderless window above the main window. It never delays launch:
// the main window is built behind it, it stays for a short minimum time and
// then fades out. A click dismisses it at once.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCSplashWindow : NSWindow

- (instancetype)init;

/// Shows the splash, and fades it out after `seconds`.
- (void)showForSeconds:(NSTimeInterval)seconds;
- (void)dismiss;

@end

NS_ASSUME_NONNULL_END
