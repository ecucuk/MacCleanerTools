// Objective-C face of the C++ core (scanner / safety / cleaner).
//
// Two jobs beyond plain wrapping:
//
//   1. Threading. Scanning walks multi-gigabyte trees (DerivedData alone can
//      take seconds) and cleaning does real filesystem work, so neither may
//      run on the main thread. All C++ core access happens on one private
//      serial queue; every callback is delivered back on the main queue.
//   2. Selection. The CLI cleans whole categories; the GUI lets the user pick
//      individual entries, so the model carries per-entry selection state and
//      builds a filtered ScanResult from it at clean time. The safety layer is
//      unchanged and still re-validates every path immediately before deletion.
//
// The header stays free of C++ types so it can be imported from anywhere; the
// core state lives in a class extension in the .mm.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// How much of a category is selected. Deliberately not NSControlStateValue:
/// that would drag AppKit into the model layer purely to name three constants.
/// MCMainWindowController maps this onto the checkbox states.
typedef NS_ENUM(NSInteger, MCSelectionState) {
    MCSelectionStateNone,
    MCSelectionStatePartial,
    MCSelectionStateAll,
};

/// One deletable item inside a category (a direct child of the category root).
@interface MCEntryNode : NSObject
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, copy, readonly) NSString *path;
@property(nonatomic, readonly) unsigned long long sizeBytes;
@property(nonatomic, readonly) BOOL isDirectory;
@property(nonatomic) BOOL selected;
@end

/// One cleanup category and the entries found under its root.
@interface MCCategoryNode : NSObject
@property(nonatomic, copy, readonly) NSString *label;
@property(nonatomic, copy, readonly) NSString *path;
@property(nonatomic, readonly) unsigned long long sizeBytes;
@property(nonatomic, readonly) BOOL rootExisted;
/// The underlying maccleaner::Category, kept as an integer so this header
/// stays importable from plain Objective-C. Round-tripped back to the enum in
/// the .mm; the delete path switches on it, so it must stay faithful.
@property(nonatomic, readonly) NSInteger rawCategory;
/// YES for categories that are always deleted permanently regardless of the
/// chosen mode -- currently just the Trash (see requiresPermanentDelete()).
@property(nonatomic, readonly) BOOL forcesPermanentDelete;
@property(nonatomic, copy, readonly) NSArray<MCEntryNode *> *entries;

/// Derived from the entries' selection.
@property(nonatomic, readonly) MCSelectionState selectionState;
- (void)setAllEntriesSelected:(BOOL)selected;
@end

/// What a clean run actually did.
@interface MCCleanSummary : NSObject
@property(nonatomic, readonly) unsigned long long bytesFreed;
@property(nonatomic, readonly) NSUInteger succeededCount;
@property(nonatomic, readonly) NSUInteger skippedCount;
@property(nonatomic, readonly) NSUInteger failedCount;
/// Human-readable "SKIP <path> (reason)" / "FAIL <path> (reason)" lines, for
/// the detail pane of the result alert. Successes are not listed.
@property(nonatomic, copy, readonly) NSArray<NSString *> *problems;
@end

@interface MCScanModel : NSObject

/// Populated after -scanWithCompletion: finishes. Main-thread only.
@property(nonatomic, copy, readonly) NSArray<MCCategoryNode *> *categories;

/// YES when this build moves items to the real Trash. NO in a fallback build,
/// where "Trash" mode is actually an irreversible delete.
@property(nonatomic, readonly) BOOL trashIsRecoverable;

/// Total size of every currently selected entry.
@property(nonatomic, readonly) unsigned long long selectedBytes;
@property(nonatomic, readonly) NSUInteger selectedCount;
/// YES if anything selected will be permanently deleted even in Trash mode.
@property(nonatomic, readonly) BOOL selectionIncludesForcedPermanent;

/// Scans every known category off the main thread, one category at a time.
/// `willScan` fires just before a category's tree walk starts and `didScan`
/// just after it finishes (didScan's node is nil for categories that turned
/// out empty/absent and were dropped from the list). All three blocks run on
/// the main queue, in order, so a UI can animate the scan as it progresses.
- (void)scanWithWillScanCategory:(nullable void (^)(NSString *label, NSString *path))willScan
                  didScanCategory:(nullable void (^)(MCCategoryNode *_Nullable node))didScan
                       completion:(void (^)(void))completion;

/// Deletes the selected entries one at a time. `permanent` maps to the CLI's
/// --permanent. `progress` fires on the main queue after each entry with the
/// outcome and the running totals; `completion` runs on main afterwards.
/// Does nothing (immediate empty-summary completion) if nothing is selected.
- (void)cleanSelectedPermanently:(BOOL)permanent
                    entryProgress:(nullable void (^)(NSString *path,
                                                      BOOL succeeded,
                                                      BOOL skippedBySafety,
                                                      NSString *message,
                                                      unsigned long long bytesFreedSoFar,
                                                      NSUInteger itemsDone,
                                                      NSUInteger itemsTotal))progress
                       completion:(void (^)(MCCleanSummary *summary))completion;

@end

NS_ASSUME_NONNULL_END
