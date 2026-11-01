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

#pragma mark - Aurora

/// The gradient plus one blurred radial blob per colour stop, each drifting
/// on its own period so the pattern never visibly repeats. Animations live
/// on the render server: no timers, nothing on the main thread.
@interface MCAuroraLayer : CAGradientLayer
@property(nonatomic, copy) NSArray<CAGradientLayer *> *blobs;
@property(nonatomic) CGSize laidOutSize;
@end

@implementation MCAuroraLayer

- (void)layoutSublayers {
    [super layoutSublayers];
    const CGSize size = self.bounds.size;
    if (CGSizeEqualToSize(size, self.laidOutSize) || size.width <= 0 || size.height <= 0) {
        return;
    }
    self.laidOutSize = size;
    // Start and end of each blob's drift, as fractions of the bounds.
    static const CGPoint kFrom[] = {{0.15, 0.85}, {0.85, 0.75}, {0.5, 0.1}};
    static const CGPoint kTo[] = {{0.45, 0.55}, {0.6, 0.25}, {0.2, 0.35}};
    static const CFTimeInterval kPeriod[] = {12, 16, 20};
    const CGFloat diameter = MAX(size.width, size.height) * 0.75;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self.blobs enumerateObjectsUsingBlock:^(CAGradientLayer *blob, NSUInteger i, BOOL *) {
        blob.bounds = CGRectMake(0, 0, diameter, diameter);
        const CGPoint from = CGPointMake(kFrom[i].x * size.width, kFrom[i].y * size.height);
        blob.position = from;
        [blob removeAllAnimations];
        if (MCTheme.reduceMotion) {
            return;
        }
        CABasicAnimation *drift = [CABasicAnimation animationWithKeyPath:@"position"];
        drift.fromValue = [NSValue valueWithPoint:from];
        drift.toValue = [NSValue valueWithPoint:NSMakePoint(kTo[i].x * size.width, kTo[i].y * size.height)];
        drift.duration = kPeriod[i];
        drift.autoreverses = YES;
        drift.repeatCount = HUGE_VALF;
        drift.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [blob addAnimation:drift forKey:@"drift"];
    }];
    [CATransaction commit];
}

@end

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

+ (CAGradientLayer *)auroraLayerForTool:(MCTool)tool {
    MCAuroraLayer *layer = [MCAuroraLayer layer];
    CAGradientLayer *base = [self gradientLayerForTool:tool];
    layer.colors = base.colors;
    layer.startPoint = base.startPoint;
    layer.endPoint = base.endPoint;
    layer.masksToBounds = YES;
    NSMutableArray<CAGradientLayer *> *blobs = [NSMutableArray array];
    NSArray<NSColor *> *colors = [self colorsForTool:tool];
    for (NSUInteger i = 0; i < colors.count; ++i) {
        // Each blob carries the next stop's colour, so blobs stand out from
        // the gradient under them; a little white keeps them luminous.
        NSColor *color = colors[(i + 1) % colors.count];
        NSColor *blended = [color blendedColorWithFraction:0.15 ofColor:NSColor.whiteColor];
        NSColor *light = blended != nil ? blended : color;
        CAGradientLayer *blob = [CAGradientLayer layer];
        blob.type = kCAGradientLayerRadial;
        blob.colors = @[ (id)[light colorWithAlphaComponent:0.85].CGColor, (id)[light colorWithAlphaComponent:0].CGColor ];
        blob.startPoint = CGPointMake(0.5, 0.5);
        blob.endPoint = CGPointMake(1, 1);
        [layer addSublayer:blob];
        [blobs addObject:blob];
    }
    layer.blobs = blobs;
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
    NSView *panel = nil;
    if (@available(macOS 26.0, *)) {
        NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:NSZeroRect];
        glass.cornerRadius = radius;
        glass.contentView = content;
        panel = glass;
    } else {
        panel = [self blurPanelWithCornerRadius:radius];
        [panel addSubview:content];
    }
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    // Size the panel from its content in both paths.
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:panel.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor],
    ]];
    return panel;
}

+ (NSView *)blurPanelWithCornerRadius:(CGFloat)radius {
    NSVisualEffectView *blur = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    blur.material = NSVisualEffectMaterialPopover;
    blur.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    blur.state = NSVisualEffectStateActive;
    blur.wantsLayer = YES;
    blur.layer.cornerRadius = radius;
    blur.layer.masksToBounds = YES;
    blur.layer.borderWidth = 0.5;
    blur.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.25].CGColor;
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
/// Round style: a ring that keeps expanding out of the button and fading.
@property(nonatomic, strong, nullable) CAShapeLayer *halo;
/// macOS 26+ pills: the system Liquid Glass bezel draws the button.
@property(nonatomic) BOOL systemGlass;
- (void)drawCustomInRect:(NSRect)rect;
@end

/// Draws the custom styles. A cell rather than -drawRect: on the button:
/// overriding -drawRect: stops AppKit from rendering the system glass bezel
/// on macOS 26, so the system-glass buttons must keep the stock cell.
@interface MCGlassButtonCell : NSButtonCell
@end

@implementation MCGlassButtonCell

- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView *)controlView {
    [(MCGlassButton *)controlView drawCustomInRect:cellFrame];
}

@end

@implementation MCGlassButton

+ (instancetype)buttonWithTitle:(NSString *)title
                          style:(MCGlassButtonStyle)style
                           tool:(MCTool)tool
                         target:(nullable id)target
                         action:(nullable SEL)action {
    MCGlassButton *button = [[self alloc] initWithFrame:NSZeroRect];
    if (@available(macOS 26.0, *)) {
        button.systemGlass = style != MCGlassButtonStyleRound;
    }
    if (!button.systemGlass) {
        button.cell = [[MCGlassButtonCell alloc] init]; // first: a new cell resets target and title
    }
    button.glassStyle = style;
    button.tool = tool;
    button.target = target;
    button.action = action;
    button.translatesAutoresizingMaskIntoConstraints = NO;
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

- (void)layout {
    [super layout];
    if (self.glassStyle != MCGlassButtonStyleRound) {
        return;
    }
    if (self.halo == nil) {
        self.wantsLayer = YES;
        self.halo = [CAShapeLayer layer];
        self.halo.fillColor = nil;
        self.halo.strokeColor = [NSColor colorWithWhite:1 alpha:0.8].CGColor;
        self.halo.lineWidth = 2;
        self.halo.opacity = 0;
        [self.layer addSublayer:self.halo];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.halo.frame = self.bounds;
    CGPathRef path = CGPathCreateWithEllipseInRect(NSInsetRect(self.bounds, 2, 2), NULL);
    self.halo.path = path;
    CGPathRelease(path);
    [CATransaction commit];
    if ([self.halo animationForKey:@"halo"] != nil || MCTheme.reduceMotion) {
        return;
    }
    CABasicAnimation *grow = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    grow.fromValue = @1;
    grow.toValue = @1.3;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0.7;
    fade.toValue = @0;
    CAAnimationGroup *pulse = [CAAnimationGroup animation];
    pulse.animations = @[ grow, fade ];
    pulse.duration = 1.8;
    pulse.repeatCount = HUGE_VALF;
    pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [self.halo addAnimation:pulse forKey:@"halo"];
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

- (void)drawCustomInRect:(NSRect)rect {
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
