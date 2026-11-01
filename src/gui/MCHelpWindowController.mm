#import "MCHelpWindowController.h"

namespace {

struct Topic {
    NSString *file;
    NSString *title;
};

const Topic kTopics[] = {
    {@"getting-started", @"Getting Started"},
    {@"storage-cleaner", @"Storage Cleaner"},
    {@"large-files", @"Large Files"},
    {@"photo-cleaner", @"Photo Cleaner"},
    {@"file-organizer", @"File Organizer"},
    {@"updater", @"Updater"},
    {@"uninstaller", @"Uninstaller"},
    {@"performance", @"Performance"},
    {@"antivirus", @"Antivirus"},
    {@"safety", @"Safety"},
    {@"full-disk-access", @"Full Disk Access"},
    {@"command-line", @"Command Line"},
};
constexpr NSInteger kTopicCount = sizeof(kTopics) / sizeof(kTopics[0]);

} // namespace

@interface MCHelpWindowController () <NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic, strong) NSTableView *topicTable;
@property(nonatomic, strong) NSTextView *textView;
@end

@implementation MCHelpWindowController

+ (instancetype)shared {
    static MCHelpWindowController *shared;
    if (shared == nil) {
        shared = [[MCHelpWindowController alloc] init];
    }
    return shared;
}

+ (NSAttributedString *)attributedStringForHTMLAtPath:(NSString *)path {
    NSData *data = path != nil ? [NSData dataWithContentsOfFile:path] : nil;
    NSMutableAttributedString *text =
        data != nil ? [[NSMutableAttributedString alloc] initWithHTML:data documentAttributes:nil] : nil;
    if (text == nil) {
        return [[NSAttributedString alloc]
            initWithString:@"This page is missing."
                attributes:@{ NSForegroundColorAttributeName : NSColor.secondaryLabelColor,
                              NSFontAttributeName : [NSFont systemFontOfSize:NSFont.systemFontSize] }];
    }
    // The HTML importer bakes in black text; label color follows dark mode.
    [text addAttribute:NSForegroundColorAttributeName value:NSColor.labelColor range:NSMakeRange(0, text.length)];
    // It also writes each list marker into the text ("\t•\t") and attaches an
    // NSTextList, which newer text views draw again: keep only the text one.
    [text enumerateAttribute:NSParagraphStyleAttributeName
                     inRange:NSMakeRange(0, text.length)
                     options:0
                  usingBlock:^(NSParagraphStyle *style, NSRange range, BOOL *) {
                      if (style.textLists.count > 0) {
                          NSMutableParagraphStyle *plain = [style mutableCopy];
                          plain.textLists = @[];
                          [text addAttribute:NSParagraphStyleAttributeName value:plain range:range];
                      }
                  }];
    return text;
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 760, 520)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                             NSWindowStyleMaskMiniaturizable |
                                                             NSWindowStyleMaskResizable
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
    window.title = @"MacCleaner Help";
    window.minSize = NSMakeSize(560, 360);
    window.releasedWhenClosed = NO;
    if ((self = [super initWithWindow:window])) {
        [self buildContent];
        [window center];
        [self.topicTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    }
    return self;
}

- (void)buildContent {
    self.topicTable = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.topicTable.headerView = nil;
    self.topicTable.style = NSTableViewStyleSourceList;
    self.topicTable.allowsEmptySelection = NO;
    self.topicTable.rowHeight = 26;
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"topic"];
    column.resizingMask = NSTableColumnAutoresizingMask;
    [self.topicTable addTableColumn:column];
    // The one column follows the sidebar's width, or titles truncate at 100 pt.
    self.topicTable.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
    self.topicTable.dataSource = self;
    self.topicTable.delegate = self;
    NSScrollView *topics = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 200, 520)];
    topics.documentView = self.topicTable;
    topics.drawsBackground = NO;

    NSScrollView *page = [NSTextView scrollableTextView];
    self.textView = (NSTextView *)page.documentView;
    self.textView.editable = NO;
    self.textView.textContainerInset = NSMakeSize(20, 16);

    NSViewController *side = [[NSViewController alloc] init];
    side.view = topics;
    NSViewController *main = [[NSViewController alloc] init];
    main.view = page;
    NSSplitViewController *split = [[NSSplitViewController alloc] init];
    NSSplitViewItem *sideItem = [NSSplitViewItem sidebarWithViewController:side];
    sideItem.minimumThickness = 180;
    sideItem.maximumThickness = 240;
    sideItem.canCollapse = NO;
    [split addSplitViewItem:sideItem];
    [split addSplitViewItem:[NSSplitViewItem splitViewItemWithViewController:main]];
    self.window.contentViewController = split;
}

- (void)showTopic:(NSString *)topic {
    for (NSInteger i = 0; topic != nil && i < kTopicCount; ++i) {
        if ([kTopics[i].file isEqualToString:topic]) {
            [self.topicTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)i] byExtendingSelection:NO];
        }
    }
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return kTopicCount;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSTextField *label = [tableView makeViewWithIdentifier:@"topicCell" owner:self];
    if (label == nil) {
        label = [NSTextField labelWithString:@""];
        label.identifier = @"topicCell";
        label.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    label.stringValue = kTopics[row].title;
    return label;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    const NSInteger row = self.topicTable.selectedRow;
    if (row < 0) {
        return;
    }
    NSString *path = [NSBundle.mainBundle pathForResource:kTopics[row].file ofType:@"html" inDirectory:@"Help"];
    [self.textView.textStorage setAttributedString:[MCHelpWindowController attributedStringForHTMLAtPath:path]];
    [self.textView scrollPoint:NSZeroPoint];
}

@end
