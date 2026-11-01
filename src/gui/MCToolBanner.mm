#import "MCToolBanner.h"

#import <QuartzCore/QuartzCore.h>

@interface MCToolBanner ()
@property(nonatomic, strong) CAGradientLayer *background;
@property(nonatomic, strong) NSTextField *valueLabel;
@property(nonatomic, strong) NSTextField *captionLabel;
@property(nonatomic, strong) NSStackView *actionsStack;
@end

@implementation MCToolBanner

- (instancetype)initWithTool:(MCTool)tool symbol:(NSString *)symbolName {
    if ((self = [super initWithFrame:NSZeroRect])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.wantsLayer = YES;
        self.layer.cornerRadius = 14;
        self.layer.masksToBounds = YES;
        _background = [MCTheme auroraLayerForTool:tool];
        [self.layer insertSublayer:_background atIndex:0];

        // A frosted disc with the white symbol: the badge's own gradient
        // would vanish on the banner's.
        NSView *badge = [[NSView alloc] initWithFrame:NSZeroRect];
        badge.translatesAutoresizingMaskIntoConstraints = NO;
        badge.wantsLayer = YES;
        badge.layer.cornerRadius = 24;
        badge.layer.backgroundColor = [NSColor colorWithWhite:1 alpha:0.2].CGColor;
        badge.layer.borderWidth = 1;
        badge.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.5].CGColor;
        NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:22
                                                                                             weight:NSFontWeightMedium];
        NSImageView *symbol = [NSImageView imageViewWithImage:[[NSImage imageWithSystemSymbolName:symbolName
                                                                         accessibilityDescription:nil]
                                                               imageWithSymbolConfiguration:config]];
        symbol.contentTintColor = NSColor.whiteColor;
        symbol.translatesAutoresizingMaskIntoConstraints = NO;
        [badge addSubview:symbol];
        [NSLayoutConstraint activateConstraints:@[
            [badge.widthAnchor constraintEqualToConstant:48],
            [badge.heightAnchor constraintEqualToConstant:48],
            [symbol.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
            [symbol.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],
        ]];

        _valueLabel = [NSTextField labelWithString:@"—"];
        _valueLabel.font = [NSFont monospacedDigitSystemFontOfSize:26 weight:NSFontWeightBold];
        _valueLabel.textColor = NSColor.whiteColor;

        _captionLabel = [NSTextField labelWithString:@""];
        _captionLabel.textColor = [NSColor colorWithWhite:1 alpha:0.85];
        _captionLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        // Captions carry paths: truncate, never widen the window. One above
        // the row stack's own hugging (DefaultLow), so the spare width goes
        // to the caption before the spacer.
        [_captionLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow + 1
                                                forOrientation:NSLayoutConstraintOrientationHorizontal];

        NSStackView *text = [NSStackView stackViewWithViews:@[ _valueLabel, _captionLabel ]];
        text.orientation = NSUserInterfaceLayoutOrientationVertical;
        text.alignment = NSLayoutAttributeLeading;
        text.spacing = 0;
        [text setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow + 1
                                       forOrientation:NSLayoutConstraintOrientationHorizontal];
        text.translatesAutoresizingMaskIntoConstraints = NO;
        NSView *plate = [[NSView alloc] initWithFrame:NSZeroRect];
        [plate addSubview:text];
        [NSLayoutConstraint activateConstraints:@[
            [text.leadingAnchor constraintEqualToAnchor:plate.leadingAnchor constant:14],
            [text.trailingAnchor constraintEqualToAnchor:plate.trailingAnchor constant:-14],
            [text.topAnchor constraintEqualToAnchor:plate.topAnchor constant:6],
            [text.bottomAnchor constraintEqualToAnchor:plate.bottomAnchor constant:-6],
        ]];
        // The number sits on a glass plate as wide as its text; a spacer
        // takes the spare width and pushes the actions right.
        NSView *glass = [MCTheme glassViewWithCornerRadius:12 content:plate];
        [glass setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow + 1
                                        forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSView *spacer = [[NSView alloc] initWithFrame:NSZeroRect];
        // A plain view has no intrinsic width, so hugging does nothing: ask
        // for zero width at the lowest priority instead, after the text.
        NSLayoutConstraint *collapse = [spacer.widthAnchor constraintEqualToConstant:0];
        collapse.priority = NSLayoutPriorityFittingSizeCompression;
        collapse.active = YES;

        _actionsStack = [NSStackView stackViewWithViews:@[]];
        _actionsStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        _actionsStack.spacing = 8;
        [_actionsStack setContentHuggingPriority:NSLayoutPriorityRequired
                                  forOrientation:NSLayoutConstraintOrientationHorizontal];

        NSStackView *row = [NSStackView stackViewWithViews:@[ badge, glass, spacer, _actionsStack ]];
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.alignment = NSLayoutAttributeCenterY;
        row.spacing = 14;
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:row];

        [NSLayoutConstraint activateConstraints:@[
            [row.topAnchor constraintEqualToAnchor:self.topAnchor constant:16],
            [row.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-16],
            [row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
            [row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        ]];
        // Keep its natural height; a stack can otherwise absorb spare height
        // and squash the list below.
        [self setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationVertical];
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

- (NSString *)value {
    return self.valueLabel.stringValue;
}

- (void)setValue:(NSString *)value {
    self.valueLabel.stringValue = value;
}

- (NSString *)caption {
    return self.captionLabel.stringValue;
}

- (void)setCaption:(NSString *)caption {
    self.captionLabel.stringValue = caption;
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

@end
