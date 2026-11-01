// The app's look in one place. Each tool has its own two-colour gradient
// (its hero screen, results banner and sidebar badge); everything around
// them stays system -- semantic colours, SF Symbols, standard lists -- so
// light, dark and increased contrast keep working without extra code here.
//
// The gradients are the same in light and dark mode: they always sit under
// white text, and their stops are dark enough for that text to stay legible.
//
// Glass: macOS 26+ gets the system Liquid Glass (NSGlassEffectView,
// NSBezelStyleGlass); macOS 14-25 gets a blurred NSVisualEffectView with a
// thin light rim. Both honour Reduce Transparency on their own.

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MCTool) {
    MCToolCleaner,
    MCToolLargeFiles,
    MCToolPhotos,
    MCToolPerformance,
    MCToolOrganizer,
    MCToolHome, // the hub and the splash screen
    MCToolAntivirus,
    MCToolUpdater,
    MCToolUninstaller,
    MCToolSmartOptimize, // Home's one-button optimizer
};

@interface MCTheme : NSObject

/// The tool's gradient, start (top-left) to end (bottom-right).
+ (NSColor *)startColorForTool:(MCTool)tool;
+ (NSColor *)endColorForTool:(MCTool)tool;

/// The tool's three gradient stops, top-left to bottom-right.
+ (NSArray<NSColor *> *)colorsForTool:(MCTool)tool;

/// A layer filled with the tool's diagonal gradient.
+ (CAGradientLayer *)gradientLayerForTool:(MCTool)tool;

/// The tool's SF Symbol (sidebar, badge, hero, banner).
+ (NSString *)symbolForTool:(MCTool)tool;

/// The tool's gradient with three soft colour blobs drifting over it
/// (still under Reduce Motion). Set its frame like any layer.
+ (CAGradientLayer *)auroraLayerForTool:(MCTool)tool;

/// A rounded square with the tool's gradient and a white SF Symbol, in the
/// style of System Settings.
+ (NSImage *)badgeWithSymbol:(NSString *)symbolName size:(CGFloat)size tool:(MCTool)tool;

/// `content` pinned inside a rounded glass panel (see the header comment).
+ (NSView *)glassViewWithCornerRadius:(CGFloat)radius content:(NSView *)content;

/// The user's Reduce Motion setting: decorative animations check it.
+ (BOOL)reduceMotion;

/// Turns a bordered list into a rounded card: no bezel, inset rows, no
/// alternating stripes.
+ (void)styleCard:(NSScrollView *)scrollView;

@end

/// A view whose background is the tool's aurora (see +auroraLayerForTool:).
@interface MCAuroraView : NSView
- (instancetype)initWithTool:(MCTool)tool;
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
