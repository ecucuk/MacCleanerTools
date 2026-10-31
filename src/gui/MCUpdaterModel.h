// Objective-C face of the Updater (maccleaner/updater.hpp), in the mould of
// MCOrganizerModel: all core access on one private serial queue, every
// callback delivered on the main queue, header free of C++ types.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MCUpdateSource) {
    MCUpdateSourceHomebrew,
    MCUpdateSourceMacPorts,
    MCUpdateSourceAppStore,
    MCUpdateSourceSparkle,
};

typedef NS_ENUM(NSInteger, MCUpdateRowState) {
    MCUpdateRowStateIdle,
    MCUpdateRowStatePending,
    MCUpdateRowStateUpgrading,
    MCUpdateRowStateDone,
    MCUpdateRowStateFailed,
};

/// One outdated item. `state` and `lastLine` change on the main thread while
/// an upgrade runs; `selected` belongs to the view.
@interface MCUpdateItem : NSObject
@property(nonatomic, readonly) MCUpdateSource source;
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, copy, readonly) NSString *installedVersion;
@property(nonatomic, copy, readonly) NSString *latestVersion;
@property(nonatomic, copy, readonly) NSString *appPath; // App Store and Sparkle, else empty
@property(nonatomic, copy, readonly) NSString *storeId; // App Store, else empty
@property(nonatomic, readonly) BOOL isCask;
@property(nonatomic, readonly) BOOL pinned;
/// For Terminal: "sudo port upgrade curl", "brew upgrade --cask firefox".
@property(nonatomic, copy, readonly) NSString *manualCommand;
/// Homebrew and not pinned: the app can upgrade it.
@property(nonatomic, readonly) BOOL upgradable;
@property(nonatomic) BOOL selected;
@property(nonatomic) MCUpdateRowState state;
@property(nonatomic, copy) NSString *lastLine; // last output line of a failed upgrade
@end

/// One source's outcome: not installed, failed, or checked.
@interface MCUpdateSourceStatus : NSObject
@property(nonatomic, readonly) MCUpdateSource source;
@property(nonatomic, copy, readonly) NSString *title; // "Homebrew", "App Store", ...
@property(nonatomic, readonly) BOOL available;
@property(nonatomic, copy, readonly) NSString *error; // empty = fine
/// The check was stopped before this source finished: its result is incomplete.
@property(nonatomic, readonly) BOOL skipped;
@end

@interface MCUpdaterModel : NSObject

/// YES while a check or an upgrade runs. Main-thread only.
@property(nonatomic, readonly) BOOL busy;
/// The last check's result, in source order.
@property(nonatomic, copy, readonly) NSArray<MCUpdateItem *> *items;
@property(nonatomic, copy, readonly) NSArray<MCUpdateSourceStatus *> *sources;

/// Runs brew update, then checks every source (network access). Replaces
/// `items` and `sources` before `completion`.
- (void)checkWithCompletion:(void (^)(void))completion;

/// Upgrades the given Homebrew items one at a time. `progress` fires after
/// each state change of an item.
- (void)upgradeItems:(NSArray<MCUpdateItem *> *)items
            progress:(void (^)(MCUpdateItem *item))progress
          completion:(void (^)(NSUInteger upgraded, NSUInteger failed, BOOL cancelled))completion;

/// A check skips its remaining sources; an upgrade lets the running brew
/// finish and starts no more (a killed brew can leave a lock or a partial
/// install). Completions still fire.
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
