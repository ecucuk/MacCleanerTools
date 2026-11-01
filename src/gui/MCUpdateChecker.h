// Check for Updates: asks GitHub for the latest MacCleaner release
// (selfupdate + http::get on a private queue) and shows the result. Main
// thread API.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCUpdateChecker : NSObject
+ (instancetype)shared;
/// Menu item: always fetches and always reports (new, up to date, error).
- (void)checkManually;
/// At launch: only when enabled, online and 24 h after the last success;
/// reports a new, not skipped version only.
- (void)checkAutomaticallyIfDue;
@end

NS_ASSUME_NONNULL_END
