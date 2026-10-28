// A tool's start screen: its gradient full-bleed, an emblem, a title, one
// line of description and the tool's big actions. While a scan runs, a ring
// spins around the emblem and a status line reports progress. The owning
// view controller decides when to show it (-setPresented:) and which state
// it is in; this view only draws.

#import <AppKit/AppKit.h>

#import "MCTheme.h"

NS_ASSUME_NONNULL_BEGIN

@interface MCHeroView : NSView

- (instancetype)initWithTool:(MCTool)tool
                      symbol:(NSString *)symbolName
                       title:(NSString *)title
                    subtitle:(NSString *)subtitle NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/// The idle actions, top to bottom: the round Scan first (usually MCGlassButtons).
@property(nonatomic, copy) NSArray<NSView *> *actions;
/// Shown under the ring while scanning, e.g. a Stop button. Optional.
@property(nonatomic, strong, nullable) NSView *scanningAccessory;

/// Idle: actions visible. `message` (optional) explains the last result,
/// e.g. "Nothing to clean".
- (void)showIdleWithMessage:(nullable NSString *)message;
/// Scanning: ring, status line and the accessory instead of the actions.
- (void)showScanningWithStatus:(NSString *)status;
- (void)setStatus:(NSString *)status;

/// Shows this view over its superview and hides every sibling, so hidden
/// results can't take keyboard focus behind it; NO does the reverse.
- (void)setPresented:(BOOL)presented;
@property(nonatomic, readonly) BOOL presented;

@end

NS_ASSUME_NONNULL_END
