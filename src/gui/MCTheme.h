// The app's look in one place. Each tool has its own two-colour gradient
// (its hero screen, results banner and sidebar badge); everything around
// them stays system -- semantic colours, SF Symbols, standard lists -- so
// light, dark and increased contrast keep working without extra code here.
//
// The gradients are the same in light and dark mode: they always sit under
// white text, and their stops are dark enough for that text to stay legible.

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MCTool) {
    MCToolCleaner,
    MCToolLargeFiles,
    MCToolPhotos,
    MCToolPerformance,
    MCToolOrganizer,
    MCToolUpdater,
};

@interface MCTheme : NSObject

/// The tool's gradient, start (top-left) to end (bottom-right).
+ (NSColor *)startColorForTool:(MCTool)tool;
+ (NSColor *)endColorForTool:(MCTool)tool;

/// A layer filled with the tool's diagonal gradient.
+ (CAGradientLayer *)gradientLayerForTool:(MCTool)tool;

/// A rounded square with the tool's gradient and a white SF Symbol, in the
/// style of System Settings.
+ (NSImage *)badgeWithSymbol:(NSString *)symbolName size:(CGFloat)size tool:(MCTool)tool;

/// Turns a bordered list into a rounded card: no bezel, inset rows, no
/// alternating stripes.
+ (void)styleCard:(NSScrollView *)scrollView;

@end

typedef NS_ENUM(NSInteger, MCGlassButtonStyle) {
    MCGlassButtonStyleRound,       // the hero's big circular action
    MCGlassButtonStylePill,        // a translucent white pill on a gradient
    MCGlassButtonStylePillPrimary, // a solid white pill, title in the tool colour
};

/// A button drawn for a gradient background. Still an NSButton: target,
/// action, key equivalent, enabled state and accessibility work as usual.
@interface MCGlassButton : NSButton

+ (instancetype)buttonWithTitle:(NSString *)title
                          style:(MCGlassButtonStyle)style
                           tool:(MCTool)tool
                         target:(nullable id)target
                         action:(nullable SEL)action;

@end

NS_ASSUME_NONNULL_END
