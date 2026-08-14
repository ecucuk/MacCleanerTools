// The single-window UI: a category/entry outline with checkboxes, a delete
// mode selector, and a clean button. Built programmatically rather than from a
// xib so the CMake build needs no Interface Builder resources.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCMainWindowController : NSWindowController
- (instancetype)init;
/// Kicks off the first scan. Call once the window is on screen.
- (void)startInitialScan;
@end

NS_ASSUME_NONNULL_END
