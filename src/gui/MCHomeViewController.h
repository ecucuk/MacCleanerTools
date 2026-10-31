// The Home hub the app opens on: one card per tool, each with a cheap live
// summary (reclaimable cache size, free disk space, memory in use). A click
// on a card asks the shell to open that tool. Summaries refresh each time
// Home appears; all of them are computed off the main thread.

#import <AppKit/AppKit.h>

#import "MCTheme.h"

NS_ASSUME_NONNULL_BEGIN

@interface MCHomeViewController : NSViewController

- (instancetype)init;

/// Adds a card, in sidebar order. Call before the view loads.
- (void)addCardForTool:(MCTool)tool title:(NSString *)title symbol:(NSString *)symbolName;

/// Called on main when the user clicks a card.
@property(nonatomic, copy, nullable) void (^openTool)(MCTool tool);

@end

NS_ASSUME_NONNULL_END
