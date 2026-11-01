// Objective-C face of the Uninstaller (maccleaner/uninstaller.hpp), in the
// mould of MCUpdaterModel: all core access on one private serial queue,
// every callback delivered on the main queue, header free of C++ types.
// App sizes are the one exception: they fill in on a second queue, so a
// slow size walk never holds up the review list or the uninstall.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One installed third-party app. `sizeBytes` (0 = not known yet) and
/// `homebrew` change on the main thread after the list is shown.
@interface MCAppRow : NSObject
@property(nonatomic, copy, readonly) NSString *path;
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, copy, readonly) NSString *bundleId;
@property(nonatomic, copy, readonly) NSString *version;
@property(nonatomic) uint64_t sizeBytes;
/// Homebrew lists this bundle as an installed cask. Set by -loadLeftoversForApp:.
@property(nonatomic) BOOL homebrew;
@end

/// One row of the review list: the bundle (first) or a leftover.
@interface MCLeftoverRow : NSObject
@property(nonatomic, copy, readonly) NSString *path;
@property(nonatomic, copy, readonly) NSString *kind; // "App", "Support", "Cache", ...
@property(nonatomic, readonly) uint64_t sizeBytes;
/// Not owned by the user: listed, never removed.
@property(nonatomic, readonly) BOOL needsAdmin;
@property(nonatomic) BOOL selected; // belongs to the view
@end

/// The outcome of one row. `error` says "Needs Full Disk Access" for EPERM.
@interface MCRemovalRow : NSObject
@property(nonatomic, copy, readonly) NSString *path;
@property(nonatomic, readonly) BOOL ok;
@property(nonatomic, copy, readonly) NSString *error;
@property(nonatomic, readonly) uint64_t sizeBytes; // of the matching leftover row
@end

@interface MCUninstallerModel : NSObject

/// Installed third-party apps, sorted by name (slow: reads code signatures).
/// Their sizes then fill in one by one; `sizeUpdated` fires for each.
- (void)loadApps:(void (^)(NSArray<MCAppRow *> *apps))done
     sizeUpdated:(void (^)(MCAppRow *app))sizeUpdated;

/// The bundle, then its leftovers. Also sets `app.homebrew` before `done`.
- (void)loadLeftoversForApp:(MCAppRow *)app done:(void (^)(NSArray<MCLeftoverRow *> *items))done;

/// Moves `items` to the Trash. `refusal` is non-nil when the core refused
/// (Apple-signed or still running); the results are then empty.
- (void)uninstallApp:(MCAppRow *)app
               items:(NSArray<MCLeftoverRow *> *)items
                done:(void (^)(NSArray<MCRemovalRow *> *results, NSString *_Nullable refusal))done;

@end

NS_ASSUME_NONNULL_END
