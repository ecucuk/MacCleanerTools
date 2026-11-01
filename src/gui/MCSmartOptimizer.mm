#import "MCSmartOptimizer.h"

#import "MCPhotoModel.h"
#import "MCSettings.h"
#import "MCUpdaterModel.h"

#include "maccleaner/cleaner.hpp"
#include "maccleaner/format.hpp"
#include "maccleaner/photos.hpp"

namespace {

NSString *humanSize(unsigned long long bytes) {
    return [NSString stringWithUTF8String:maccleaner::humanReadableBytes(bytes).c_str()];
}

constexpr unsigned long long kLargeFileBytes = 500ull * 1000 * 1000;
constexpr NSUInteger kLargeFileCount = 10;

} // namespace

@interface MCSmartOptimizer ()
@property(nonatomic) BOOL running;
@property(nonatomic) BOOL stopRequested;
@property(nonatomic) BOOL includePhotos;
@property(nonatomic) MCSmartStep currentStep;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *states;
@property(nonatomic, strong) NSMutableArray<NSString *> *summaries;
@property(nonatomic, copy, nullable) void (^stepChanged)(MCSmartStep step);
@property(nonatomic, copy, nullable) void (^completion)(BOOL cancelled);

@property(nonatomic, strong, readwrite) MCScanModel *scanModel;
@property(nonatomic, strong) MCBigFilesModel *bigFilesModel;
@property(nonatomic, strong) MCPhotoModel *photoModel;
@property(nonatomic, strong) MCProcessModel *processModel;
@property(nonatomic, strong) MCUpdaterModel *updaterModel;
@property(nonatomic, strong) MCMalwareModel *malwareModel;

@property(nonatomic, copy, readwrite) NSArray<MCOptimizationCandidate *> *candidates;
@property(nonatomic, copy, readwrite) NSArray<MCBigFileItem *> *largeFiles;
@property(nonatomic, readwrite) NSUInteger photoGroupCount;
@property(nonatomic, readwrite) unsigned long long photoExtraBytes;
@property(nonatomic, readwrite) NSUInteger updateCount;
@property(nonatomic, copy, readwrite) NSArray<MCMalwareFinding *> *findings;
@end

@implementation MCSmartOptimizer

- (instancetype)init {
    if ((self = [super init])) {
        _states = [NSMutableArray array];
        _summaries = [NSMutableArray array];
        for (NSInteger i = 0; i < MCSmartStepCount; ++i) {
            [_states addObject:@(MCSmartStepStateWaiting)];
            [_summaries addObject:@""];
        }
        _candidates = @[];
        _largeFiles = @[];
        _findings = @[];
    }
    return self;
}

+ (NSString *)titleOfStep:(MCSmartStep)step {
    switch (step) {
        case MCSmartStepStorage: return @"Storage Cleaner";
        case MCSmartStepLargeFiles: return @"Large Files";
        case MCSmartStepPhotos: return @"Photo Cleaner";
        case MCSmartStepProcesses: return @"Processes";
        case MCSmartStepUpdater: return @"Updater";
        case MCSmartStepAntivirus: return @"Antivirus";
    }
    return @"";
}

- (MCSmartStepState)stateOfStep:(MCSmartStep)step {
    return (MCSmartStepState)self.states[(NSUInteger)step].integerValue;
}

- (NSString *)summaryOfStep:(MCSmartStep)step {
    return self.summaries[(NSUInteger)step];
}

- (void)setStep:(MCSmartStep)step state:(MCSmartStepState)state summary:(NSString *)summary {
    self.states[(NSUInteger)step] = @(state);
    self.summaries[(NSUInteger)step] = summary;
    if (self.stepChanged != nil) {
        self.stepChanged(step);
    }
}

#pragma mark Run

- (void)runIncludingPhotos:(BOOL)photos
               stepChanged:(void (^)(MCSmartStep step))stepChanged
                completion:(void (^)(BOOL cancelled))completion {
    if (self.running) {
        return;
    }
    // Fresh models every run: nothing from a previous run's selection survives.
    self.scanModel = [[MCScanModel alloc] init];
    self.bigFilesModel = [[MCBigFilesModel alloc] init];
    self.photoModel = [[MCPhotoModel alloc] init];
    self.processModel = [[MCProcessModel alloc] init];
    self.updaterModel = [[MCUpdaterModel alloc] init];
    self.malwareModel = [[MCMalwareModel alloc] init];
    self.candidates = @[];
    self.largeFiles = @[];
    self.findings = @[];
    self.photoGroupCount = 0;
    self.photoExtraBytes = 0;
    self.updateCount = 0;

    self.includePhotos = photos;
    self.stopRequested = NO;
    self.running = YES;
    self.stepChanged = stepChanged;
    self.completion = completion;
    for (NSInteger i = 0; i < MCSmartStepCount; ++i) {
        [self setStep:(MCSmartStep)i state:MCSmartStepStateWaiting summary:@""];
    }
    [self runStep:MCSmartStepStorage];
}

- (void)stop {
    if (!self.running || self.stopRequested) {
        return;
    }
    self.stopRequested = YES;
    switch (self.currentStep) {
        case MCSmartStepStorage: break; // MCScanModel has no cancel: stop after it
        case MCSmartStepLargeFiles: [self.bigFilesModel cancelScan]; break;
        case MCSmartStepPhotos: [self.photoModel cancelScan]; break;
        case MCSmartStepProcesses: break; // a two-sample pass, about a second
        case MCSmartStepUpdater: [self.updaterModel cancel]; break;
        case MCSmartStepAntivirus: [self.malwareModel cancel]; break;
    }
}

/// Every step ends here: record the outcome, then start the next one.
- (void)finishStep:(MCSmartStep)step state:(MCSmartStepState)state summary:(NSString *)summary {
    if (self.stopRequested && state == MCSmartStepStateDone) {
        summary = [summary stringByAppendingString:@" (stopped early)"];
    }
    [self setStep:step state:state summary:summary];
    [self runStep:(MCSmartStep)(step + 1)];
}

- (void)runStep:(MCSmartStep)step {
    if (step >= MCSmartStepCount || self.stopRequested) {
        for (NSInteger i = step; i < MCSmartStepCount; ++i) {
            [self setStep:(MCSmartStep)i state:MCSmartStepStateSkipped summary:@"Stopped"];
        }
        self.running = NO;
        void (^completion)(BOOL) = self.completion;
        self.completion = nil;
        self.stepChanged = nil;
        if (completion != nil) {
            completion(self.stopRequested);
        }
        return;
    }
    self.currentStep = step;
    [self setStep:step state:MCSmartStepStateRunning summary:@"Scanning…"];
    switch (step) {
        case MCSmartStepStorage: [self runStorage]; break;
        case MCSmartStepLargeFiles: [self runLargeFiles]; break;
        case MCSmartStepPhotos: [self runPhotos]; break;
        case MCSmartStepProcesses: [self runProcesses]; break;
        case MCSmartStepUpdater: [self runUpdater]; break;
        case MCSmartStepAntivirus: [self runAntivirus]; break;
    }
}

- (void)runStorage {
    __weak MCSmartOptimizer *weakSelf = self;
    [self.scanModel
        scanWithWillScanCategory:^(NSString *label, NSString *) {
            [weakSelf setStep:MCSmartStepStorage state:MCSmartStepStateRunning summary:label];
        }
        didScanCategory:nil
        completion:^{
            MCSmartOptimizer *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            for (MCCategoryNode *category in strongSelf.scanModel.categories) {
                [category setAllEntriesSelected:maccleaner::isRecommendedForAutoClean(
                                                    static_cast<maccleaner::Category>(category.rawCategory))];
            }
            const unsigned long long bytes = strongSelf.scanModel.selectedBytes;
            [strongSelf finishStep:MCSmartStepStorage
                             state:MCSmartStepStateDone
                           summary:bytes == 0 ? @"Nothing to clean"
                                              : [NSString stringWithFormat:@"%@ of caches and logs", humanSize(bytes)]];
        }];
}

- (void)runLargeFiles {
    __weak MCSmartOptimizer *weakSelf = self;
    [self.bigFilesModel scanUnder:NSHomeDirectory()
                     minSizeBytes:kLargeFileBytes
                       maxResults:kLargeFileCount
                         progress:^(uint64_t visited, NSString *) {
                             [weakSelf setStep:MCSmartStepLargeFiles
                                         state:MCSmartStepStateRunning
                                       summary:[NSString stringWithFormat:@"%llu items checked",
                                                                          (unsigned long long)visited]];
                         }
                    resultsUpdate:nil
                       completion:^(NSArray<MCBigFileItem *> *files) {
                           MCSmartOptimizer *strongSelf = weakSelf;
                           if (strongSelf == nil) {
                               return;
                           }
                           strongSelf.largeFiles = files;
                           unsigned long long total = 0;
                           for (MCBigFileItem *file in files) {
                               total += file.sizeBytes;
                           }
                           [strongSelf finishStep:MCSmartStepLargeFiles
                                            state:MCSmartStepStateDone
                                          summary:files.count == 0
                                                      ? @"No files over 500 MB"
                                                      : [NSString stringWithFormat:@"%lu files over 500 MB, %@",
                                                                                   (unsigned long)files.count,
                                                                                   humanSize(total)]];
                       }];
}

- (void)runPhotos {
    if (!self.includePhotos) {
        [self finishStep:MCSmartStepPhotos state:MCSmartStepStateSkipped summary:@"Not selected"];
        return;
    }
    NSString *pictures = [NSHomeDirectory() stringByAppendingPathComponent:@"Pictures"];
    __weak MCSmartOptimizer *weakSelf = self;
    [self.photoModel scanFolder:pictures
                       progress:^(uint64_t done, NSString *) {
                           [weakSelf setStep:MCSmartStepPhotos
                                       state:MCSmartStepStateRunning
                                     summary:[NSString stringWithFormat:@"%llu photos read",
                                                                        (unsigned long long)done]];
                       }
                     completion:^(NSArray<MCPhotoItem *> *items, NSUInteger) {
                         MCSmartOptimizer *strongSelf = weakSelf;
                         if (strongSelf == nil) {
                             return;
                         }
                         NSArray<NSArray<MCPhotoItem *> *> *groups =
                             [strongSelf.photoModel groupsOfItems:items
                                                      maxDistance:maccleaner::photos::kDefaultMaxDistance];
                         unsigned long long extra = 0;
                         for (NSArray<MCPhotoItem *> *group in groups) {
                             for (NSUInteger i = 1; i < group.count; ++i) {
                                 extra += group[i].sizeBytes;
                             }
                         }
                         strongSelf.photoGroupCount = groups.count;
                         strongSelf.photoExtraBytes = extra;
                         [strongSelf finishStep:MCSmartStepPhotos
                                          state:MCSmartStepStateDone
                                        summary:groups.count == 0
                                                    ? @"No similar photos"
                                                    : [NSString stringWithFormat:@"%lu groups of similar photos, %@",
                                                                                 (unsigned long)groups.count,
                                                                                 humanSize(extra)]];
                     }];
}

- (void)runProcesses {
    __weak MCSmartOptimizer *weakSelf = self;
    [self.processModel findOptimizationCandidatesWithCompletion:^(NSArray<MCOptimizationCandidate *> *candidates) {
        MCSmartOptimizer *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        strongSelf.candidates = candidates;
        NSUInteger recommended = 0;
        for (MCOptimizationCandidate *candidate in candidates) {
            recommended += candidate.recommended ? 1 : 0;
        }
        [strongSelf finishStep:MCSmartStepProcesses
                         state:MCSmartStepStateDone
                       summary:candidates.count == 0
                                   ? @"Nothing to close"
                                   : [NSString stringWithFormat:@"%lu can be closed, %lu recommended",
                                                                (unsigned long)candidates.count,
                                                                (unsigned long)recommended]];
    }];
}

- (void)runUpdater {
    if (MCSettings.offlineMode) {
        [self finishStep:MCSmartStepUpdater state:MCSmartStepStateSkipped summary:@"Offline mode"];
        return;
    }
    __weak MCSmartOptimizer *weakSelf = self;
    [self.updaterModel checkWithCompletion:^{
        MCSmartOptimizer *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        // Every item is an available update; `upgradable` only says whether
        // MacCleaner can install it itself (Homebrew), as the Updater counts.
        const NSUInteger count = strongSelf.updaterModel.items.count;
        strongSelf.updateCount = count;
        [strongSelf finishStep:MCSmartStepUpdater
                         state:MCSmartStepStateDone
                       summary:count == 0 ? @"Everything is up to date"
                                          : [NSString stringWithFormat:@"%lu updates available", (unsigned long)count]];
    }];
}

- (void)runAntivirus {
    __weak MCSmartOptimizer *weakSelf = self;
    [self.malwareModel scanFolder:nil
        progress:^(NSString *status) {
            [weakSelf setStep:MCSmartStepAntivirus state:MCSmartStepStateRunning summary:status];
        }
        completion:^(NSArray<MCMalwareFinding *> *findings, uint64_t filesScanned, uint64_t, NSUInteger, BOOL) {
            MCSmartOptimizer *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            strongSelf.findings = findings;
            [strongSelf finishStep:MCSmartStepAntivirus
                             state:MCSmartStepStateDone
                           summary:findings.count == 0
                                       ? [NSString stringWithFormat:@"No threats in %llu files",
                                                                    (unsigned long long)filesScanned]
                                       : [NSString stringWithFormat:@"%lu findings to review",
                                                                    (unsigned long)findings.count]];
        }];
}

#pragma mark Apply

- (void)applyWithCompletion:(void (^)(NSString *summary))completion {
    __weak MCSmartOptimizer *weakSelf = self;
    // Always the Trash; the core re-checks every path right before moving it.
    [self.scanModel cleanSelectedPermanently:NO
                               entryProgress:nil
                                  completion:^(MCCleanSummary *clean) {
                                      MCSmartOptimizer *strongSelf = weakSelf;
                                      if (strongSelf == nil) {
                                          return;
                                      }
                                      NSUInteger problems = clean.problems.count;
                                      NSUInteger quit = 0;
                                      for (MCOptimizationCandidate *candidate in strongSelf.candidates) {
                                          if (!candidate.selected) {
                                              continue;
                                          }
                                          // SIGTERM only, re-validated by the model; a process that
                                          // already exited is the outcome the user asked for.
                                          if ([strongSelf.processModel killPid:candidate.pid force:NO error:nil] ||
                                              ![strongSelf.processModel processExists:candidate.pid]) {
                                              ++quit;
                                          } else {
                                              ++problems;
                                          }
                                      }
                                      completion([MCSmartOptimizer summaryWithBytes:clean.bytesFreed
                                                                               quit:quit
                                                                           problems:problems]);
                                  }];
}

+ (NSString *)summaryWithBytes:(unsigned long long)bytes quit:(NSUInteger)quit problems:(NSUInteger)problems {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (bytes > 0) {
        [parts addObject:[NSString stringWithFormat:@"%@ moved to the Trash", humanSize(bytes)]];
    }
    if (quit > 0) {
        [parts addObject:[NSString stringWithFormat:@"%lu %@ quit", (unsigned long)quit,
                                                    quit == 1 ? @"process" : @"processes"]];
    }
    NSString *summary = parts.count == 0 ? @"Nothing changed" : [parts componentsJoinedByString:@", "];
    if (problems > 0) {
        summary = [summary stringByAppendingFormat:@" — %lu %@", (unsigned long)problems,
                                                   problems == 1 ? @"problem" : @"problems"];
    }
    return summary;
}

@end
