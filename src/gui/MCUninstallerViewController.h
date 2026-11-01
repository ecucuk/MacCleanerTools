// The Uninstaller tool: list the installed third-party apps, review an app's
// bundle and leftovers (support files, caches, preferences, containers,
// launch agents), and move the checked rows to the Trash. Rows that need an
// administrator are listed but never removed.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCUninstallerViewController : NSViewController
- (instancetype)init;
@end

NS_ASSUME_NONNULL_END
