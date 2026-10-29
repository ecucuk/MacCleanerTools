// Objective-C face of the photo analysis (maccleaner/photos.hpp), in the
// mould of MCBigFilesModel: all C++ core access on one private serial queue,
// every callback delivered on the main queue, header free of C++ types.
//
// Two sources feed the same core: a folder (ImageIO, removal through the
// safety layer and the Trash) and the Photos library (PhotoKit, removal
// through Photos itself, which asks the user and keeps the photos in Recently
// Deleted for 30 days).

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCPhotoItem : NSObject
/// File path (folder source) or PHAsset localIdentifier (library source).
@property(nonatomic, copy, readonly) NSString *identifier;
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, readonly) BOOL isLibraryAsset;
@property(nonatomic, readonly) NSInteger pixelWidth;
@property(nonatomic, readonly) NSInteger pixelHeight;
@property(nonatomic, readonly) double sharpness;
/// 0 for library assets (unknown without fetching the original).
@property(nonatomic, readonly) unsigned long long sizeBytes;
@property(nonatomic, readonly, nullable) NSDate *created;
@end

@interface MCPhotoModel : NSObject

/// How removeFiles: gets rid of a photo file.
typedef NS_ENUM(NSInteger, MCPhotoRemoval) {
    MCPhotoRemovalTrash,
    /// Moves it into a backup folder, keeping its path relative to the scan
    /// root. JPEG, PNG and TIFF are stored as HEIC when that is smaller.
    MCPhotoRemovalBackup,
    /// Unlinks it. Cannot be undone.
    MCPhotoRemovalPermanent,
};

/// YES between a scan or removal call and its completion. Main-thread only.
@property(nonatomic, readonly) BOOL busy;

/// Analyses every photo under `root` off the main thread. `progress` is
/// throttled (~4 Hz) and runs on main; `completion` runs on main with every
/// analysed photo and the number of photo files that could not be decoded.
/// Starting a scan while `busy` is a no-op.
- (void)scanFolder:(NSString *)root
          progress:(nullable void (^)(uint64_t done, NSString *current))progress
        completion:(void (^)(NSArray<MCPhotoItem *> *items, NSUInteger skipped))completion;

/// The last saved result of a folder scan of `root`, or nil. Every folder
/// scan saves one (unless cancelled) and reuses it, so a rescan decodes only
/// new or changed files. `completion` runs on main.
- (void)loadCachedFolder:(NSString *)root completion:(void (^)(NSArray<MCPhotoItem *> *_Nullable items))completion;

/// Asks for Photos access, then analyses every image asset that is stored on
/// this Mac. Assets only in iCloud are not downloaded; they count as skipped.
/// On denied access `items` is nil and `error` says how to grant it.
- (void)scanLibraryWithProgress:(nullable void (^)(uint64_t done, NSString *current))progress
                     completion:(void (^)(NSArray<MCPhotoItem *> *_Nullable items, NSUInteger skipped,
                                          NSString *_Nullable error))completion;

/// Asks a running scan or removal to stop; its completion still fires with
/// what was done so far. No-op when idle.
- (void)cancelScan;

/// Duplicate groups of `items` at `maxDistance` (Hamming, 0-64). Element 0 of
/// each group is the photo to keep. Synchronous and cheap enough to call when
/// the user moves the threshold.
- (NSArray<NSArray<MCPhotoItem *> *> *)groupsOfItems:(NSArray<MCPhotoItem *> *)items
                                         maxDistance:(NSInteger)maxDistance;

/// Removes folder photos off the main thread, each after the same checks as
/// Large Files with the scanned folder as the only allowed root (plus the
/// Photos library guard). `backupFolder` is required for MCPhotoRemovalBackup
/// and must lie outside `scanRoot`; an existing file there is never replaced.
/// `progress` (~4 Hz) and `completion` run on main; `problems` holds one
/// "name — reason" line per photo left in place; `storedBytes` is what the
/// backup folder gained. No-op while `busy`.
- (void)removeFiles:(NSArray<NSString *> *)paths
      underScanRoot:(NSString *)scanRoot
                how:(MCPhotoRemoval)how
       backupFolder:(nullable NSString *)backupFolder
           progress:(nullable void (^)(uint64_t done, NSString *current))progress
         completion:(void (^)(NSSet<NSString *> *removed, NSArray<NSString *> *problems,
                              uint64_t storedBytes))completion;

/// Deletes library assets through Photos, which shows its own confirmation.
/// `completion` runs on main.
- (void)deleteLibraryAssets:(NSArray<NSString *> *)localIdentifiers
                 completion:(void (^)(BOOL ok, NSString *_Nullable error))completion;

/// Colour image of at most `maxPixels` on the long edge, for thumbnails and
/// the preview. `completion` runs on main. For a folder photo it runs once,
/// with nil if the file cannot be decoded. For a library photo it may run
/// twice (a quick version, then a better one) and does not run at all when
/// nothing is stored on this Mac.
- (void)imageForItem:(MCPhotoItem *)item
           maxPixels:(CGFloat)maxPixels
          completion:(void (^)(NSImage *_Nullable image))completion;

@end

NS_ASSUME_NONNULL_END
