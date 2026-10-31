#import "MCTheme.h"

#import <QuartzCore/QuartzCore.h>

namespace {

NSColor *rgb(uint32_t hex) {
    return [NSColor colorWithSRGBRed:((hex >> 16) & 0xff) / 255.0
                               green:((hex >> 8) & 0xff) / 255.0
                                blue:(hex & 0xff) / 255.0
                               alpha:1.0];
}

struct Gradient {
    uint32_t start, end;
};

Gradient gradientFor(MCTool tool) {
    switch (tool) {
        case MCToolCleaner: return {0x6d28d9, 0x2563eb};     // violet -> blue
        case MCToolLargeFiles: return {0x0f766e, 0x16a34a};  // teal -> green
        case MCToolPhotos: return {0xdb2777, 0xea580c};      // pink -> orange
        case MCToolPerformance: return {0xc2410c, 0xd97706}; // orange -> amber
        case MCToolOrganizer: return {0x0369a1, 0x4f46e5};   // sky -> indigo
        case MCToolHome: return {0x4338ca, 0x0891b2};        // indigo -> cyan
        case MCToolAntivirus: return {0xb91c1c, 0xc2410c};   // red -> orange
    }
    return {0x6d28d9, 0x2563eb};
}

/// A template symbol painted white: SourceAtop keeps the glyph's shape
/// (palette colours would need macOS 12).
NSImage *_Nullable whiteSymbol(NSString *name, CGFloat pointSize) {
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:pointSize
                                                                                         weight:NSFontWeightSemibold];
    NSImage *symbol = [[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]
        imageWithSymbolConfiguration:config];
    if (symbol == nil) {
        return nil;
    }
    return [NSImage imageWithSize:symbol.size
                          flipped:NO
                   drawingHandler:^BOOL(NSRect rect) {
                       [symbol drawInRect:rect];
                       [NSColor.whiteColor set];
                       NSRectFillUsingOperation(rect, NSCompositingOperationSourceAtop);
                       return YES;
                   }];
}

} // namespace

@implementation MCTheme

+ (NSColor *)startColorForTool:(MCTool)tool {
    return rgb(gradientFor(tool).start);
}

+ (NSColor *)endColorForTool:(MCTool)tool {
    return rgb(gradientFor(tool).end);
}

+ (CAGradientLayer *)gradientLayerForTool:(MCTool)tool {
    CAGradientLayer *layer = [CAGradientLayer layer];
    layer.colors = @[ (id)[self startColorForTool:tool].CGColor, (id)[self endColorForTool:tool].CGColor ];
    // Layer space is y-up on macOS: (0, 1) is the top-left corner.
    layer.startPoint = CGPointMake(0, 1);
    layer.endPoint = CGPointMake(1, 0);
    return layer;
}

+ (NSImage *)badgeWithSymbol:(NSString *)symbolName size:(CGFloat)size tool:(MCTool)tool {
    NSImage *glyph = whiteSymbol(symbolName, size * 0.5);
    NSColor *start = [self startColorForTool:tool];
    NSColor *end = [self endColorForTool:tool];
    return [NSImage imageWithSize:NSMakeSize(size, size)
                          flipped:NO
                   drawingHandler:^BOOL(NSRect rect) {
                       const CGFloat radius = rect.size.width * 0.225;
                       NSBezierPath *tile = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius];
                       [[[NSGradient alloc] initWithStartingColor:start endingColor:end] drawInBezierPath:tile
                                                                                                     angle:-45];
                       if (glyph != nil) {
                           const NSSize g = glyph.size;
                           [glyph drawInRect:NSMakeRect(NSMidX(rect) - g.width / 2, NSMidY(rect) - g.height / 2,
                                                        g.width, g.height)];
                       }
                       return YES;
                   }];
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

@end

#pragma mark - MCGlassButton

@interface MCGlassButton ()
@property(nonatomic) MCGlassButtonStyle glassStyle;
@property(nonatomic) MCTool tool;
@end

@implementation MCGlassButton

+ (instancetype)buttonWithTitle:(NSString *)title
                          style:(MCGlassButtonStyle)style
                           tool:(MCTool)tool
                         target:(nullable id)target
                         action:(nullable SEL)action {
    MCGlassButton *button = [[self alloc] initWithFrame:NSZeroRect];
    button.glassStyle = style;
    button.tool = tool;
    button.title = title;
    button.target = target;
    button.action = action;
    button.bordered = NO;
    button.buttonType = NSButtonTypeMomentaryChange;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    return button;
}

- (NSFont *)titleFont {
    switch (self.glassStyle) {
        case MCGlassButtonStyleRound: return [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
        case MCGlassButtonStylePill:
        case MCGlassButtonStylePillPrimary: return [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    }
    return [NSFont systemFontOfSize:13];
}

- (NSSize)intrinsicContentSize {
    if (self.glassStyle == MCGlassButtonStyleRound) {
        return NSMakeSize(92, 92);
    }
    const NSSize text = [self.title sizeWithAttributes:@{NSFontAttributeName : [self titleFont]}];
    return NSMakeSize(ceil(text.width) + 32, 30);
}

- (void)setTitle:(NSString *)title {
    [super setTitle:title];
    [self invalidateIntrinsicContentSize];
    self.needsDisplay = YES;
}

- (NSBezierPath *)shapeInRect:(NSRect)rect {
    if (self.glassStyle == MCGlassButtonStyleRound) {
        return [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(rect, 2, 2)];
    }
    const CGFloat radius = rect.size.height / 2;
    return [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, 1, 1) xRadius:radius - 1 yRadius:radius - 1];
}

- (void)drawRect:(NSRect)dirtyRect {
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    if (!self.enabled) {
        CGContextSetAlpha(context, 0.45);
    }

    NSBezierPath *shape = [self shapeInRect:self.bounds];
    const BOOL pressed = self.isHighlighted;
    NSColor *titleColor = NSColor.whiteColor;
    switch (self.glassStyle) {
        case MCGlassButtonStyleRound:
            [[NSColor colorWithWhite:1 alpha:pressed ? 0.34 : 0.2] setFill];
            [shape fill];
            [[NSColor colorWithWhite:1 alpha:0.75] setStroke];
            shape.lineWidth = 2;
            [shape stroke];
            break;
        case MCGlassButtonStylePill:
            [[NSColor colorWithWhite:1 alpha:pressed ? 0.34 : 0.2] setFill];
            [shape fill];
            break;
        case MCGlassButtonStylePillPrimary:
            [[NSColor colorWithWhite:1 alpha:pressed ? 0.8 : 1] setFill];
            [shape fill];
            titleColor = [MCTheme startColorForTool:self.tool];
            break;
    }

    NSDictionary *attributes = @{NSFontAttributeName : [self titleFont], NSForegroundColorAttributeName : titleColor};
    const NSSize text = [self.title sizeWithAttributes:attributes];
    [self.title drawAtPoint:NSMakePoint(NSMidX(self.bounds) - text.width / 2, NSMidY(self.bounds) - text.height / 2)
             withAttributes:attributes];
    CGContextRestoreGState(context);
}

- (void)drawFocusRingMask {
    [[self shapeInRect:self.bounds] fill];
}

- (NSRect)focusRingMaskBounds {
    return self.bounds;
}

@end
