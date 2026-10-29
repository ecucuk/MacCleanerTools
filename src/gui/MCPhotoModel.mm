#import "MCPhotoModel.h"

#import <ImageIO/ImageIO.h>
#import <Photos/Photos.h>

#include "../platform/image_mac.h"
#include "maccleaner/photos.hpp"
#include "maccleaner/safety.hpp"
#include "maccleaner/trash.hpp"

#include <atomic>
#include <cstdio>
#include <functional>
#include <memory>
#include <string>
#include <vector>

using namespace maccleaner;

namespace {

NSString *toNSString(const std::string &value) {
    NSString *result = [NSString stringWithUTF8String:value.c_str()];
    return result != nil ? result : @"(unprintable path)";
}

} // namespace

@interface MCPhotoItem ()
- (instancetype)initWithInfo:(const photos::PhotoInfo &)info name:(NSString *)name libraryAsset:(BOOL)libraryAsset;
@property(nonatomic) uint64_t hash64;
@end

@implementation MCPhotoItem

- (instancetype)initWithInfo:(const photos::PhotoInfo &)info name:(NSString *)name libraryAsset:(BOOL)libraryAsset {
    if ((self = [super init])) {
        _identifier = [toNSString(info.id) copy];
        _name = [name copy];
        _isLibraryAsset = libraryAsset;
        _pixelWidth = info.pixelWidth;
        _pixelHeight = info.pixelHeight;
        _sharpness = info.sharpness;
        _sizeBytes = info.sizeBytes;
        _created = info.createdUnix != 0 ? [NSDate dateWithTimeIntervalSince1970:static_cast<NSTimeInterval>(info.createdUnix)] : nil;
        _hash64 = info.hash;
    }
    return self;
}

- (photos::PhotoInfo)info {
    photos::PhotoInfo info;
    info.id = self.identifier.UTF8String;
    info.hash = self.hash64;
    info.sharpness = self.sharpness;
    info.pixelWidth = static_cast<int>(self.pixelWidth);
    info.pixelHeight = static_cast<int>(self.pixelHeight);
    info.createdUnix = self.created != nil ? static_cast<std::int64_t>(self.created.timeIntervalSince1970) : 0;
    info.sizeBytes = self.sizeBytes;
    return info;
}

@end

namespace {

NSArray<MCPhotoItem *> *itemsFromFolderPhotos(const std::vector<photos::PhotoInfo> &photos) {
    NSMutableArray<MCPhotoItem *> *items = [NSMutableArray arrayWithCapacity:photos.size()];
    for (const photos::PhotoInfo &info : photos) {
        NSString *name = toNSString(std::filesystem::path(info.id).filename().string());
        [items addObject:[[MCPhotoItem alloc] initWithInfo:info name:name libraryAsset:NO]];
    }
    return items;
}

// ~/Library/Caches/<bundle id>/photo-scans/<hash of root>.bin; empty if the
// directory cannot be made (the scan then simply runs uncached). The root is
// stored inside the file too, so a hash collision only costs a full rescan.
std::filesystem::path cacheFileForRoot(const std::string &root) {
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier != nil ? NSBundle.mainBundle.bundleIdentifier : @"MacCleaner";
    NSURL *dir = [[caches URLByAppendingPathComponent:bundle] URLByAppendingPathComponent:@"photo-scans"];
    if (dir == nil || ![NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES
                                                               attributes:nil error:nil]) {
        return {};
    }
    char name[32];
    std::snprintf(name, sizeof name, "%016zx.bin", std::hash<std::string>{}(root));
    return std::filesystem::path(dir.fileSystemRepresentation) / name;
}

} // namespace

@interface MCPhotoModel () {
    // Owned by the work queue while a scan runs; the cancel flag is the one
    // piece both threads touch, which is exactly what atomics are for.
    std::atomic<bool> _cancelled;
}
@property(nonatomic, strong) dispatch_queue_t workQueue;
@property(nonatomic) BOOL scanning;
@end

@implementation MCPhotoModel

- (instancetype)init {
    if ((self = [super init])) {
        _workQueue = dispatch_queue_create("com.maccleaner.photos", DISPATCH_QUEUE_SERIAL);
        _cancelled.store(false);
    }
    return self;
}

// Throttles work-thread progress to ~4 Hz before it touches the main queue.
// Safe to call from several threads at once (the library scan does).
static void (^throttled(void (^progress)(uint64_t, NSString *)))(uint64_t, NSString *) {
    if (progress == nil) {
        return nil;
    }
    auto lastReport = std::make_shared<std::atomic<CFAbsoluteTime>>(0);
    return ^(uint64_t done, NSString *current) {
        const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        CFAbsoluteTime last = lastReport->load(std::memory_order_relaxed);
        if (now - last < 0.25 || !lastReport->compare_exchange_strong(last, now, std::memory_order_relaxed)) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            progress(done, current);
        });
    };
}

- (void)scanFolder:(NSString *)root
          progress:(nullable void (^)(uint64_t, NSString *))progress
        completion:(void (^)(NSArray<MCPhotoItem *> *, NSUInteger))completion {
    if (self.scanning) {
        return;
    }
    self.scanning = YES;
    _cancelled.store(false, std::memory_order_relaxed);

    std::string rootPath = root.UTF8String;
    void (^report)(uint64_t, NSString *) = throttled(progress);

    dispatch_async(self.workQueue, ^{
        photos::PhotoProgress progressThunk;
        if (report != nil) {
            progressThunk = [report](std::uint64_t done, const std::filesystem::path &current) {
                report(done, toNSString(current.string()));
            };
        }
        const std::filesystem::path cache = cacheFileForRoot(rootPath);
        std::vector<photos::PhotoInfo> previous;
        photos::loadPhotoCache(cache, rootPath, previous);
        const photos::FolderScan scan = photos::scanPhotoFolder(std::filesystem::path(rootPath), &self->_cancelled,
                                                                progressThunk, photos::decodeImageFile, previous);
        // A cancelled scan, or one of a folder that is gone (an unplugged
        // drive), misses files the cache still knows; keep the old cache.
        std::error_code ec;
        if (!self->_cancelled.load(std::memory_order_relaxed) && !cache.empty() &&
            std::filesystem::is_directory(rootPath, ec)) {
            photos::savePhotoCache(cache, rootPath, scan.photos);
        }

        NSArray<MCPhotoItem *> *items = itemsFromFolderPhotos(scan.photos);
        const NSUInteger skipped = static_cast<NSUInteger>(scan.undecodable);

        dispatch_async(dispatch_get_main_queue(), ^{
            self.scanning = NO;
            completion(items, skipped);
        });
    });
}

- (void)loadCachedFolder:(NSString *)root completion:(void (^)(NSArray<MCPhotoItem *> *_Nullable))completion {
    std::string rootPath = root.UTF8String;
    dispatch_async(self.workQueue, ^{
        std::vector<photos::PhotoInfo> cached;
        const std::filesystem::path cache = cacheFileForRoot(rootPath);
        NSArray<MCPhotoItem *> *items =
            !cache.empty() && photos::loadPhotoCache(cache, rootPath, cached) ? itemsFromFolderPhotos(cached) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(items);
        });
    });
}

- (void)scanLibraryWithProgress:(nullable void (^)(uint64_t, NSString *))progress
                     completion:(void (^)(NSArray<MCPhotoItem *> *_Nullable, NSUInteger, NSString *_Nullable))completion {
    if (self.scanning) {
        return;
    }
    self.scanning = YES;
    _cancelled.store(false, std::memory_order_relaxed);
    void (^report)(uint64_t, NSString *) = throttled(progress);

    void (^finish)(NSArray<MCPhotoItem *> *, NSUInteger, NSString *) =
        ^(NSArray<MCPhotoItem *> *items, NSUInteger skipped, NSString *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.scanning = NO;
                completion(items, skipped, error);
            });
        };

    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite
                                               handler:^(PHAuthorizationStatus status) {
        if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
            finish(nil, 0, @"Photos access denied. Allow it in System Settings › Privacy & Security › Photos.");
            return;
        }
        dispatch_async(self.workQueue, ^{
            PHFetchResult<PHAsset *> *assets = [PHAsset fetchAssetsWithMediaType:PHAssetMediaTypeImage options:nil];

            PHImageRequestOptions *options = [[PHImageRequestOptions alloc] init];
            options.synchronous = YES;
            options.deliveryMode = PHImageRequestOptionsDeliveryModeHighQualityFormat;
            options.resizeMode = PHImageRequestOptionsResizeModeExact;
            options.networkAccessAllowed = NO; // never download from iCloud
            const CGSize target = CGSizeMake(photos::kDecodeMaxPixels, photos::kDecodeMaxPixels);

            // Decoding dominates, so assets are analysed in parallel. The
            // fetch result loads lazily and is not documented as
            // thread-safe, so its assets are read up front.
            NSArray<PHAsset *> *all = [assets objectsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, assets.count)]];
            std::vector<MCPhotoItem *> slots(all.count); // asset order, whatever the thread timing
            std::atomic<NSUInteger> skipped{0};
            std::atomic<NSUInteger> done{0};
            // Blocks capture C++ objects as const copies; these point at the
            // locals instead, which outlive the synchronous dispatch_apply.
            MCPhotoItem *__strong *slot = slots.data();
            std::atomic<NSUInteger> *skippedCount = &skipped;
            std::atomic<NSUInteger> *doneCount = &done;
            dispatch_apply(all.count, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
                if (self->_cancelled.load(std::memory_order_relaxed)) {
                    return;
                }
                @autoreleasepool {
                    PHAsset *asset = all[i];
                    __block photos::GrayImage gray;
                    __block BOOL decoded = NO;
                    [[PHImageManager defaultManager] requestImageForAsset:asset
                                                               targetSize:target
                                                              contentMode:PHImageContentModeAspectFit
                                                                  options:options
                                                            resultHandler:^(NSImage *image, NSDictionary *) {
                        CGImageRef cgImage = [image CGImageForProposedRect:nullptr context:nil hints:nil];
                        decoded = cgImage != nullptr && photos::grayFromCGImage(cgImage, gray);
                    }];
                    if (!decoded) {
                        skippedCount->fetch_add(1, std::memory_order_relaxed);
                        return;
                    }

                    photos::PhotoInfo info;
                    info.id = asset.localIdentifier.UTF8String;
                    info.hash = photos::dHash(gray);
                    info.sharpness = photos::sharpness(gray);
                    info.pixelWidth = static_cast<int>(asset.pixelWidth);
                    info.pixelHeight = static_cast<int>(asset.pixelHeight);
                    info.createdUnix = asset.creationDate != nil
                                           ? static_cast<std::int64_t>(asset.creationDate.timeIntervalSince1970)
                                           : 0;
                    PHAssetResource *resource = [PHAssetResource assetResourcesForAsset:asset].firstObject;
                    NSString *name = nil;
                    if (@available(macOS 27, *)) {
                        name = resource.filename;
                    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                        name = resource.originalFilename;
#pragma clang diagnostic pop
                    }
                    if (name == nil) {
                        name = asset.localIdentifier;
                    }
                    slot[i] = [[MCPhotoItem alloc] initWithInfo:info name:name libraryAsset:YES];
                    if (report != nil) {
                        report(doneCount->fetch_add(1, std::memory_order_relaxed) + 1, name);
                    }
                }
            });

            NSMutableArray<MCPhotoItem *> *items = [NSMutableArray arrayWithCapacity:all.count];
            for (MCPhotoItem *item : slots) {
                if (item != nil) {
                    [items addObject:item];
                }
            }
            finish(items, skipped.load(), nil);
        });
    }];
}

- (void)cancelScan {
    _cancelled.store(true, std::memory_order_relaxed);
}

- (NSArray<NSArray<MCPhotoItem *> *> *)groupsOfItems:(NSArray<MCPhotoItem *> *)items
                                         maxDistance:(NSInteger)maxDistance {
    std::vector<photos::PhotoInfo> infos;
    infos.reserve(items.count);
    for (MCPhotoItem *item in items) {
        infos.push_back([item info]);
    }
    NSMutableArray<NSArray<MCPhotoItem *> *> *groups = [NSMutableArray array];
    for (const auto &group : photos::groupDuplicates(infos, static_cast<int>(maxDistance))) {
        NSMutableArray<MCPhotoItem *> *members = [NSMutableArray arrayWithCapacity:group.size()];
        for (std::size_t index : group) {
            [members addObject:items[index]];
        }
        [groups addObject:members];
    }
    return groups;
}

- (BOOL)trashFileAtPath:(NSString *)path underScanRoot:(NSString *)scanRoot error:(NSString **)error {
    safety::AllowedRoots allowed;
    allowed.add(std::filesystem::path(scanRoot.UTF8String));

    std::string reason;
    if (!safety::isSafeToDelete(std::filesystem::path(path.UTF8String), allowed, &reason)) {
        if (error != nullptr) {
            *error = toNSString(reason);
        }
        return NO;
    }

    std::string trashError;
    if (!trash::moveToTrash(std::filesystem::path(path.UTF8String), trashError)) {
        if (error != nullptr) {
            *error = toNSString(trashError);
        }
        return NO;
    }
    return YES;
}

- (void)deleteLibraryAssets:(NSArray<NSString *> *)localIdentifiers
                 completion:(void (^)(BOOL, NSString *_Nullable))completion {
    [[PHPhotoLibrary sharedPhotoLibrary]
        performChanges:^{
            PHFetchResult<PHAsset *> *assets = [PHAsset fetchAssetsWithLocalIdentifiers:localIdentifiers options:nil];
            [PHAssetChangeRequest deleteAssets:assets];
        }
        completionHandler:^(BOOL success, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(success, success ? nil : error.localizedDescription);
            });
        }];
}

- (void)imageForItem:(MCPhotoItem *)item
           maxPixels:(CGFloat)maxPixels
          completion:(void (^)(NSImage *_Nullable))completion {
    if (item.isLibraryAsset) {
        PHAsset *asset = [PHAsset fetchAssetsWithLocalIdentifiers:@[ item.identifier ] options:nil].firstObject;
        if (asset == nil) {
            completion(nil);
            return;
        }
        // Opportunistic: HighQualityFormat yields nil when the full-size
        // original is only in iCloud, which left the preview blank. This
        // delivers the best local version (possibly twice, better second).
        PHImageRequestOptions *options = [[PHImageRequestOptions alloc] init];
        options.deliveryMode = PHImageRequestOptionsDeliveryModeOpportunistic;
        options.networkAccessAllowed = NO;
        [[PHImageManager defaultManager] requestImageForAsset:asset
                                                   targetSize:CGSizeMake(maxPixels, maxPixels)
                                                  contentMode:PHImageContentModeAspectFit
                                                      options:options
                                                resultHandler:^(NSImage *image, NSDictionary *) {
            if (image == nil) {
                return; // keep whatever an earlier delivery showed
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(image);
            });
        }];
        return;
    }

    NSString *path = item.identifier;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSImage *image = nil;
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], nullptr);
        if (source != nullptr) {
            NSDictionary *options = @{
                (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
                (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform : @YES,
                (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize : @(maxPixels),
            };
            CGImageRef cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
            CFRelease(source);
            if (cgImage != nullptr) {
                image = [[NSImage alloc] initWithCGImage:cgImage size:NSZeroSize];
                CGImageRelease(cgImage);
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(image);
        });
    });
}

@end
