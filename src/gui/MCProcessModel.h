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

/// One process the optimizer proposes terminating, with the reason it was
/// picked -- an optimizer that cannot explain itself is indistinguishable
/// from one that kills things at random, so the reason is not optional.
@interface MCOptimizationCandidate : NSObject
@property(nonatomic, readonly) int pid;
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, copy, readonly) NSString *path;
@property(nonatomic, copy, readonly) NSString *kindLabel; // "Orphaned helper", ...
@property(nonatomic, copy, readonly) NSString *reason;    // one user-facing line
@property(nonatomic, readonly) unsigned long long reclaimableBytes;
/// NO for proposals whose cost is a reload (a live helper of a running app).
/// Those arrive unchecked so the user opts in deliberately.
@property(nonatomic, readonly) BOOL recommended;
/// UI state: recommended candidates start selected; the user may check or
/// uncheck any of them.
@property(nonatomic) BOOL selected;
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

/// YES while `pid` still exists (in any state, including zombie). Used to
/// tell "the kill failed" apart from "it had already exited by the time we
/// got there" -- the second is the outcome the user asked for, not an error
/// to warn them about.
- (BOOL)processExists:(int)pid;

/// Takes a fresh sample off the main thread and applies the optimizer rules
/// to it, delivering the proposals on main, largest footprint first. An
/// empty array means there is genuinely nothing to reclaim -- which is the
/// normal state of a healthy Mac, and is reported as such rather than
/// padded with busywork.
- (void)findOptimizationCandidatesWithCompletion:
    (void (^)(NSArray<MCOptimizationCandidate *> *candidates))completion;

@end

NS_ASSUME_NONNULL_END
