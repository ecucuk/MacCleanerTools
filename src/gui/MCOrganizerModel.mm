#import "MCOrganizerModel.h"

#include "maccleaner/organizer.hpp"

#include <atomic>
#include <map>
#include <string>
#include <vector>

using namespace maccleaner;
namespace fs = std::filesystem;

namespace {

NSString *toNSString(const std::string &value) {
    NSString *result = [NSString stringWithUTF8String:value.c_str()];
    return result != nil ? result : @"(unprintable)";
}

// Folder tree of the plan, one node per path component under the destination.
struct Node {
    std::size_t count = 0;
    std::map<std::string, Node> children;
};

} // namespace

@interface MCOrganizerGroup ()
- (instancetype)initWithTitle:(NSString *)title count:(NSUInteger)count children:(NSArray<MCOrganizerGroup *> *)children;
@end

@implementation MCOrganizerGroup
- (instancetype)initWithTitle:(NSString *)title count:(NSUInteger)count children:(NSArray<MCOrganizerGroup *> *)children {
    if ((self = [super init])) {
        _title = [title copy];
        _count = count;
        _children = [children copy];
    }
    return self;
}
@end

@interface MCOrganizerPin ()
- (instancetype)initWithLatitude:(double)latitude longitude:(double)longitude count:(NSUInteger)count
                       placeName:(NSString *)placeName;
@end

@implementation MCOrganizerPin
- (instancetype)initWithLatitude:(double)latitude longitude:(double)longitude count:(NSUInteger)count
                       placeName:(NSString *)placeName {
    if ((self = [super init])) {
        _latitude = latitude;
        _longitude = longitude;
        _count = count;
        _placeName = [placeName copy];
    }
    return self;
}
@end

namespace {

NSArray<MCOrganizerGroup *> *groupsFromNode(const Node &node) {
    NSMutableArray<MCOrganizerGroup *> *groups = [NSMutableArray array];
    for (const auto &[name, child] : node.children) {
        [groups addObject:[[MCOrganizerGroup alloc] initWithTitle:toNSString(name)
                                                            count:child.count
                                                         children:groupsFromNode(child)]];
    }
    return groups;
}

} // namespace

@interface MCOrganizerModel () {
    // The plan and its source belong to the work queue; the cancel flag is the
    // one piece both threads touch.
    std::vector<organizer::Move> _plan;
    fs::path _planSource;
    std::atomic<bool> _cancelled;
}
@property(nonatomic, strong) dispatch_queue_t workQueue;
@property(nonatomic) BOOL busy;
@end

@implementation MCOrganizerModel

- (instancetype)init {
    if ((self = [super init])) {
        _workQueue = dispatch_queue_create("com.maccleaner.organizer", DISPATCH_QUEUE_SERIAL);
        _cancelled.store(false);
    }
    return self;
}

// ~/Library/Caches/<bundle id>/geocode.tsv, shared by every preview.
+ (fs::path)geocodeCacheFile {
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier != nil ? NSBundle.mainBundle.bundleIdentifier : @"MacCleaner";
    return fs::path(caches.path.fileSystemRepresentation) / bundle.UTF8String / "geocode.tsv";
}

- (void)previewSource:(NSString *)source
          destination:(NSString *)destination
              byPlace:(BOOL)byPlace
             progress:(void (^)(NSString *))progress
           completion:(void (^)(NSArray<MCOrganizerGroup *> *, NSArray<MCOrganizerPin *> *, NSUInteger, NSUInteger,
                                NSString *_Nullable))completion {
    if (self.busy) {
        return;
    }
    self.busy = YES;
    _cancelled.store(false);
    const fs::path sourcePath(source.fileSystemRepresentation);
    const fs::path destPath(destination.fileSystemRepresentation);
    const fs::path cacheFile = [MCOrganizerModel geocodeCacheFile];

    dispatch_async(self.workQueue, ^{
        CFAbsoluteTime lastReport = 0;
        auto report = [&](NSString *status) {
            const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - lastReport >= 0.25) {
                lastReport = now;
                dispatch_async(dispatch_get_main_queue(), ^{ progress(status); });
            }
        };

        self->_plan.clear();
        std::string reason;
        if (!organizer::isValidDestination(destPath, &reason)) {
            NSString *message = toNSString(reason);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.busy = NO;
                completion(@[], @[], 0, 0, message);
            });
            return;
        }

        auto files = organizer::scanForOrganize(sourcePath, destPath, &self->_cancelled, [&](std::size_t seen) {
            report([NSString stringWithFormat:@"Reading files… %lu", (unsigned long)seen]);
        });
        const auto layout = byPlace ? organizer::PhotoLayout::Place : organizer::PhotoLayout::Content;
        if (byPlace && !self->_cancelled.load()) {
            organizer::resolvePlaces(files, cacheFile, &self->_cancelled, [&](std::size_t done, std::size_t total) {
                report([NSString stringWithFormat:@"Looking up places… %lu of %lu", (unsigned long)done,
                                                  (unsigned long)total]);
            });
        }
        if (!self->_cancelled.load()) {
            self->_plan = organizer::planOrganize(
                files, destPath, [](const fs::path &path) { std::error_code ec; return fs::exists(path, ec); }, layout);
            self->_planSource = sourcePath;
        }

        Node root;
        for (const organizer::Move &move : self->_plan) {
            Node *node = &root;
            for (const fs::path &part : move.to.parent_path().lexically_relative(destPath)) {
                node = &node->children[part.string()];
                ++node->count;
            }
        }
        std::map<organizer::GeoCell, std::pair<std::size_t, std::string>> cells;
        for (const organizer::FileMeta &file : files) {
            if (file.location) {
                auto &[count, name] = cells[organizer::cellOf(*file.location)];
                ++count;
                if (name.empty() && !file.province.empty()) {
                    name = file.city.empty() ? file.province : file.province + ", " + file.city;
                }
            }
        }
        NSMutableArray<MCOrganizerPin *> *pins = [NSMutableArray array];
        for (const auto &[cell, info] : cells) {
            const organizer::GeoPoint center = organizer::cellCenter(cell);
            [pins addObject:[[MCOrganizerPin alloc] initWithLatitude:center.latitude longitude:center.longitude
                                                               count:info.first placeName:toNSString(info.second)]];
        }
        NSArray<MCOrganizerGroup *> *groups = groupsFromNode(root);
        const NSUInteger moveCount = self->_plan.size();
        const NSUInteger fileCount = files.size();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            completion(groups, pins, moveCount, fileCount, nil);
        });
    });
}

- (void)organizeWithProgress:(void (^)(NSUInteger, NSUInteger))progress
                  completion:(void (^)(NSUInteger, NSArray<NSString *> *))completion {
    if (self.busy) {
        return;
    }
    self.busy = YES;
    _cancelled.store(false);
    dispatch_async(self.workQueue, ^{
        CFAbsoluteTime lastReport = 0;
        const organizer::ApplyResult result = organizer::applyPlan(
            self->_plan, self->_planSource, &self->_cancelled, [&](std::size_t done, std::size_t total) {
                const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                if (now - lastReport >= 0.25) {
                    lastReport = now;
                    dispatch_async(dispatch_get_main_queue(), ^{ progress(done, total); });
                }
            });
        // A plan is good for one run: whatever moved has a new path now.
        self->_plan.clear();
        NSMutableArray<NSString *> *problems = [NSMutableArray array];
        for (const std::string &problem : result.problems) {
            [problems addObject:toNSString(problem)];
        }
        const NSUInteger moved = result.moved;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            completion(moved, problems);
        });
    });
}

- (void)cancel {
    _cancelled.store(true);
}

@end
