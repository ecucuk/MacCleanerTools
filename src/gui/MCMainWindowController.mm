#import "MCMainWindowController.h"

#import "MCCleanerViewController.h"
#import "MCLargeFilesViewController.h"

#pragma mark - Tool registry

/// One row in the sidebar. The view controller is created lazily on first
/// selection so tools the user never opens cost nothing.
@interface MCToolEntry : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *symbolName;
@property(nonatomic, copy) NSViewController * (^make)(void);
@property(nonatomic, strong, nullable) NSViewController *controller;
@end

@implementation MCToolEntry
@end

#pragma mark - Sidebar

@protocol MCToolSidebarDelegate <NSObject>
- (void)sidebarDidSelectToolAtIndex:(NSInteger)index;
@end

/// The source list. A plain table view -- two-level outlines and section
/// headers can come when the tool count justifies them.
@interface MCToolSidebarController : NSViewController <NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic, weak) id<MCToolSidebarDelegate> delegate;
@property(nonatomic, copy) NSArray<MCToolEntry *> *tools;
@property(nonatomic, strong) NSTableView *tableView;
@end

@implementation MCToolSidebarController

- (void)loadView {
    self.tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.headerView = nil;
    self.tableView.style = NSTableViewStyleSourceList;
    self.tableView.rowHeight = 28;
    self.tableView.allowsEmptySelection = NO;

    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"tool"];
    [self.tableView addTableColumn:column];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 200, 400)];
    scroll.documentView = self.tableView;
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = NO;
    self.view = scroll;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.tools.count;
}

- (NSView *)tableView:(NSTableView *)tableView
    viewForTableColumn:(NSTableColumn *)tableColumn
                    row:(NSInteger)row {
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"toolCell" owner:self];
    if (cell == nil) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = @"toolCell";

        NSImageView *icon = [[NSImageView alloc] initWithFrame:NSZeroRect];
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:icon];
        cell.imageView = icon;

        NSTextField *label = [NSTextField labelWithString:@""];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview:label];
        cell.textField = label;

        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
            [icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:18],
            [icon.heightAnchor constraintEqualToConstant:18],
            [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:6],
            [label.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
            [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }

    MCToolEntry *tool = self.tools[(NSUInteger)row];
    cell.textField.stringValue = tool.title;
    cell.imageView.image = [NSImage imageWithSystemSymbolName:tool.symbolName
                                      accessibilityDescription:tool.title];
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    const NSInteger row = self.tableView.selectedRow;
    if (row >= 0) {
        [self.delegate sidebarDidSelectToolAtIndex:row];
    }
}

@end

#pragma mark - Shell

@interface MCMainWindowController () <MCToolSidebarDelegate, NSWindowDelegate>
@property(nonatomic, strong) MCToolSidebarController *sidebar;
@property(nonatomic, strong) NSViewController *contentHost; // swaps tool views
@property(nonatomic, copy) NSArray<MCToolEntry *> *tools;
@property(nonatomic, strong, nullable) NSViewController *currentTool;
@property(nonatomic) BOOL initialScanStarted;
@end

@implementation MCMainWindowController

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 920, 560)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"MacCleaner";
    window.minSize = NSMakeSize(760, 420);
    [window center];

    if ((self = [super initWithWindow:window])) {
        window.delegate = self;
        MCToolEntry *cleaner = [[MCToolEntry alloc] init];
        cleaner.title = @"Storage Cleaner";
        cleaner.symbolName = @"trash";
        cleaner.make = ^{ return (NSViewController *)[[MCCleanerViewController alloc] init]; };

        MCToolEntry *largeFiles = [[MCToolEntry alloc] init];
        largeFiles.title = @"Large Files";
        largeFiles.symbolName = @"doc.text.magnifyingglass";
        largeFiles.make = ^{ return (NSViewController *)[[MCLargeFilesViewController alloc] init]; };

        _tools = @[ cleaner, largeFiles ];

        _sidebar = [[MCToolSidebarController alloc] init];
        _sidebar.tools = _tools;
        _sidebar.delegate = self;

        _contentHost = [[NSViewController alloc] init];
        _contentHost.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 720, 560)];

        NSSplitViewController *split = [[NSSplitViewController alloc] init];
        NSSplitViewItem *side = [NSSplitViewItem sidebarWithViewController:_sidebar];
        side.minimumThickness = 150;
        side.maximumThickness = 240;
        // The sidebar is the tool switcher; collapsing it would strand the
        // user in whatever tool happened to be open.
        side.canCollapse = NO;
        [split addSplitViewItem:side];
        [split addSplitViewItem:[NSSplitViewItem splitViewItemWithViewController:_contentHost]];
        window.contentViewController = split;

        [self selectToolAtIndex:0];
    }
    return self;
}

- (void)startInitialScan {
    // Reaches the cleaner only if it is still the selected tool by the time
    // the app delegate calls this; switching first and scanning later would
    // surprise whoever is already using another tool.
    if ([self.currentTool isKindOfClass:[MCCleanerViewController class]] && !self.initialScanStarted) {
        self.initialScanStarted = YES;
        [(MCCleanerViewController *)self.currentTool startInitialScan];
    }
}

#pragma mark NSWindowDelegate

// The shell window *is* the app: the satellite windows (Activity, the Quick
// Look panel) have no life of their own, so closing the main window
// terminates cleanly instead of leaving a windowless-but-running app behind
// an orphaned Activity window. terminate: closes every remaining window on
// the way out; if termination was what triggered this close (Cmd-Q), the
// extra terminate: is a no-op.
- (void)windowWillClose:(NSNotification *)notification {
    [NSApp terminate:nil];
}

#pragma mark MCToolSidebarDelegate

- (void)sidebarDidSelectToolAtIndex:(NSInteger)index {
    [self selectToolAtIndex:index];
}

- (void)selectToolAtIndex:(NSInteger)index {
    if (index < 0 || (NSUInteger)index >= self.tools.count) {
        return;
    }
    MCToolEntry *tool = self.tools[(NSUInteger)index];
    if (tool.controller == nil) {
        tool.controller = tool.make();
    }
    if (self.currentTool == tool.controller) {
        return;
    }

    if (self.currentTool != nil) {
        [self.currentTool.view removeFromSuperview];
        [self.currentTool removeFromParentViewController];
    }

    self.currentTool = tool.controller;
    [self.contentHost addChildViewController:tool.controller];
    NSView *toolView = tool.controller.view;
    toolView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentHost.view addSubview:toolView];
    [NSLayoutConstraint activateConstraints:@[
        [toolView.topAnchor constraintEqualToAnchor:self.contentHost.view.topAnchor],
        [toolView.bottomAnchor constraintEqualToAnchor:self.contentHost.view.bottomAnchor],
        [toolView.leadingAnchor constraintEqualToAnchor:self.contentHost.view.leadingAnchor],
        [toolView.trailingAnchor constraintEqualToAnchor:self.contentHost.view.trailingAnchor],
    ]];

    self.window.title = [NSString stringWithFormat:@"MacCleaner — %@", tool.title];
}

@end
