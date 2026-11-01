#import "MCAboutWindowController.h"

#import "MCSettings.h"

static NSString *const kRepositoryURL = @"https://github.com/ecucuk/MacCleanerTools";

static NSString *licenseText(void) {
    NSString *path = [NSBundle.mainBundle pathForResource:@"LICENSE" ofType:nil];
    NSString *text = path != nil ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
    return text != nil ? text : @"MIT License";
}

// "Copyright (c) 2026 …" — the third line of the MIT text.
static NSString *copyrightLine(void) {
    for (NSString *line in [licenseText() componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"Copyright"]) {
            return line;
        }
    }
    return @"";
}

// A read-only, scrollable text block for an alert's accessory view.
static NSScrollView *textBlock(NSString *text) {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 440, 220)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    NSTextView *view = [[NSTextView alloc] initWithFrame:scroll.bounds];
    view.editable = NO;
    view.string = text;
    view.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    view.textContainerInset = NSMakeSize(6, 6);
    view.autoresizingMask = NSViewWidthSizable;
    scroll.documentView = view;
    return scroll;
}

@implementation MCAboutWindowController

+ (instancetype)shared {
    static MCAboutWindowController *shared;
    if (shared == nil) {
        shared = [[MCAboutWindowController alloc] init];
    }
    return shared;
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 320, 300)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                             NSWindowStyleMaskFullSizeContentView
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
    window.titlebarAppearsTransparent = YES;
    window.titleVisibility = NSWindowTitleHidden;
    window.releasedWhenClosed = NO;
    window.title = @"About MacCleaner";
    if ((self = [super initWithWindow:window])) {
        [self buildContent];
        [window center];
    }
    return self;
}

- (void)buildContent {
    NSImageView *icon = [NSImageView imageViewWithImage:NSApp.applicationIconImage];
    [icon.widthAnchor constraintEqualToConstant:96].active = YES;
    [icon.heightAnchor constraintEqualToConstant:96].active = YES;

    NSTextField *name = [NSTextField labelWithString:@"MacCleaner"];
    name.font = [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];

    NSString *build = NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"];
    NSTextField *version = [NSTextField
        labelWithString:[NSString stringWithFormat:@"Version %@ (%@)", MCSettings.appVersion, build != nil ? build : @"0"]];
    version.textColor = NSColor.secondaryLabelColor;
    version.selectable = YES; // for bug reports

    NSTextField *copyright = [NSTextField labelWithString:copyrightLine()];
    copyright.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    copyright.textColor = NSColor.secondaryLabelColor;

    NSStackView *buttons = [NSStackView stackViewWithViews:@[
        [NSButton buttonWithTitle:@"GitHub" target:self action:@selector(openRepository:)],
        [NSButton buttonWithTitle:@"License" target:self action:@selector(showLicense:)],
        [NSButton buttonWithTitle:@"Acknowledgements" target:self action:@selector(showAcknowledgements:)],
    ]];
    buttons.spacing = 8;

    NSStackView *stack = [NSStackView stackViewWithViews:@[ icon, name, version, copyright, buttons ]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 8;
    [stack setCustomSpacing:16 afterView:copyright];
    stack.edgeInsets = NSEdgeInsetsMake(36, 24, 20, 24);
    self.window.contentView = stack;
}

- (void)openRepository:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:kRepositoryURL]];
}

- (void)showLicense:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"MIT License";
    alert.accessoryView = textBlock(licenseText());
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

- (void)showAcknowledgements:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Acknowledgements";
    alert.informativeText = @"MacCleaner contains no third-party code. It is built on Apple system frameworks: "
                            @"AppKit, Foundation, SwiftUI, Quick Look, Vision, Photos, ImageIO, Core Graphics, "
                            @"AVFoundation, MapKit, Core Location, Security and IOKit.";
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

@end
