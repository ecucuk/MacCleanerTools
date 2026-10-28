#import "MCHeroView.h"

#import <QuartzCore/QuartzCore.h>

namespace {
constexpr CGFloat kEmblemBox = 200;  // glow included
constexpr CGFloat kOrbDiameter = 124;
constexpr CGFloat kRingRadius = 76;
NSString *const kSpinKey = @"spin";
NSString *const kPulseKey = @"pulse";

NSTextField *whiteLabel(NSString *text, NSFont *font, CGFloat alpha) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = font;
    label.textColor = [NSColor colorWithWhite:1 alpha:alpha];
    label.alignment = NSTextAlignmentCenter;
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    // Status lines carry changing paths: truncate, never widen the window.
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    return label;
}
} // namespace

#pragma mark - Emblem

/// A frosted orb with the tool's symbol, a soft glow behind it and a ring
/// that spins while a scan runs. Pure Core Animation, so it stays sharp at
/// any scale and costs nothing while idle.
@interface MCEmblemView : NSView
@property(nonatomic, strong) CAGradientLayer *glow;
@property(nonatomic, strong) CAGradientLayer *orb;
@property(nonatomic, strong) CAShapeLayer *track;
@property(nonatomic, strong) CAShapeLayer *ring;
@property(nonatomic, strong) NSImageView *symbol;
- (void)setSpinning:(BOOL)spinning;
@end

@implementation MCEmblemView

- (instancetype)initWithSymbol:(NSString *)symbolName {
    if ((self = [super initWithFrame:NSMakeRect(0, 0, kEmblemBox, kEmblemBox)])) {
        self.wantsLayer = YES;
        self.translatesAutoresizingMaskIntoConstraints = NO;

        _glow = [CAGradientLayer layer];
        _glow.type = kCAGradientLayerRadial;
        _glow.colors = @[ (id)[NSColor colorWithWhite:1 alpha:0.32].CGColor,
                          (id)[NSColor colorWithWhite:1 alpha:0].CGColor ];
        _glow.startPoint = CGPointMake(0.5, 0.5);
        _glow.endPoint = CGPointMake(1, 1);

        _orb = [CAGradientLayer layer];
        _orb.colors = @[ (id)[NSColor colorWithWhite:1 alpha:0.38].CGColor,
                         (id)[NSColor colorWithWhite:1 alpha:0.1].CGColor ];
        _orb.startPoint = CGPointMake(0.5, 1);
        _orb.endPoint = CGPointMake(0.5, 0);
        _orb.cornerRadius = kOrbDiameter / 2;
        _orb.borderWidth = 1.5;
        _orb.borderColor = [NSColor colorWithWhite:1 alpha:0.55].CGColor;

        _track = [CAShapeLayer layer];
        _track.fillColor = nil;
        _track.strokeColor = [NSColor colorWithWhite:1 alpha:0.2].CGColor;
        _track.lineWidth = 4;

        _ring = [CAShapeLayer layer];
        _ring.fillColor = nil;
        _ring.strokeColor = NSColor.whiteColor.CGColor;
        _ring.lineWidth = 4;
        _ring.lineCap = kCALineCapRound;
        _ring.strokeEnd = 0.28;

        for (CALayer *layer in @[ _glow, _orb, _track, _ring ]) {
            [self.layer addSublayer:layer];
        }

        NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:52
                                                                                             weight:NSFontWeightMedium];
        _symbol = [NSImageView imageViewWithImage:[[NSImage imageWithSystemSymbolName:symbolName
                                                                accessibilityDescription:nil]
                                                      imageWithSymbolConfiguration:config]];
        _symbol.contentTintColor = NSColor.whiteColor;
        _symbol.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_symbol];

        [NSLayoutConstraint activateConstraints:@[
            [self.widthAnchor constraintEqualToConstant:kEmblemBox],
            [self.heightAnchor constraintEqualToConstant:kEmblemBox],
            [_symbol.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_symbol.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
        [self setSpinning:NO];
    }
    return self;
}

- (void)layout {
    [super layout];
    const NSRect b = self.bounds;
    const CGPoint center = CGPointMake(NSMidX(b), NSMidY(b));
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.glow.frame = b;
    self.orb.bounds = CGRectMake(0, 0, kOrbDiameter, kOrbDiameter);
    self.orb.position = center;
    for (CAShapeLayer *layer in @[ self.track, self.ring ]) {
        layer.bounds = b;
        layer.position = center; // rotates about the emblem's centre
        CGPathRef path = CGPathCreateWithEllipseInRect(
            CGRectMake(center.x - kRingRadius, center.y - kRingRadius, 2 * kRingRadius, 2 * kRingRadius), NULL);
        layer.path = path;
        CGPathRelease(path);
    }
    [CATransaction commit];
}

- (void)setSpinning:(BOOL)spinning {
    self.track.hidden = !spinning;
    self.ring.hidden = !spinning;
    [self.ring removeAnimationForKey:kSpinKey];
    [self.orb removeAnimationForKey:kPulseKey];
    if (!spinning || NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) {
        return; // Reduce Motion: the ring stands still
    }
    CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    spin.fromValue = @0;
    spin.toValue = @(-2 * M_PI); // clockwise in y-up layer space
    spin.duration = 1.2;
    spin.repeatCount = HUGE_VALF;
    [self.ring addAnimation:spin forKey:kSpinKey];

    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    pulse.fromValue = @1;
    pulse.toValue = @1.05;
    pulse.duration = 0.9;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.orb addAnimation:pulse forKey:kPulseKey];
}

@end

#pragma mark - Hero

@interface MCHeroView ()
@property(nonatomic, strong) CAGradientLayer *background;
@property(nonatomic, strong) MCEmblemView *emblem;
@property(nonatomic, strong) NSTextField *subtitleLabel;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSStackView *actionsStack;
@property(nonatomic, strong) NSStackView *column;
@property(nonatomic) BOOL presented;
@property(nonatomic) BOOL scanning;
@end

@implementation MCHeroView

- (instancetype)initWithTool:(MCTool)tool
                      symbol:(NSString *)symbolName
                       title:(NSString *)title
                    subtitle:(NSString *)subtitle {
    if ((self = [super initWithFrame:NSZeroRect])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.wantsLayer = YES;
        _background = [MCTheme gradientLayerForTool:tool];
        [self.layer insertSublayer:_background atIndex:0];

        _emblem = [[MCEmblemView alloc] initWithSymbol:symbolName];
        NSTextField *titleLabel = whiteLabel(title, [NSFont systemFontOfSize:28 weight:NSFontWeightBold], 1);
        _subtitleLabel = whiteLabel(subtitle, [NSFont systemFontOfSize:15], 0.85);
        _statusLabel = whiteLabel(@"", [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular], 0.85);
        _statusLabel.hidden = YES;

        _actionsStack = [NSStackView stackViewWithViews:@[]];
        // The big round action on top, the quieter ones under it.
        _actionsStack.orientation = NSUserInterfaceLayoutOrientationVertical;
        _actionsStack.spacing = 14;
        _actionsStack.alignment = NSLayoutAttributeCenterX;

        _column = [NSStackView stackViewWithViews:@[ _emblem, titleLabel, _subtitleLabel, _statusLabel, _actionsStack ]];
        _column.orientation = NSUserInterfaceLayoutOrientationVertical;
        _column.alignment = NSLayoutAttributeCenterX;
        _column.spacing = 8;
        [_column setCustomSpacing:4 afterView:_emblem];
        [_column setCustomSpacing:28 afterView:_statusLabel];
        [_column setCustomSpacing:28 afterView:_subtitleLabel];
        _column.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_column];

        [NSLayoutConstraint activateConstraints:@[
            [_column.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_column.centerYAnchor constraintEqualToAnchor:self.centerYAnchor constant:-10],
            [_column.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:24],
            [_column.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-24],
        ]];
        self.hidden = YES;
    }
    return self;
}

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.background.frame = self.bounds;
    [CATransaction commit];
}

- (void)setActions:(NSArray<NSView *> *)actions {
    _actions = [actions copy];
    for (NSView *view in self.actionsStack.arrangedSubviews) {
        [self.actionsStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    for (NSView *view in _actions) {
        [self.actionsStack addArrangedSubview:view];
    }
}

- (void)setScanningAccessory:(NSView *)scanningAccessory {
    [_scanningAccessory removeFromSuperview];
    _scanningAccessory = scanningAccessory;
    if (scanningAccessory != nil) {
        scanningAccessory.hidden = YES;
        [self.column addArrangedSubview:scanningAccessory];
    }
}

- (void)showIdleWithMessage:(nullable NSString *)message {
    self.scanning = NO;
    [self.emblem setSpinning:NO];
    self.actionsStack.hidden = NO;
    self.scanningAccessory.hidden = YES;
    self.statusLabel.stringValue = message != nil ? message : @"";
    self.statusLabel.hidden = message.length == 0;
}

- (void)showScanningWithStatus:(NSString *)status {
    if (!self.scanning) {
        self.scanning = YES;
        [self.emblem setSpinning:YES]; // start once; status updates keep it running
    }
    self.actionsStack.hidden = YES;
    self.scanningAccessory.hidden = NO;
    [self setStatus:status];
}

- (void)setStatus:(NSString *)status {
    self.statusLabel.stringValue = status;
    self.statusLabel.hidden = NO;
}

- (void)setPresented:(BOOL)presented {
    _presented = presented;
    for (NSView *sibling in self.superview.subviews) {
        sibling.hidden = (sibling == self) ? !presented : presented;
    }
    if (!presented) {
        self.scanning = NO;
        [self.emblem setSpinning:NO];
    }
}

@end
