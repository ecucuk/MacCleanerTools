#import "MCBigFilesModel.h"

#include "maccleaner/bigfiles.hpp"
#include "maccleaner/safety.hpp"
#include "maccleaner/trash.hpp"

#include <atomic>
#include <string>

using namespace maccleaner;

namespace {

NSString *toNSString(const std::string &value) {
    NSString *result = [NSString stringWithUTF8String:value.c_str()];
    return result != nil ? result : @"(unprintable path)";
}

} // namespace

@interface MCBigFileItem ()
- (instancetype)initWithBigFile:(const BigFile &)file;
@end

@implementation MCBigFileItem

- (instancetype)initWithBigFile:(const BigFile &)file {
    if ((self = [super init])) {
        _name = [toNSString(file.path.filename().string()) copy];
        _path = [toNSString(file.path.string()) copy];
        _sizeBytes = file.sizeBytes;
    }
    return self;
}

@end

@interface MCBigFilesModel () {
    // Owned by the work queue while a scan runs; the cancel flag is the one
    // piece both threads touch, which is exactly what atomics are for.
    std::atomic<bool> _cancelled;
}
@property(nonatomic, strong) dispatch_queue_t workQueue;
@property(nonatomic) BOOL scanning;
@end

@implementation MCBigFilesModel

- (instancetype)init {
    if ((self = [super init])) {
        _workQueue = dispatch_queue_create("com.maccleaner.bigfiles", DISPATCH_QUEUE_SERIAL);
        _cancelled.store(false);
    }
    return self;
}

- (void)scanUnder:(NSString *)root
      minSizeBytes:(unsigned long long)minSizeBytes
        maxResults:(NSUInteger)maxResults
          progress:(nullable void (^)(uint64_t, NSString *))progress
        completion:(void (^)(NSArray<MCBigFileItem *> *))completion {
    if (self.scanning) {
        return;
    }
    self.scanning = YES;
    _cancelled.store(false, std::memory_order_relaxed);

    std::string rootPath = root.UTF8String;

    dispatch_async(self.workQueue, ^{
        BigFileScanOptions options;
        options.root = std::filesystem::path(rootPath);
        options.minSizeBytes = minSizeBytes;
        options.maxResults = maxResults;

        // Throttle progress on the work thread: findBigFiles reports roughly
        // once per directory, which over a whole home is tens of thousands of
        // callbacks -- far more than the main queue should be asked to absorb.
        // The throttle clock lives inside the (mutable) lambda: findBigFiles
        // invokes the one std::function copy for the whole scan, so the state
        // persists exactly as long as it needs to.
        BigFileProgress progressThunk;
        if (progress != nil) {
            progressThunk = [progress, lastReport = CFAbsoluteTime(0)](
                                std::uint64_t visited, const std::filesystem::path &dir) mutable {
                const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                if (now - lastReport < 0.25) {
                    return;
                }
                lastReport = now;
                NSString *dirString = toNSString(dir.string());
                dispatch_async(dispatch_get_main_queue(), ^{
                    progress(visited, dirString);
                });
            };
        }

        const std::vector<BigFile> found = findBigFiles(options, &self->_cancelled, progressThunk);

        NSMutableArray<MCBigFileItem *> *items = [NSMutableArray arrayWithCapacity:found.size()];
        for (const BigFile &file : found) {
            [items addObject:[[MCBigFileItem alloc] initWithBigFile:file]];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.scanning = NO;
            completion(items);
        });
    });
}

- (void)cancelScan {
    _cancelled.store(true, std::memory_order_relaxed);
}

- (BOOL)trashItemAtPath:(NSString *)path
          underScanRoot:(NSString *)scanRoot
                   error:(NSString **)error {
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

@end
