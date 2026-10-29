// The File Organizer tool: pick a folder (and optionally another
// destination), preview where every file goes -- as a folder outline or, for
// photos with GPS, on a map -- then move them. Moves re-validate through the
// same safety layer as deletes, scoped to the chosen source folder.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCOrganizerViewController : NSViewController
- (instancetype)init;
@end

NS_ASSUME_NONNULL_END
