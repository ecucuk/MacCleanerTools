// Objective-C face of the big-file finder (maccleaner/bigfiles.hpp), in the
// mould of MCScanModel: all C++ core access on one private serial queue,
// every callback delivered on the main queue, header free of C++ types.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCBigFileItem : NSObject
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, copy, readonly) NSString *path;
@property(nonatomic, readonly) unsigned long long sizeBytes;
@end

@interface MCBigFilesModel : NSObject

/// YES between -scanUnder:... and its completion. Main-thread only.
@property(nonatomic, readonly) BOOL scanning;

/// Walks `root` off the main thread and reports the largest files found.
/// `progress` is throttled (~4 Hz) and delivered on main with the number of
/// entries visited and the directory currently being walked; `resultsUpdate`
/// (same throttle) streams the evolving top list so the UI can fill as files
/// are found; `completion` runs on main with the authoritative final list,
/// sorted largest-first. Only one scan can be in flight; starting a second
/// one while `scanning` is a no-op.
- (void)scanUnder:(NSString *)root
      minSizeBytes:(unsigned long long)minSizeBytes
        maxResults:(NSUInteger)maxResults
          progress:(nullable void (^)(uint64_t visited, NSString *currentDir))progress
     resultsUpdate:(nullable void (^)(NSArray<MCBigFileItem *> *files))resultsUpdate
        completion:(void (^)(NSArray<MCBigFileItem *> *files))completion;

/// Asks a running scan to stop; its completion still fires (with whatever was
/// found so far). No-op when idle.
- (void)cancelScan;

/// Moves one found file to the Trash, re-validating against the same safety
/// layer the cleaner uses -- with the scan root as the single allowed root,
/// so only strict descendants of the directory the user chose to search can
/// ever be deleted (plus the usual symlink/ownership/system-path checks).
/// Synchronous (single-file trashing is fast); returns NO and fills `error`
/// on rejection or failure.
- (BOOL)trashItemAtPath:(NSString *)path
          underScanRoot:(NSString *)scanRoot
                   error:(NSString *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
