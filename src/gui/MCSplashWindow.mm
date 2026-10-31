#import "MCSplashWindow.h"

#import <QuartzCore/QuartzCore.h>

#import "MCTheme.h"

namespace {
constexpr CGFloat kWidth = 360;
constexpr CGFloat kHeight = 260;
} // namespace

/// The gradient background; any click on it dismisses the splash.
@interface MCSplashView : NSView
@property(nonatomic, strong) CAGradientLayer *background;
@end

@implementation MCSplashView

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.background.frame = self.bounds;
    [CATransaction commit];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

- (void)mouseDown:(NSEvent *)event {
    [(MCSplashWindow *)self.window dismiss];
}

@end

@interface MCSplashWindow ()
@property(nonatomic) BOOL dismissed;
@end

@implementation MCSplashWindow

- (instancetype)init {
    if ((self = [super initWithContentRect:NSMakeRect(0, 0, kWidth, kHeight)
                                 styleMask:NSWindowStyleMaskBorderless
                                   backing:NSBackingStoreBuffered
                                     defer:NO])) {
        self.releasedWhenClosed = NO;
        self.opaque = NO;
        self.backgroundColor = NSColor.clearColor;
        self.hasShadow = YES;
        self.level = NSFloatingWindowLevel;

        MCSplashView *content = [[MCSplashView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, kHeight)];
        content.wantsLayer = YES;
        content.layer.cornerRadius = 18;
        content.layer.masksToBounds = YES;
        content.background = [MCTheme gradientLayerForTool:MCToolHome];
        [content.layer insertSublayer:content.background atIndex:0];

        NSImageView *icon = [NSImageView imageViewWithImage:NSApp.applicationIconImage];
        icon.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *name = [NSTextField labelWithString:@"MacCleaner"];
        name.font = [NSFont systemFontOfSize:26 weight:NSFontWeightBold];
        name.textColor = NSColor.whiteColor;

        NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        NSTextField *versionLabel =
            [NSTextField labelWithString:version != nil ? [@"Version " stringByAppendingString:version] : @""];
        versionLabel.textColor = [NSColor colorWithWhite:1 alpha:0.8];

        NSStackView *stack = [NSStackView stackViewWithViews:@[ icon, name, versionLabel ]];
        stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        stack.spacing = 6;
        [stack setCustomSpacing:12 afterView:icon];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [icon.widthAnchor constraintEqualToConstant:96],
            [icon.heightAnchor constraintEqualToConstant:96],
            [stack.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
            [stack.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        ]];

        self.contentView = content;
        self.accessibilityLabel = @"MacCleaner is starting";
        [self center];
    }
    return self;
}

- (void)showForSeconds:(NSTimeInterval)seconds {
    [self orderFront:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self dismiss];
    });
}

- (void)dismiss {
    if (self.dismissed) {
        return;
    }
    self.dismissed = YES;
    [NSAnimationContext
        runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.25;
            self.animator.alphaValue = 0;
        }
        completionHandler:^{
            [self orderOut:nil];
        }];
}

@end
