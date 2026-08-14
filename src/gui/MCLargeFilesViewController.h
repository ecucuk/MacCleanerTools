// The Large Files tool: pick a directory (default: home), a size threshold
// and scan; results land in a sortable table with Reveal-in-Finder and
// Move-to-Trash actions. Deletion re-validates through the same safety layer
// as the cleaner, scoped to the chosen scan root.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCLargeFilesViewController : NSViewController
- (instancetype)init;
@end

NS_ASSUME_NONNULL_END
