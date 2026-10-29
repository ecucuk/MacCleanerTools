// Objective-C face of the File Organizer (maccleaner/organizer.hpp), in the
// mould of MCBigFilesModel: all C++ core access on one private serial queue,
// every callback delivered on the main queue, header free of C++ types.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One folder of the planned layout ("Photos", "Nature", "2023", ...) with
/// the number of files that will land under it.
@interface MCOrganizerGroup : NSObject
@property(nonatomic, copy, readonly) NSString *title;
@property(nonatomic, readonly) NSUInteger count;
@property(nonatomic, copy, readonly) NSArray<MCOrganizerGroup *> *children;
@end

/// Photos with GPS in one ~5 km grid cell, for the map.
@interface MCOrganizerPin : NSObject
@property(nonatomic, readonly) double latitude;
@property(nonatomic, readonly) double longitude;
@property(nonatomic, readonly) NSUInteger count;
/// "İstanbul, Kartal" once places are looked up; empty otherwise.
@property(nonatomic, copy, readonly) NSString *placeName;
@end

@interface MCOrganizerModel : NSObject

/// YES while a preview or an organize runs. Main-thread only.
@property(nonatomic, readonly) BOOL busy;

/// Reads every file under `source`, plans where it goes under `destination`
/// and keeps that plan for -organize.... With `byPlace`, photo locations are
/// reverse geocoded (grid-cell centers go to Apple; results are cached).
/// `progress` (~4 Hz) gets a status line. `error` is set and the plan is
/// empty when the destination is refused. `waitingCount` photos (By Place)
/// stay put because their place lookup failed.
- (void)previewSource:(NSString *)source
          destination:(NSString *)destination
              byPlace:(BOOL)byPlace
             progress:(void (^)(NSString *status))progress
           completion:(void (^)(NSArray<MCOrganizerGroup *> *groups, NSArray<MCOrganizerPin *> *pins,
                                NSUInteger moveCount, NSUInteger fileCount, NSUInteger waitingCount,
                                NSString *_Nullable error))completion;

/// Runs the last preview's plan: each move goes through the safety layer
/// with the source as the only allowed root and never replaces a file.
- (void)organizeWithProgress:(void (^)(NSUInteger done, NSUInteger total))progress
                  completion:(void (^)(NSUInteger moved, NSArray<NSString *> *problems))completion;

/// Stops a running preview or organize between files; its completion still
/// fires. Files already moved stay moved.
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
