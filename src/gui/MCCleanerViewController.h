// The Storage Cleaner tool: a category/entry outline with checkboxes, a
// delete mode selector, a clean button, and the Activity window feed. This is
// the original single-window UI, extracted into a view controller so the main
// window can host multiple tools side by side (see MCMainWindowController).

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCCleanerViewController : NSViewController
- (instancetype)init;
/// Kicks off the first scan. Call once the view is in a window on screen.
- (void)startInitialScan;
@end

NS_ASSUME_NONNULL_END
