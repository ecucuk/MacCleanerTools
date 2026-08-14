// The Optimize review sheet: what the optimizer proposes to terminate, why,
// and how much each one is holding -- presented for review *before* anything
// is signalled. The review is the whole point: an optimizer that silently
// decides what to close on your behalf is how "cleaner" apps earn their bad
// name, and one wrong guess costs unsaved work.

#import <AppKit/AppKit.h>

@class MCOptimizationCandidate;

NS_ASSUME_NONNULL_BEGIN

@interface MCOptimizeSheetController : NSViewController

/// `onConfirm` receives only the candidates still checked, and is not called
/// at all if the user cancels.
- (instancetype)initWithCandidates:(NSArray<MCOptimizationCandidate *> *)candidates
                          onConfirm:(void (^)(NSArray<MCOptimizationCandidate *> *accepted))onConfirm;

@end

NS_ASSUME_NONNULL_END
