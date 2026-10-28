// The top of a tool's results: its gradient in a rounded band, the badge,
// one big number with a caption, and the tool's main actions on the right.

#import <AppKit/AppKit.h>

#import "MCTheme.h"

NS_ASSUME_NONNULL_BEGIN

@interface MCToolBanner : NSView

- (instancetype)initWithTool:(MCTool)tool symbol:(NSString *)symbolName NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@property(nonatomic, copy) NSString *value;
@property(nonatomic, copy) NSString *caption;
/// Right-aligned, left to right (usually MCGlassButtons).
@property(nonatomic, copy) NSArray<NSView *> *actions;

@end

NS_ASSUME_NONNULL_END
