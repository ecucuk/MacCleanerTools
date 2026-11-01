// The app's preferences. The only code that reads or writes NSUserDefaults:
// every key, type and default lives here. Each setter posts
// MCSettingsDidChangeNotification so open windows can follow.

#import <AppKit/AppKit.h>

#import "MCTheme.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MCLaunchTool) { MCLaunchToolHome, MCLaunchToolLastUsed };
typedef NS_ENUM(NSInteger, MCAppearance) { MCAppearanceSystem, MCAppearanceLight, MCAppearanceDark };

extern NSNotificationName const MCSettingsDidChangeNotification;

@interface MCSettings : NSObject

+ (void)registerDefaults;
/// Sets NSApp.appearance from `appearance`.
+ (void)applyAppearance;

@property(class, nonatomic) BOOL showSplash;
@property(class, nonatomic) MCLaunchTool launchTool;
@property(class, nonatomic) MCTool lastTool;
@property(class, nonatomic) BOOL checkUpdatesAtLaunch;
@property(class, nonatomic, nullable, copy) NSDate *lastUpdateCheck;
@property(class, nonatomic, nullable, copy) NSString *skippedVersion;
/// One of `largeFilesChoicesMB`; any other stored value reads as 100.
@property(class, nonatomic) NSInteger largeFilesMinSizeMB;
@property(class, nonatomic, readonly) NSArray<NSNumber *> *largeFilesChoicesMB;
/// "≥ 100 MB", "≥ 1 GB".
+ (NSString *)labelForMegabytes:(NSInteger)megabytes;
@property(class, nonatomic) BOOL idleHelperRuleDefault;
@property(class, nonatomic) MCAppearance appearance;
@property(class, nonatomic) BOOL offlineMode;
@property(class, nonatomic) BOOL welcomeShown;
@property(class, nonatomic, nullable, copy) NSString *lastSeenVersion;
@property(class, nonatomic) BOOL fullDiskAccessHintSuppressed;

/// CFBundleShortVersionString of the running app.
@property(class, nonatomic, readonly) NSString *appVersion;

@end

NS_ASSUME_NONNULL_END
