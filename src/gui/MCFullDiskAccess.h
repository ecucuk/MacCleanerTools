// The Full Disk Access guide: why macOS blocks some folders (TCC) and a
// button that opens the right System Settings page.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCFullDiskAccess : NSObject
/// YES for an error text that a TCC denial produces: strerror(EPERM)
/// ("Operation not permitted") or the Uninstaller's "Needs Full Disk Access".
+ (BOOL)isAccessError:(nullable NSString *)text;
/// After a failed operation: a sheet at most once per launch, never after
/// "Don't show again".
+ (void)presentIfNeededForWindow:(nullable NSWindow *)window;
/// Help menu: always shows, without the "Don't show again" box.
+ (void)presentForWindow:(nullable NSWindow *)window;
/// Opens System Settings › Privacy & Security › Full Disk Access.
+ (void)openSystemSettings;
@end

NS_ASSUME_NONNULL_END
