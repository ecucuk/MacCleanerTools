#import "MCWelcomeWindowController.h"

#import "MCFullDiskAccess.h"
#import "MCHelpWindowController.h"
#import "MCSettings.h"
#import "MCTheme.h"

namespace {

struct TourTool {
    MCTool tool;
    NSString *symbol;
    NSString *line;
};

const TourTool kTourTools[] = {
    {MCToolCleaner, @"trash", @"Storage Cleaner — caches, logs and developer junk"},
    {MCToolLargeFiles, @"doc.text.magnifyingglass", @"Large Files — the biggest files, with Quick Look"},
    {MCToolPhotos, @"photo.on.rectangle.angled", @"Photo Cleaner — duplicate and blurry photos"},
    {MCToolOrganizer, @"folder.badge.gearshape", @"File Organizer — sort a folder by type or place"},
    {MCToolUpdater, @"arrow.triangle.2.circlepath", @"Updater — outdated apps in one list"},
    {MCToolUninstaller, @"trash.square", @"Uninstaller — an app and its leftovers"},
    {MCToolPerformance, @"gauge.with.needle", @"Performance — processes and Optimize"},
    {MCToolAntivirus, @"shield.lefthalf.filled", @"Antivirus — an on-demand malware scan"},
};

NSTextField *bodyText(NSString *text) {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.preferredMaxLayoutWidth = 460;
    label.font = [NSFont systemFontOfSize:13];
    return label;
}

NSView *page(NSString *symbol, MCTool tool, NSString *title, NSArray<NSView *> *content) {
    NSImageView *badge = [NSImageView imageViewWithImage:[MCTheme badgeWithSymbol:symbol size:56 tool:tool]];
    NSTextField *heading = [NSTextField labelWithString:title];
    heading.font = [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold];
    NSStackView *stack = [NSStackView stackViewWithViews:[@[ badge, heading ] arrayByAddingObjectsFromArray:content]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 12;
    [stack setCustomSpacing:18 afterView:heading];
    return stack;
}

} // namespace

@interface MCWelcomeWindowController ()
@property(nonatomic, copy) NSArray<NSView *> *pages;
@property(nonatomic) NSInteger index;
@property(nonatomic, strong) NSView *pageHost;
@property(nonatomic, strong) NSTextField *dots;
@property(nonatomic, strong) NSButton *backButton;
@property(nonatomic, strong) NSButton *nextButton;
@end

@implementation MCWelcomeWindowController

+ (instancetype)shared {
    static MCWelcomeWindowController *shared;
    if (shared == nil) {
        shared = [[MCWelcomeWindowController alloc] init];
    }
    return shared;
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 580, 480)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                             NSWindowStyleMaskFullSizeContentView
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
    window.titlebarAppearsTransparent = YES;
    window.titleVisibility = NSWindowTitleHidden;
    window.releasedWhenClosed = NO;
    if ((self = [super initWithWindow:window])) {
        [self buildChrome];
    }
    return self;
}

- (void)buildChrome {
    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 580, 480)];
    self.pageHost = [[NSView alloc] initWithFrame:NSZeroRect];
    self.dots = [NSTextField labelWithString:@""];
    self.dots.textColor = NSColor.tertiaryLabelColor;
    self.backButton = [NSButton buttonWithTitle:@"Back" target:self action:@selector(back:)];
    self.nextButton = [NSButton buttonWithTitle:@"Next" target:self action:@selector(next:)];
    self.nextButton.keyEquivalent = @"\r";
    for (NSView *view in @[ self.pageHost, self.dots, self.backButton, self.nextButton ]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [self.pageHost.topAnchor constraintEqualToAnchor:content.topAnchor constant:40],
        [self.pageHost.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:40],
        [self.pageHost.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-40],
        [self.pageHost.bottomAnchor constraintEqualToAnchor:self.nextButton.topAnchor constant:-20],
        [self.nextButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [self.nextButton.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-20],
        [self.backButton.trailingAnchor constraintEqualToAnchor:self.nextButton.leadingAnchor constant:-8],
        [self.backButton.centerYAnchor constraintEqualToAnchor:self.nextButton.centerYAnchor],
        [self.dots.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
        [self.dots.centerYAnchor constraintEqualToAnchor:self.nextButton.centerYAnchor],
    ]];
    self.window.contentView = content;
}

- (NSArray<NSView *> *)tourPages {
    NSMutableArray<NSView *> *toolRows = [NSMutableArray array];
    for (const TourTool &tool : kTourTools) {
        NSImageView *icon = [NSImageView imageViewWithImage:[MCTheme badgeWithSymbol:tool.symbol size:20 tool:tool.tool]];
        NSStackView *row = [NSStackView stackViewWithViews:@[ icon, [NSTextField labelWithString:tool.line] ]];
        row.spacing = 8;
        [toolRows addObject:row];
    }
    NSStackView *toolList = [NSStackView stackViewWithViews:toolRows];
    toolList.orientation = NSUserInterfaceLayoutOrientationVertical;
    toolList.alignment = NSLayoutAttributeLeading;
    toolList.spacing = 6;

    NSButton *fdaButton = [NSButton buttonWithTitle:@"Open System Settings" target:MCFullDiskAccess.class
                                             action:@selector(openSystemSettings)];
    return @[
        page(@"sparkles", MCToolHome, @"Welcome to MacCleaner", @[ bodyText(
            @"MacCleaner frees disk space and memory on your Mac. This short tour shows the tools and how "
            @"MacCleaner keeps your files safe.") ]),
        page(@"square.grid.2x2", MCToolHome, @"Eight tools, one window", @[ toolList ]),
        page(@"checkmark.shield", MCToolCleaner, @"Nothing goes without your review", @[ bodyText(
            @"Every tool shows what it found before it changes anything. You choose the items. They move to the "
            @"Trash, so you can put them back. System files, other users' files and Apple's apps are never "
            @"removed.") ]),
        page(@"lock.shield", MCToolAntivirus, @"Full Disk Access", @[
            bodyText(@"macOS protects some folders, such as Mail, Safari and app containers. To clean them, turn "
                     @"on MacCleaner in System Settings › Privacy & Security › Full Disk Access. You can do this "
                     @"later from the Help menu."),
            fdaButton,
        ]),
        page(@"hand.thumbsup", MCToolPerformance, @"You're ready", @[ bodyText(
            @"Pick a tool in the sidebar or press ⌘1 to ⌘8. Help (⌘?) explains each tool, and Settings (⌘,) "
            @"holds your preferences.") ]),
    ];
}

- (NSView *)whatsNewPage {
    NSScrollView *scroll = [NSTextView scrollableTextView];
    NSTextView *text = (NSTextView *)scroll.documentView;
    text.editable = NO;
    text.drawsBackground = NO;
    scroll.drawsBackground = NO;
    NSString *path = [NSBundle.mainBundle pathForResource:@"WhatsNew" ofType:@"html"];
    [text.textStorage setAttributedString:[MCHelpWindowController attributedStringForHTMLAtPath:path]];
    return scroll;
}

- (void)showPages:(NSArray<NSView *> *)pages {
    self.pages = pages;
    self.index = 0;
    [self showCurrentPage];
    [self.window center];
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
}

- (void)showTour {
    [self showPages:self.tourPages];
}

- (void)showWhatsNew {
    [self showPages:@[ self.whatsNewPage ]];
}

- (void)showAtLaunchIfNeeded {
    NSString *version = MCSettings.appVersion;
    if (!MCSettings.welcomeShown) {
        MCSettings.welcomeShown = YES;
        MCSettings.lastSeenVersion = version; // the tour covers this version
        [self showTour];
    } else if (![MCSettings.lastSeenVersion isEqualToString:version]) {
        MCSettings.lastSeenVersion = version;
        [self showWhatsNew];
    }
}

- (void)showCurrentPage {
    for (NSView *view in self.pageHost.subviews.copy) {
        [view removeFromSuperview];
    }
    NSView *view = self.pages[(NSUInteger)self.index];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.pageHost addSubview:view];
    const BOOL scrolls = [view isKindOfClass:NSScrollView.class];
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:self.pageHost.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:self.pageHost.trailingAnchor],
        [view.topAnchor constraintEqualToAnchor:self.pageHost.topAnchor],
        scrolls ? [view.bottomAnchor constraintEqualToAnchor:self.pageHost.bottomAnchor]
                : [view.bottomAnchor constraintLessThanOrEqualToAnchor:self.pageHost.bottomAnchor],
    ]];

    const NSInteger count = (NSInteger)self.pages.count;
    NSMutableString *dots = [NSMutableString string];
    for (NSInteger i = 0; count > 1 && i < count; ++i) {
        [dots appendString:i == self.index ? @"● " : @"○ "];
    }
    self.dots.stringValue = dots;
    self.backButton.hidden = self.index == 0;
    self.nextButton.title = self.index == count - 1 ? @"Done" : @"Next";
}

- (void)back:(id)sender {
    if (self.index > 0) {
        self.index -= 1;
        [self showCurrentPage];
    }
}

- (void)next:(id)sender {
    if (self.index < (NSInteger)self.pages.count - 1) {
        self.index += 1;
        [self showCurrentPage];
    } else {
        [self close];
    }
}

@end
