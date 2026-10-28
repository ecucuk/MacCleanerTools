// The app's look in one place: the brand colours (the icon's blue-to-teal
// gradient), the gradient badges in the sidebar, and the
// card style every list sits in. Everything else stays system: semantic
// colours, SF Symbols, standard controls -- so light, dark, increased
// contrast and the user's text size keep working without extra code here.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCTheme : NSObject

/// The gradient's two ends. Dynamic: lighter in dark mode so they keep their
/// contrast against dark surfaces.
+ (NSColor *)brandColor;
+ (NSColor *)brandSecondaryColor;

/// A rounded square filled with the brand gradient and a white SF Symbol, in
/// the style of System Settings. Re-renders per appearance.
+ (NSImage *)badgeWithSymbol:(NSString *)symbolName size:(CGFloat)size;

/// Tints the tool's main action with the brand colour.
+ (void)stylePrimaryButton:(NSButton *)button;

/// Turns a bordered list into a rounded card: no bezel, inset rows, no
/// alternating stripes.
+ (void)styleCard:(NSScrollView *)scrollView;

/// A bundled light/dark image pair (`<name>-light.png`, `<name>-dark.png`),
/// drawn with whichever matches the appearance at draw time.
+ (nullable NSImage *)illustrationNamed:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
