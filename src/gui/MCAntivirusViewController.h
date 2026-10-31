// The Antivirus tool: an on-demand scan for XProtect.plist signatures,
// quarantined unsigned programs and suspicious LaunchAgents/LaunchDaemons.
// Report-only until the user picks rows and moves them to the Trash; every
// trash re-validates through the same safety layer as deletes.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCAntivirusViewController : NSViewController
- (instancetype)init;
@end

NS_ASSUME_NONNULL_END
