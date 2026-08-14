// The Performance tool: a live, sortable view of the current user's
// processes (CPU, memory, uptime), with heavy consumers highlighted and
// Quit / Force Quit actions guarded by the core's safe-kill rules -- only
// processes the user owns, never loginwindow, always with confirmation.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCPerformanceViewController : NSViewController
- (instancetype)init;
@end

NS_ASSUME_NONNULL_END
