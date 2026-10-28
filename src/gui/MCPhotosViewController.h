// The Photo Cleaner tool: scan a folder or the Photos library for duplicate
// and blurry photos, review them with thumbnails, a preview and Quick Look,
// and remove the checked ones. Folder photos go to the Trash through the
// safety layer, scoped to the scanned folder; library photos are deleted
// through Photos, which asks first and keeps them in Recently Deleted.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCPhotosViewController : NSViewController
- (instancetype)init;
@end

NS_ASSUME_NONNULL_END
