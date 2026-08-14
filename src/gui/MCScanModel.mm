#import "MCScanModel.h"

#include "maccleaner/cleaner.hpp"
#include "maccleaner/format.hpp"
#include "maccleaner/safety.hpp"
#include "maccleaner/scanner.hpp"
#include "maccleaner/trash.hpp"

#include <string>
#include <vector>

using namespace maccleaner;

namespace {

NSString *toNSString(const std::string &value) {
    NSString *result = [NSString stringWithUTF8String:value.c_str()];
    // A path that isn't valid UTF-8 must not silently become nil and blow up
    // an NSArray insert later; fall back to a lossy but non-nil rendering.
    return result != nil ? result : @"(unprintable path)";
}

} // namespace

#pragma mark - MCEntryNode

@implementation MCEntryNode

- (instancetype)initWithFileEntry:(const FileEntry &)entry {
    if ((self = [super init])) {
        _name = [toNSString(entry.path.filename().string()) copy];
        _path = [toNSString(entry.path.string()) copy];
        _sizeBytes = entry.sizeBytes;
        _isDirectory = entry.isDirectory;
        _selected = NO;
    }
    return self;
}

@end

#pragma mark - MCCategoryNode

@implementation MCCategoryNode

- (instancetype)initWithScanResult:(const ScanResult &)result {
    if ((self = [super init])) {
        _label = [toNSString(result.label) copy];
        _path = [toNSString(result.root.string()) copy];
        _sizeBytes = result.totalSizeBytes;
        _rootExisted = result.rootExisted;
        _rawCategory = static_cast<NSInteger>(result.category);
        _forcesPermanentDelete = requiresPermanentDelete(result.category);

        NSMutableArray<MCEntryNode *> *entries = [NSMutableArray arrayWithCapacity:result.entries.size()];
        for (const FileEntry &entry : result.entries) {
            [entries addObject:[[MCEntryNode alloc] initWithFileEntry:entry]];
        }
        _entries = [entries copy];
    }
    return self;
}

- (MCSelectionState)selectionState {
    NSUInteger selected = 0;
    for (MCEntryNode *entry in self.entries) {
        if (entry.selected) {
            ++selected;
        }
    }
    if (selected == 0) {
        return MCSelectionStateNone;
    }
    return selected == self.entries.count ? MCSelectionStateAll : MCSelectionStatePartial;
}

- (void)setAllEntriesSelected:(BOOL)selected {
    for (MCEntryNode *entry in self.entries) {
        entry.selected = selected;
    }
}

@end

#pragma mark - MCCleanSummary

@interface MCCleanSummary ()
@property(nonatomic) unsigned long long bytesFreed;
@property(nonatomic) NSUInteger succeededCount;
@property(nonatomic) NSUInteger skippedCount;
@property(nonatomic) NSUInteger failedCount;
@property(nonatomic, copy) NSArray<NSString *> *problems;
@end

@implementation MCCleanSummary
@end

#pragma mark - MCScanModel

@interface MCScanModel () {
    // Owned exclusively by _workQueue. The UI never touches these; it works
    // against the MCCategoryNode snapshot on the main thread instead.
    std::vector<ScanTarget> _targets;
    safety::AllowedRoots _allowed;
}
@property(nonatomic, strong) dispatch_queue_t workQueue;
@property(nonatomic, copy) NSArray<MCCategoryNode *> *categories;
@end

@implementation MCScanModel

- (instancetype)init {
    if ((self = [super init])) {
        _categories = @[];
        _workQueue = dispatch_queue_create("com.maccleaner.core", DISPATCH_QUEUE_SERIAL);

        // Same construction the CLI uses, including the nested-root exclusions
        // that keep e.g. the Homebrew cache out of the general caches category.
        _targets = defaultTargets(homeDirectory());
        registerAllowedRoots(_targets, _allowed);
    }
    return self;
}

- (BOOL)trashIsRecoverable {
    return trash::isNativeImplementation();
}

#pragma mark Scanning

- (void)scanWithWillScanCategory:(nullable void (^)(NSString *, NSString *))willScan
                  didScanCategory:(nullable void (^)(MCCategoryNode *_Nullable))didScan
                       completion:(void (^)(void))completion {
    dispatch_async(self.workQueue, ^{
        NSMutableArray<MCCategoryNode *> *nodes = [NSMutableArray arrayWithCapacity:self->_targets.size()];

        for (const ScanTarget &target : self->_targets) {
            if (willScan != nil) {
                NSString *label = toNSString(target.label);
                NSString *path = toNSString(target.root.string());
                dispatch_async(dispatch_get_main_queue(), ^{
                    willScan(label, path);
                });
            }

            const ScanResult result = scanTarget(target);

            // Categories whose root doesn't exist on this machine (no Xcode, no
            // npm) would just be empty noise in the list.
            MCCategoryNode *node = nil;
            if (result.rootExisted && !result.entries.empty()) {
                node = [[MCCategoryNode alloc] initWithScanResult:result];
                [nodes addObject:node];
            }
            if (didScan != nil) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    didScan(node);
                });
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.categories = nodes;
            completion();
        });
    });
}

#pragma mark Selection

- (unsigned long long)selectedBytes {
    unsigned long long total = 0;
    for (MCCategoryNode *category in self.categories) {
        for (MCEntryNode *entry in category.entries) {
            if (entry.selected) {
                total += entry.sizeBytes;
            }
        }
    }
    return total;
}

- (NSUInteger)selectedCount {
    NSUInteger count = 0;
    for (MCCategoryNode *category in self.categories) {
        for (MCEntryNode *entry in category.entries) {
            if (entry.selected) {
                ++count;
            }
        }
    }
    return count;
}

- (BOOL)selectionIncludesForcedPermanent {
    for (MCCategoryNode *category in self.categories) {
        if (!category.forcesPermanentDelete) {
            continue;
        }
        for (MCEntryNode *entry in category.entries) {
            if (entry.selected) {
                return YES;
            }
        }
    }
    return NO;
}

#pragma mark Cleaning

- (void)cleanSelectedPermanently:(BOOL)permanent
                    entryProgress:(nullable void (^)(NSString *, BOOL, BOOL, NSString *,
                                                      unsigned long long, NSUInteger, NSUInteger))progress
                       completion:(void (^)(MCCleanSummary *))completion {
    // Snapshot the selection on the main thread into plain values, so the work
    // queue never reads the ObjC node tree the UI is still mutating.
    struct PendingCategory {
        Category category;
        std::string label;
        std::filesystem::path root;
        std::vector<FileEntry> entries;
    };
    auto pending = std::make_shared<std::vector<PendingCategory>>();

    NSArray<MCCategoryNode *> *categories = self.categories;
    for (NSUInteger index = 0; index < categories.count; ++index) {
        MCCategoryNode *node = categories[index];

        PendingCategory group;
        group.label = node.label.UTF8String;
        group.root = std::filesystem::path(node.path.UTF8String);
        group.category = static_cast<Category>(node.rawCategory);

        for (MCEntryNode *entry in node.entries) {
            if (!entry.selected) {
                continue;
            }
            FileEntry fileEntry;
            fileEntry.path = std::filesystem::path(entry.path.UTF8String);
            fileEntry.sizeBytes = entry.sizeBytes;
            fileEntry.isDirectory = entry.isDirectory;
            group.entries.push_back(std::move(fileEntry));
        }

        if (!group.entries.empty()) {
            pending->push_back(std::move(group));
        }
    }

    if (pending->empty()) {
        completion([[MCCleanSummary alloc] init]);
        return;
    }

    NSUInteger itemsTotal = 0;
    for (const PendingCategory &group : *pending) {
        itemsTotal += group.entries.size();
    }

    dispatch_async(self.workQueue, ^{
        CleanOptions options;
        options.dryRun = false; // the confirmation sheet is the GUI's dry run
        options.mode = permanent ? DeleteMode::Permanent : DeleteMode::Trash;

        MCCleanSummary *summary = [[MCCleanSummary alloc] init];
        NSMutableArray<NSString *> *problems = [NSMutableArray array];
        unsigned long long bytesFreed = 0;
        NSUInteger succeeded = 0;
        NSUInteger skipped = 0;
        NSUInteger failed = 0;
        NSUInteger itemsDone = 0;

        for (const PendingCategory &group : *pending) {
            // One clean() call per entry rather than per category, so progress
            // can be reported between items. Behaviour is identical: clean()
            // treats each entry independently anyway (per-entry safety
            // re-validation, per-category mode forcing via result.category).
            for (const FileEntry &fileEntry : group.entries) {
                ScanResult result;
                result.category = group.category;
                result.label = group.label;
                result.root = group.root;
                result.entries = {fileEntry};
                result.rootExisted = true;

                // Same clean() the CLI calls: every path is re-validated
                // against the allowlist immediately before deletion.
                const CleanReport report = clean(result, self->_allowed, options);
                ++itemsDone;
                bytesFreed += report.bytesFreed;

                for (const CleanOutcome &outcome : report.outcomes) {
                    BOOL outcomeSkipped = NO;
                    BOOL outcomeSucceeded = NO;
                    if (outcome.skipped) {
                        ++skipped;
                        outcomeSkipped = YES;
                        [problems addObject:[NSString stringWithFormat:@"SKIP  %@  (%@)",
                                                                         toNSString(outcome.path.string()),
                                                                         toNSString(outcome.message)]];
                    } else if (!outcome.succeeded) {
                        ++failed;
                        [problems addObject:[NSString stringWithFormat:@"FAIL  %@  (%@)",
                                                                         toNSString(outcome.path.string()),
                                                                         toNSString(outcome.message)]];
                    } else {
                        ++succeeded;
                        outcomeSucceeded = YES;
                    }

                    if (progress != nil) {
                        NSString *path = toNSString(outcome.path.string());
                        NSString *message = toNSString(outcome.message);
                        const unsigned long long freedSoFar = bytesFreed;
                        const NSUInteger done = itemsDone;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            progress(path, outcomeSucceeded, outcomeSkipped, message, freedSoFar, done, itemsTotal);
                        });
                    }
                }
            }
        }

        summary.bytesFreed = bytesFreed;
        summary.succeededCount = succeeded;
        summary.skippedCount = skipped;
        summary.failedCount = failed;
        summary.problems = problems;

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(summary);
        });
    });
}

@end
