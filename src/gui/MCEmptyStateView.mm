#import "MCEmptyStateView.h"

#import <AVFoundation/AVFoundation.h>

#import "MCTheme.h"

namespace {
constexpr CGFloat kArtHeight = 120;
} // namespace

@interface MCEmptyStateView ()
@property(nonatomic, copy) NSString *illustration;
@property(nonatomic, strong) NSImageView *imageView;
@property(nonatomic, strong) NSView *videoView;
@property(nonatomic, strong) NSTextField *label;
@property(nonatomic, strong, nullable) AVQueuePlayer *player;
@property(nonatomic, strong, nullable) AVPlayerLooper *looper;
@end

@implementation MCEmptyStateView

- (NSView *)wrapCard:(NSScrollView *)card {
    // A sibling of the card in a plain view, not a subview of the scroll
    // view: NSScrollView tiles its subviews by frame and leaves constraints
    // pinned to it unresolved.
    NSView *container = [[NSView alloc] initWithFrame:NSZeroRect];
    container.translatesAutoresizingMaskIntoConstraints = card.translatesAutoresizingMaskIntoConstraints;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:card];
    [container addSubview:self];
    for (NSView *view in @[ card, self ]) {
        [NSLayoutConstraint activateConstraints:@[
            [view.topAnchor constraintEqualToAnchor:container.topAnchor],
            [view.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
            [view.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
            [view.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        ]];
    }
    return container;
}

- (instancetype)initWithIllustration:(NSString *)illustration {
    if ((self = [super initWithFrame:NSZeroRect])) {
        _illustration = [illustration copy];
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.hidden = YES;
        // Same rounded card as the list it covers.
        self.wantsLayer = YES;
        self.layer.cornerRadius = 10;
        self.layer.masksToBounds = YES;

        _imageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
        _imageView.imageScaling = NSImageScaleProportionallyDown;

        // Layer-hosting view for the clip; created now, loaded on first scan.
        _videoView = [[NSView alloc] initWithFrame:NSZeroRect];
        _videoView.layer = [AVPlayerLayer layer];
        _videoView.wantsLayer = YES;

        _label = [NSTextField wrappingLabelWithString:@""];
        _label.alignment = NSTextAlignmentCenter;
        _label.textColor = NSColor.secondaryLabelColor;
        _label.preferredMaxLayoutWidth = 280;

        NSStackView *stack = [NSStackView stackViewWithViews:@[ _imageView, _videoView, _label ]];
        stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        stack.alignment = NSLayoutAttributeCenterX;
        stack.spacing = 14;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:stack];

        [NSLayoutConstraint activateConstraints:@[
            [_imageView.heightAnchor constraintEqualToConstant:kArtHeight],
            [_imageView.widthAnchor constraintEqualToConstant:kArtHeight * 1.5],
            [_videoView.heightAnchor constraintEqualToConstant:kArtHeight],
            [_videoView.widthAnchor constraintEqualToConstant:kArtHeight],
            [stack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:16],
            [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-16],
        ]];
    }
    return self;
}

- (BOOL)isOpaque {
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    // The card's own surface, so the overlay reads as the list being empty.
    [NSColor.controlBackgroundColor setFill];
    NSRectFill(dirtyRect);
}

- (void)showIllustrationWithMessage:(NSString *)message {
    [self.player pause];
    if (self.imageView.image == nil) {
        self.imageView.image = [MCTheme illustrationNamed:self.illustration];
    }
    self.imageView.hidden = self.imageView.image == nil;
    self.videoView.hidden = YES;
    self.label.stringValue = message;
    self.hidden = NO;
}

- (void)showScanningWithMessage:(NSString *)message {
    if (self.player == nil) {
        NSURL *url = [NSBundle.mainBundle URLForResource:@"scan" withExtension:@"mov"];
        if (url != nil) {
            self.player = [[AVQueuePlayer alloc] init];
            self.player.muted = YES;
            self.looper = [AVPlayerLooper playerLooperWithPlayer:self.player
                                                    templateItem:[AVPlayerItem playerItemWithURL:url]];
            AVPlayerLayer *layer = (AVPlayerLayer *)self.videoView.layer;
            // HEVC with alpha only stays transparent in a format that has alpha.
            layer.pixelBufferAttributes = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)};
            layer.player = self.player;
        }
    }
    self.imageView.hidden = YES;
    self.videoView.hidden = self.player == nil;
    // Reduce Motion: the first frame stands still instead of looping.
    if (!NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) {
        [self.player play];
    }
    self.label.stringValue = message;
    self.hidden = NO;
}

- (void)hide {
    [self.player pause];
    self.hidden = YES;
}

@end
