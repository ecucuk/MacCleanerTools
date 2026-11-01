// Home's one-button optimizer: runs the existing tools' models one after
// another, then holds what they found for one combined review. It has no
// scan or delete logic of its own -- every scan, every safety check and
// every Trash move is the owning model's. Applying touches only what the
// user left checked in the review: Storage entries go to the Trash, process
// candidates get a SIGTERM. Large Files, Photos, Updater and Antivirus only
// report. Main-thread only; every callback runs on main.

#import <Foundation/Foundation.h>

#import "MCBigFilesModel.h"
#import "MCMalwareModel.h"
#import "MCProcessModel.h"
#import "MCScanModel.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MCSmartStep) {
    MCSmartStepStorage,
    MCSmartStepLargeFiles,
    MCSmartStepPhotos,
    MCSmartStepProcesses,
    MCSmartStepUpdater,
    MCSmartStepAntivirus,
};
static const NSInteger MCSmartStepCount = MCSmartStepAntivirus + 1;

typedef NS_ENUM(NSInteger, MCSmartStepState) {
    MCSmartStepStateWaiting,
    MCSmartStepStateRunning,
    MCSmartStepStateDone,
    MCSmartStepStateSkipped,
    MCSmartStepStateFailed,
};

@interface MCSmartOptimizer : NSObject

@property(nonatomic, readonly) BOOL running;
/// Storage categories, with every entry of a recommended category selected.
@property(nonatomic, strong, readonly) MCScanModel *scanModel;
@property(nonatomic, copy, readonly) NSArray<MCOptimizationCandidate *> *candidates;
@property(nonatomic, copy, readonly) NSArray<MCBigFileItem *> *largeFiles;
@property(nonatomic, readonly) NSUInteger photoGroupCount;
/// Size of every photo in a group except the first: what removing the
/// duplicates would free.
@property(nonatomic, readonly) unsigned long long photoExtraBytes;
@property(nonatomic, readonly) NSUInteger updateCount;
@property(nonatomic, copy, readonly) NSArray<MCMalwareFinding *> *findings;

+ (NSString *)titleOfStep:(MCSmartStep)step;
- (MCSmartStepState)stateOfStep:(MCSmartStep)step;
/// One line; empty while the step waits.
- (NSString *)summaryOfStep:(MCSmartStep)step;

/// Starts a run; `stepChanged` fires whenever a step's state or summary
/// changes, `completion` once at the end (also after -stop).
- (void)runIncludingPhotos:(BOOL)photos
               stepChanged:(void (^)(MCSmartStep step))stepChanged
                completion:(void (^)(BOOL cancelled))completion;
/// Cancels the running step where its model allows it (Storage cannot be
/// interrupted; the run stops after it) and skips the rest.
- (void)stop;

/// Moves the selected Storage entries to the Trash, then quits the selected
/// candidates. `summary` is one line for the user.
- (void)applyWithCompletion:(void (^)(NSString *summary))completion;

@end

NS_ASSUME_NONNULL_END
