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
    uint32_t start, middle, end;
};

Gradient gradientFor(MCTool tool) {
    switch (tool) {
        case MCToolCleaner: return {0x7c3aed, 0x4f46e5, 0x2563eb};       // violet -> indigo -> blue
        case MCToolLargeFiles: return {0x0f766e, 0x059669, 0x16a34a};    // teal -> emerald -> green
        case MCToolPhotos: return {0xdb2777, 0xe11d48, 0xea580c};        // pink -> rose -> orange
        case MCToolPerformance: return {0xc2410c, 0xea580c, 0xd97706};   // orange -> amber
        case MCToolOrganizer: return {0x0369a1, 0x2563eb, 0x4f46e5};     // sky -> blue -> indigo
        case MCToolHome: return {0x4338ca, 0x2563eb, 0x0891b2};          // indigo -> blue -> cyan
        case MCToolAntivirus: return {0xb91c1c, 0xdc2626, 0xc2410c};     // red -> orange
        case MCToolUpdater: return {0x047857, 0x059669, 0x0d9488};       // emerald -> teal
        case MCToolUninstaller: return {0x7c3aed, 0xc026d3, 0xdb2777};   // violet -> fuchsia -> pink
        case MCToolSmartOptimize: return {0xa21caf, 0x7c3aed, 0x0891b2}; // fuchsia -> violet -> cyan
    }
    return {0x7c3aed, 0x4f46e5, 0x2563eb};
}

/// A symbol drawn in white with hierarchical layers, so multi-part glyphs
/// keep their depth on a coloured tile.
NSImage *_Nullable whiteSymbol(NSString *name, CGFloat pointSize) {
    NSImageSymbolConfiguration *config = [[NSImageSymbolConfiguration configurationWithPointSize:pointSize
                                                                                          weight:NSFontWeightSemibold]
        configurationByApplyingConfiguration:[NSImageSymbolConfiguration
                                                 configurationWithHierarchicalColor:NSColor.whiteColor]];
    return [[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil] imageWithSymbolConfiguration:config];
}

} // namespace

@implementation MCTheme

+ (NSString *)symbolForTool:(MCTool)tool {
    switch (tool) {
        case MCToolCleaner: return @"bubbles.and.sparkles.fill";
        case MCToolLargeFiles: return @"doc.viewfinder.fill";
        case MCToolPhotos: return @"photo.stack.fill";
        case MCToolPerformance: return @"bolt.fill";
        case MCToolOrganizer: return @"folder.fill.badge.gearshape";
        case MCToolHome: return @"house.fill";
        case MCToolAntivirus: return @"checkmark.shield.fill";
        case MCToolUpdater: return @"arrow.down.app.fill";
        case MCToolUninstaller: return @"xmark.app.fill";
        case MCToolSmartOptimize: return @"wand.and.stars";
    }
    return @"sparkles";
}

+ (NSArray<NSColor *> *)colorsForTool:(MCTool)tool {
    const Gradient g = gradientFor(tool);
    return @[ rgb(g.start), rgb(g.middle), rgb(g.end) ];
}

+ (NSColor *)startColorForTool:(MCTool)tool {
    return rgb(gradientFor(tool).start);
}

+ (NSColor *)endColorForTool:(MCTool)tool {
    return rgb(gradientFor(tool).end);
}

+ (CAGradientLayer *)gradientLayerForTool:(MCTool)tool {
    CAGradientLayer *layer = [CAGradientLayer layer];
    NSMutableArray *colors = [NSMutableArray array];
    for (NSColor *color in [self colorsForTool:tool]) {
        [colors addObject:(id)color.CGColor];
    }
    layer.colors = colors;
    // Layer space is y-up on macOS: (0, 1) is the top-left corner.
    layer.startPoint = CGPointMake(0, 1);
    layer.endPoint = CGPointMake(1, 0);
    return layer;
}

+ (NSImage *)badgeWithSymbol:(NSString *)symbolName size:(CGFloat)size tool:(MCTool)tool {
    NSImage *glyph = whiteSymbol(symbolName, size * 0.46);
    NSGradient *fill = [[NSGradient alloc] initWithColors:[self colorsForTool:tool]];
    return [NSImage imageWithSize:NSMakeSize(size, size)
                          flipped:NO
                   drawingHandler:^BOOL(NSRect rect) {
                       // Leave room for the drop shadow inside the image.
                       const NSRect tileRect = NSInsetRect(rect, rect.size.width * 0.04, rect.size.width * 0.04);
                       const CGFloat radius = tileRect.size.width * 0.225;
                       NSBezierPath *tile = [NSBezierPath bezierPathWithRoundedRect:tileRect
                                                                            xRadius:radius
                                                                            yRadius:radius];
                       [NSGraphicsContext saveGraphicsState];
                       NSShadow *shadow = [[NSShadow alloc] init];
                       shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.28];
                       shadow.shadowOffset = NSMakeSize(0, -rect.size.width * 0.02);
                       shadow.shadowBlurRadius = rect.size.width * 0.04;
                       [shadow set];
                       [fill drawInBezierPath:tile angle:-45];
                       [NSGraphicsContext restoreGraphicsState];

                       // Glass highlight over the top half, and a light rim.
                       [NSGraphicsContext saveGraphicsState];
                       [tile addClip];
                       NSGradient *shine = [[NSGradient alloc]
                           initWithStartingColor:[NSColor colorWithWhite:1 alpha:0.38]
                                     endingColor:[NSColor colorWithWhite:1 alpha:0]];
                       [shine drawInRect:NSMakeRect(NSMinX(tileRect), NSMidY(tileRect), NSWidth(tileRect),
                                                    NSHeight(tileRect) / 2)
                                   angle:-90];
                       [NSGraphicsContext restoreGraphicsState];
                       [[NSColor colorWithWhite:1 alpha:0.28] setStroke];
                       NSBezierPath *rim = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(tileRect, 0.5, 0.5)
                                                                           xRadius:radius - 0.5
                                                                           yRadius:radius - 0.5];
                       rim.lineWidth = 1;
                       [rim stroke];

                       if (glyph != nil) {
                           const NSSize g = glyph.size;
                           [glyph drawInRect:NSMakeRect(NSMidX(tileRect) - g.width / 2,
                                                        NSMidY(tileRect) - g.height / 2, g.width, g.height)];
                       }
                       return YES;
                   }];
}

+ (NSView *)glassViewWithCornerRadius:(CGFloat)radius content:(NSView *)content {
    content.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(macOS 26.0, *)) {
        NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:NSZeroRect];
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        glass.cornerRadius = radius;
        glass.contentView = content;
        return glass;
    }
    NSVisualEffectView *blur = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    blur.translatesAutoresizingMaskIntoConstraints = NO;
    blur.material = NSVisualEffectMaterialPopover;
    blur.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    blur.state = NSVisualEffectStateActive;
    blur.wantsLayer = YES;
    blur.layer.cornerRadius = radius;
    blur.layer.masksToBounds = YES;
    blur.layer.borderWidth = 0.5;
    blur.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.25].CGColor;
    [blur addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:blur.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:blur.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:blur.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:blur.bottomAnchor],
    ]];
    return blur;
}

+ (BOOL)reduceMotion {
    return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
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
@property(nonatomic) BOOL hovered;
/// macOS 26+ pills: the system Liquid Glass bezel draws the button.
@property(nonatomic) BOOL systemGlass;
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
    button.target = target;
    button.action = action;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(macOS 26.0, *)) {
        button.systemGlass = style != MCGlassButtonStyleRound;
    }
    if (button.systemGlass) {
        if (@available(macOS 26.0, *)) {
            button.bezelStyle = NSBezelStyleGlass;
            button.controlSize = NSControlSizeLarge;
            if (style == MCGlassButtonStylePillPrimary) {
                button.bezelColor = [NSColor colorWithWhite:1 alpha:0.92];
            }
        }
    } else {
        button.bordered = NO;
        button.buttonType = NSButtonTypeMomentaryChange;
    }
    button.title = title;
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

- (NSColor *)titleColor {
    return self.glassStyle == MCGlassButtonStylePillPrimary ? [MCTheme startColorForTool:self.tool]
                                                            : NSColor.whiteColor;
}

- (NSSize)intrinsicContentSize {
    if (self.glassStyle == MCGlassButtonStyleRound) {
        return NSMakeSize(92, 92);
    }
    if (self.systemGlass) {
        return super.intrinsicContentSize;
    }
    const NSSize text = [self.title sizeWithAttributes:@{NSFontAttributeName : [self titleFont]}];
    return NSMakeSize(ceil(text.width) + 32, 30);
}

- (void)setTitle:(NSString *)title {
    [super setTitle:title];
    if (self.systemGlass) {
        self.attributedTitle = [[NSAttributedString alloc]
            initWithString:title
                attributes:@{NSFontAttributeName : [self titleFont], NSForegroundColorAttributeName : [self titleColor]}];
    }
    [self invalidateIntrinsicContentSize];
    self.needsDisplay = YES;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.systemGlass) {
        return; // the system bezel has its own hover response
    }
    for (NSTrackingArea *area in self.trackingAreas) {
        if (area.owner == self) {
            [self removeTrackingArea:area];
        }
    }
    [self addTrackingArea:[[NSTrackingArea alloc]
                              initWithRect:NSZeroRect
                                   options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow |
                                           NSTrackingInVisibleRect
                                     owner:self
                                  userInfo:nil]];
}

- (void)mouseEntered:(NSEvent *)event {
    self.hovered = YES;
    self.needsDisplay = YES;
}

- (void)mouseExited:(NSEvent *)event {
    self.hovered = NO;
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
    if (self.systemGlass) {
        [super drawRect:dirtyRect];
        return;
    }
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    if (!self.enabled) {
        CGContextSetAlpha(context, 0.45);
    }

    NSBezierPath *shape = [self shapeInRect:self.bounds];
    const BOOL pressed = self.isHighlighted;
    const BOOL lit = self.hovered && self.enabled;
    if (self.glassStyle == MCGlassButtonStylePillPrimary) {
        [[NSColor colorWithWhite:1 alpha:pressed ? 0.8 : 1] setFill];
        [shape fill];
    } else {
        [[NSColor colorWithWhite:1 alpha:pressed ? 0.36 : (lit ? 0.28 : 0.18)] setFill];
        [shape fill];
        // Glass: a highlight on the top half, a bright rim on top, a darker one below.
        [NSGraphicsContext saveGraphicsState];
        [shape addClip];
        NSGradient *shine = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:1 alpha:lit ? 0.45 : 0.32]
                                                          endingColor:[NSColor colorWithWhite:1 alpha:0]];
        [shine drawInRect:NSMakeRect(0, NSMidY(self.bounds), NSWidth(self.bounds), NSHeight(self.bounds) / 2)
                    angle:-90];
        [NSGraphicsContext restoreGraphicsState];
        NSGradient *rim = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:1 alpha:0.9]
                                                        endingColor:[NSColor colorWithWhite:1 alpha:0.25]];
        NSBezierPath *outline = [self shapeInRect:NSInsetRect(self.bounds, 0.75, 0.75)];
        outline.lineWidth = self.glassStyle == MCGlassButtonStyleRound ? 2 : 1;
        [NSGraphicsContext saveGraphicsState];
        // Stroke through a clip of the outline's own stroke area to paint it with a gradient.
        CGContextAddPath(context, outline.CGPath);
        CGContextSetLineWidth(context, outline.lineWidth);
        CGContextReplacePathWithStrokedPath(context);
        CGContextClip(context);
        [rim drawInRect:self.bounds angle:-90];
        [NSGraphicsContext restoreGraphicsState];
    }

    NSDictionary *attributes = @{NSFontAttributeName : [self titleFont], NSForegroundColorAttributeName : [self titleColor]};
    const NSSize text = [self.title sizeWithAttributes:attributes];
    [self.title drawAtPoint:NSMakePoint(NSMidX(self.bounds) - text.width / 2, NSMidY(self.bounds) - text.height / 2)
             withAttributes:attributes];
    CGContextRestoreGState(context);
}

- (void)drawFocusRingMask {
    if (self.systemGlass) {
        [super drawFocusRingMask];
        return;
    }
    [[self shapeInRect:self.bounds] fill];
}

- (NSRect)focusRingMaskBounds {
    return self.systemGlass ? super.focusRingMaskBounds : self.bounds;
}

@end
