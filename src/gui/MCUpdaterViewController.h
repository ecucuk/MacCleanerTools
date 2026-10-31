// The Updater tool: check Homebrew, MacPorts, App Store and Sparkle apps for
// newer versions, upgrade the selected Homebrew items in place, and send
// the rest to where they update (the App Store, the app itself, Terminal).
// Nothing runs with sudo and nothing touches the network until "Check".

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCUpdaterViewController : NSViewController
- (instancetype)init;
@end

NS_ASSUME_NONNULL_END
