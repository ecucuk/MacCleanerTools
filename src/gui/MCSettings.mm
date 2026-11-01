#import "MCSettings.h"

NSNotificationName const MCSettingsDidChangeNotification = @"MCSettingsDidChangeNotification";

static NSString *const kShowSplash = @"showSplash";
static NSString *const kLaunchTool = @"launchTool";
static NSString *const kLastTool = @"lastTool";
static NSString *const kCheckUpdatesAtLaunch = @"checkUpdatesAtLaunch";
static NSString *const kLastUpdateCheck = @"lastUpdateCheck";
static NSString *const kSkippedVersion = @"skippedVersion";
static NSString *const kLargeFilesMinSizeMB = @"largeFilesMinSizeMB";
static NSString *const kIdleHelperRuleDefault = @"idleHelperRuleDefault";
static NSString *const kAppearance = @"appearance";
static NSString *const kOfflineMode = @"offlineMode";
static NSString *const kWelcomeShown = @"welcomeShown";
static NSString *const kLastSeenVersion = @"lastSeenVersion";
static NSString *const kFullDiskAccessHintSuppressed = @"fullDiskAccessHintSuppressed";

static const NSInteger kDefaultLargeFilesMB = 100;

static NSUserDefaults *defaults(void) {
    return NSUserDefaults.standardUserDefaults;
}

static void store(id _Nullable value, NSString *key) {
    if (value == nil) {
        [defaults() removeObjectForKey:key];
    } else {
        [defaults() setObject:value forKey:key];
    }
    [NSNotificationCenter.defaultCenter postNotificationName:MCSettingsDidChangeNotification object:nil];
}

@implementation MCSettings

+ (void)registerDefaults {
    [defaults() registerDefaults:@{
        kShowSplash : @YES,
        kLaunchTool : @(MCLaunchToolHome),
        kLastTool : @(MCToolHome),
        kCheckUpdatesAtLaunch : @YES,
        kLargeFilesMinSizeMB : @(kDefaultLargeFilesMB),
        kIdleHelperRuleDefault : @NO,
        kAppearance : @(MCAppearanceSystem),
        kOfflineMode : @NO,
        kWelcomeShown : @NO,
        kFullDiskAccessHintSuppressed : @NO,
    }];
}

+ (void)applyAppearance {
    switch (self.appearance) {
        case MCAppearanceLight:
            NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
            break;
        case MCAppearanceDark:
            NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
            break;
        case MCAppearanceSystem:
            NSApp.appearance = nil;
            break;
    }
}

+ (BOOL)showSplash { return [defaults() boolForKey:kShowSplash]; }
+ (void)setShowSplash:(BOOL)value { store(@(value), kShowSplash); }

+ (MCLaunchTool)launchTool { return (MCLaunchTool)[defaults() integerForKey:kLaunchTool]; }
+ (void)setLaunchTool:(MCLaunchTool)value { store(@(value), kLaunchTool); }

+ (MCTool)lastTool { return (MCTool)[defaults() integerForKey:kLastTool]; }
+ (void)setLastTool:(MCTool)value { store(@(value), kLastTool); }

+ (BOOL)checkUpdatesAtLaunch { return [defaults() boolForKey:kCheckUpdatesAtLaunch]; }
+ (void)setCheckUpdatesAtLaunch:(BOOL)value { store(@(value), kCheckUpdatesAtLaunch); }

+ (NSDate *)lastUpdateCheck {
    id value = [defaults() objectForKey:kLastUpdateCheck];
    return [value isKindOfClass:NSDate.class] ? value : nil;
}
+ (void)setLastUpdateCheck:(NSDate *)value { store(value, kLastUpdateCheck); }

+ (NSString *)skippedVersion { return [defaults() stringForKey:kSkippedVersion]; }
+ (void)setSkippedVersion:(NSString *)value { store(value, kSkippedVersion); }

+ (NSArray<NSNumber *> *)largeFilesChoicesMB {
    return @[ @50, @100, @250, @500, @1024, @5120 ];
}

+ (NSString *)labelForMegabytes:(NSInteger)megabytes {
    return megabytes >= 1024 ? [NSString stringWithFormat:@"≥ %ld GB", (long)(megabytes / 1024)]
                             : [NSString stringWithFormat:@"≥ %ld MB", (long)megabytes];
}

+ (NSInteger)largeFilesMinSizeMB {
    const NSInteger value = [defaults() integerForKey:kLargeFilesMinSizeMB];
    // A hand-edited defaults value must not reach the scan as an odd size.
    return [self.largeFilesChoicesMB containsObject:@(value)] ? value : kDefaultLargeFilesMB;
}
+ (void)setLargeFilesMinSizeMB:(NSInteger)value { store(@(value), kLargeFilesMinSizeMB); }

+ (BOOL)idleHelperRuleDefault { return [defaults() boolForKey:kIdleHelperRuleDefault]; }
+ (void)setIdleHelperRuleDefault:(BOOL)value { store(@(value), kIdleHelperRuleDefault); }

+ (MCAppearance)appearance { return (MCAppearance)[defaults() integerForKey:kAppearance]; }
+ (void)setAppearance:(MCAppearance)value {
    store(@(value), kAppearance);
    [self applyAppearance];
}

+ (BOOL)offlineMode { return [defaults() boolForKey:kOfflineMode]; }
+ (void)setOfflineMode:(BOOL)value { store(@(value), kOfflineMode); }

+ (BOOL)welcomeShown { return [defaults() boolForKey:kWelcomeShown]; }
+ (void)setWelcomeShown:(BOOL)value { store(@(value), kWelcomeShown); }

+ (NSString *)lastSeenVersion { return [defaults() stringForKey:kLastSeenVersion]; }
+ (void)setLastSeenVersion:(NSString *)value { store(value, kLastSeenVersion); }

+ (BOOL)fullDiskAccessHintSuppressed { return [defaults() boolForKey:kFullDiskAccessHintSuppressed]; }
+ (void)setFullDiskAccessHintSuppressed:(BOOL)value { store(@(value), kFullDiskAccessHintSuppressed); }

+ (NSString *)appVersion {
    NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"];
    return version.length > 0 ? version : @"0";
}

@end
