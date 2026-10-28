#import "MCTheme.h"

namespace {

NSColor *dynamicColor(uint32_t lightRGB, uint32_t darkRGB) {
    auto make = [](uint32_t rgb) {
        return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xff) / 255.0
                                   green:((rgb >> 8) & 0xff) / 255.0
                                    blue:(rgb & 0xff) / 255.0
                                   alpha:1.0];
    };
    NSColor *light = make(lightRGB);
    NSColor *dark = make(darkRGB);
    return [NSColor colorWithName:nil
                  dynamicProvider:^NSColor *(NSAppearance *appearance) {
                      NSAppearanceName match = [appearance
                          bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
                      return [match isEqualToString:NSAppearanceNameDarkAqua] ? dark : light;
                  }];
}

BOOL drawingDark() {
    NSAppearanceName match = [NSAppearance.currentDrawingAppearance
        bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
    return [match isEqualToString:NSAppearanceNameDarkAqua];
}

NSImage *_Nullable bundledImage(NSString *name) {
    NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"png"];
    NSImage *image = path != nil ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
    NSImageRep *rep = image.representations.firstObject;
    if (rep == nil) {
        return nil;
    }
    // The art is drawn at @2x; without this a 72-dpi PNG would show at
    // double size.
    image.size = NSMakeSize(static_cast<CGFloat>(rep.pixelsWide) / 2, static_cast<CGFloat>(rep.pixelsHigh) / 2);
    return image;
}

} // namespace

@implementation MCTheme

+ (NSColor *)brandColor {
    static NSColor *color = dynamicColor(0x1c5ced, 0x3d7bff);
    return color;
}

+ (NSColor *)brandSecondaryColor {
    static NSColor *color = dynamicColor(0x21b5de, 0x3cc8ee);
    return color;
}

+ (NSImage *)badgeWithSymbol:(NSString *)symbolName size:(CGFloat)size {
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:size * 0.5
                                                                                         weight:NSFontWeightSemibold];
    NSImage *symbol = [[NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil]
        imageWithSymbolConfiguration:config];
    // Symbols are template images; filling over them with SourceAtop keeps
    // the glyph's shape and paints it white (palette colours need macOS 12).
    NSImage *glyph = symbol == nil ? nil
                                   : [NSImage imageWithSize:symbol.size
                                                    flipped:NO
                                             drawingHandler:^BOOL(NSRect rect) {
                                                 [symbol drawInRect:rect];
                                                 [NSColor.whiteColor set];
                                                 NSRectFillUsingOperation(rect, NSCompositingOperationSourceAtop);
                                                 return YES;
                                             }];

    return [NSImage imageWithSize:NSMakeSize(size, size)
                          flipped:NO
                   drawingHandler:^BOOL(NSRect rect) {
                       const CGFloat radius = rect.size.width * 0.225;
                       NSBezierPath *tile = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius];
                       NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:[MCTheme brandColor]
                                                                            endingColor:[MCTheme brandSecondaryColor]];
                       [gradient drawInBezierPath:tile angle:-45];
                       if (glyph != nil) {
                           const NSSize g = glyph.size;
                           [glyph drawInRect:NSMakeRect(NSMidX(rect) - g.width / 2, NSMidY(rect) - g.height / 2,
                                                        g.width, g.height)];
                       }
                       return YES;
                   }];
}

+ (void)stylePrimaryButton:(NSButton *)button {
    button.bezelColor = [self brandColor];
}

+ (void)styleCard:(NSScrollView *)scrollView {
    scrollView.borderType = NSNoBorder;
    scrollView.wantsLayer = YES;
    scrollView.layer.cornerRadius = 10;
    scrollView.layer.masksToBounds = YES;
    if ([scrollView.documentView isKindOfClass:[NSTableView class]]) {
        NSTableView *table = (NSTableView *)scrollView.documentView;
        table.style = NSTableViewStyleInset;
        table.usesAlternatingRowBackgroundColors = NO;
    }
}

+ (nullable NSImage *)illustrationNamed:(NSString *)name {
    NSImage *light = bundledImage([name stringByAppendingString:@"-light"]);
    NSImage *dark = bundledImage([name stringByAppendingString:@"-dark"]);
    if (light == nil || dark == nil) {
        return nil;
    }
    return [NSImage imageWithSize:light.size
                          flipped:NO
                   drawingHandler:^BOOL(NSRect rect) {
                       [(drawingDark() ? dark : light) drawInRect:rect];
                       return YES;
                   }];
}

@end
