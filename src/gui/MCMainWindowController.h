// The multi-tool shell window: a source-list sidebar on the left selects a
// tool, the right side hosts the selected tool's view controller. Tools are
// self-contained NSViewControllers (MCCleanerViewController,
// MCLargeFilesViewController, ...); adding a tool means adding a row here and
// nothing else. Built programmatically rather than from a xib so the CMake
// build needs no Interface Builder resources.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCMainWindowController : NSWindowController
- (instancetype)init;
/// Kicks off the default tool's first scan. Call once the window is on screen.
- (void)startInitialScan;
@end

NS_ASSUME_NONNULL_END
