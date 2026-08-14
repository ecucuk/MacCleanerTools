// Objective-C face of the process monitor (maccleaner/processes.hpp), in the
// mould of MCScanModel/MCBigFilesModel: core access on one serial queue,
// callbacks on main, header free of C++ types.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MCProcessKind) {
    MCProcessKindApp,
    MCProcessKindSystem,
    MCProcessKindBackground,
};

@interface MCProcessItem : NSObject
@property(nonatomic, readonly) int pid;
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, copy, readonly) NSString *path;
@property(nonatomic, readonly) MCProcessKind kind;
@property(nonatomic, readonly) double cpuPercent;      // 100 = one full core
@property(nonatomic, readonly) unsigned long long memoryBytes;
@property(nonatomic, readonly) NSTimeInterval uptimeSeconds;
/// NO when the safe-kill layer would reject this process (with the reason),
/// so the UI can grey the action out instead of offering a guaranteed FAIL.
@property(nonatomic, readonly) BOOL killable;
@property(nonatomic, copy, readonly, nullable) NSString *notKillableReason;
@end

@interface MCProcessModel : NSObject

/// Takes a fresh sample off the main thread, diffs it against the previous
/// one (CPU%% is 0 on the very first refresh -- no baseline yet), and
/// delivers the list on main, unsorted; ordering is the view's business.
/// Refreshes while one is already in flight are coalesced into a no-op.
- (void)refreshWithCompletion:(void (^)(NSArray<MCProcessItem *> *items))completion;

/// Sends SIGTERM (or SIGKILL when `force`) to `pid` after re-validating
/// against the same safe-kill rules. Synchronous; returns NO with `error`
/// set on rejection or failure.
- (BOOL)killPid:(int)pid force:(BOOL)force error:(NSString *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
