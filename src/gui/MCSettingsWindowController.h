// Settings (⌘,): General, Cleaning, Appearance, Privacy. Every control
// writes its MCSettings property at once; there is no Apply button.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCSettingsWindowController : NSWindowController
+ (instancetype)shared;
/// "general", "cleaning", "appearance" or "privacy"; shows the window.
- (void)showTab:(NSString *)identifier;
@end

NS_ASSUME_NONNULL_END
