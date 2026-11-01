#import "MCLargeFilesViewController.h"

#import "MCBigFilesModel.h"
#import "MCHeroView.h"
#import "MCSettings.h"
#import "MCTheme.h"
#import "MCToolBanner.h"

// Quartz brings QLPreviewView: one view that renders what Finder's Quick
// Look renders (HEIC/RAW images, video with playback controls, audio),
// far beyond what a hand-rolled NSImageView + AVPlayerView pair would cover.
#import <Quartz/Quartz.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "maccleaner/format.hpp"

namespace {

NSString *humanSize(unsigned long long bytes) {
    // Same formatter as the CLI and the cleaner, so every surface agrees.
    return [NSString stringWithUTF8String:maccleaner::humanReadableBytes(bytes).c_str()];
}

NSString *const kSizeColumn = @"size";
NSString *const kNameColumn = @"name";
NSString *const kPathColumn = @"path";

// Threshold popup entries come from MCSettings.largeFilesChoicesMB; bytes
// are 1024-based to match humanSize output.
NSString *thresholdText(NSInteger megabytes) {
    return [[MCSettings labelForMegabytes:megabytes] stringByReplacingOccurrencesOfString:@"≥ " withString:@""];
}
constexpr NSUInteger kMaxResults = 200;

} // namespace

/// Space toggles the Quick Look panel, exactly like Finder. The table only
/// forwards the intent up the responder chain -- the view controller owns the
/// panel handshake -- so this stays a dumb view.
@interface MCQuickLookTableView : NSTableView
@end

@implementation MCQuickLookTableView

- (void)keyDown:(NSEvent *)event {
    NSString *chars = event.charactersIgnoringModifiers;
    if (chars.length == 1 && [chars characterAtIndex:0] == ' ' &&
        (event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask) == 0) {
        [NSApp sendAction:@selector(togglePreviewPanel:) to:nil from:self];
        return;
    }
    [super keyDown:event];
}

@end

@interface MCLargeFilesViewController () <NSTableViewDataSource, NSTableViewDelegate,
                                           QLPreviewPanelDataSource, QLPreviewPanelDelegate>

@property(nonatomic, strong) MCBigFilesModel *model;
@property(nonatomic, copy) NSArray<MCBigFileItem *> *items;
@property(nonatomic, copy) NSString *scanRoot;      // the root of the *displayed* results
@property(nonatomic, copy) NSString *pendingRoot;   // what the picker shows / next scan uses

// Live scan state, composed into one status line by -refreshScanStatus so
// the walk-progress and found-files callbacks don't fight over the label.
@property(nonatomic) uint64_t scanVisited;
@property(nonatomic, copy, nullable) NSString *scanCurrentDir;

@property(nonatomic, strong) NSTextField *rootLabel;
@property(nonatomic, strong) NSPopUpButton *thresholdPopUp;
@property(nonatomic) NSInteger appliedDefaultMB; // the Settings default last put in the popup
@property(nonatomic, strong) NSButton *chooseButton;
@property(nonatomic, strong) NSButton *scanButton;
@property(nonatomic, strong) NSProgressIndicator *spinner;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSTableView *tableView;
@property(nonatomic, strong) NSButton *quickLookButton;
@property(nonatomic, strong) NSButton *revealButton;
@property(nonatomic, strong) NSButton *trashButton;

// Preview pane: Quick Look for media/photo selections, a placeholder
// (icon + caption) for everything else.
@property(nonatomic, strong) QLPreviewView *previewView;
@property(nonatomic, strong) MCHeroView *hero;
@property(nonatomic, strong) MCToolBanner *banner;
@property(nonatomic) BOOL hasScanned;
@property(nonatomic, strong) NSStackView *placeholderStack;
@property(nonatomic, strong) NSImageView *placeholderIcon;
@property(nonatomic, strong) NSTextField *placeholderLabel;
@property(nonatomic, copy, nullable) NSString *previewedPath;

@end

@implementation MCLargeFilesViewController

- (instancetype)init {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _model = [[MCBigFilesModel alloc] init];
        _items = @[];
        _pendingRoot = NSHomeDirectory();
    }
    return self;
}

#pragma mark - Layout

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 720, 560)];

    // --- top bar: root picker + threshold + scan -------------------------
    self.rootLabel = [NSTextField labelWithString:[self displayPath:self.pendingRoot]];
    self.rootLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.rootLabel.toolTip = self.pendingRoot;
    [self.rootLabel setContentHuggingPriority:NSLayoutPriorityDefaultLow
                                forOrientation:NSLayoutConstraintOrientationHorizontal];
    // Compressible, so a deep path truncates in the middle instead of forcing
    // the window wider -- Auto Layout grows the *window* to satisfy a label's
    // intrinsic width if nothing in the chain may compress.
    [self.rootLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                              forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.chooseButton = [NSButton buttonWithTitle:@"Choose…" target:self action:@selector(chooseRoot:)];
    self.chooseButton.bezelStyle = NSBezelStyleRounded;

    self.thresholdPopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (NSNumber *megabytes in MCSettings.largeFilesChoicesMB) {
        [self.thresholdPopUp addItemWithTitle:[MCSettings labelForMegabytes:megabytes.integerValue]];
        self.thresholdPopUp.lastItem.tag = megabytes.integerValue;
    }
    self.appliedDefaultMB = MCSettings.largeFilesMinSizeMB;
    [self.thresholdPopUp selectItemWithTag:self.appliedDefaultMB];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(settingsDidChange:)
                                               name:MCSettingsDidChangeNotification
                                             object:nil];

    self.scanButton = [MCGlassButton buttonWithTitle:@"Scan" style:MCGlassButtonStylePillPrimary
                                                tool:MCToolLargeFiles target:self action:@selector(scanOrCancel:)];
    self.scanButton.keyEquivalent = @"\r";

    self.spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.controlSize = NSControlSizeSmall;
    self.spinner.displayedWhenStopped = NO;

    NSStackView *topBar = [NSStackView stackViewWithViews:@[
        self.rootLabel, self.chooseButton, self.thresholdPopUp, self.spinner
    ]];
    topBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    topBar.spacing = 8;
    topBar.translatesAutoresizingMaskIntoConstraints = NO;

    // --- table -----------------------------------------------------------
    self.tableView = [[MCQuickLookTableView alloc] initWithFrame:NSZeroRect];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.allowsMultipleSelection = YES;
    self.tableView.doubleAction = @selector(revealSelection:);
    self.tableView.target = self;

    NSTableColumn *sizeColumn = [[NSTableColumn alloc] initWithIdentifier:kSizeColumn];
    sizeColumn.title = @"Size";
    sizeColumn.width = 90;
    sizeColumn.minWidth = 70;
    [self.tableView addTableColumn:sizeColumn];

    NSTableColumn *nameColumn = [[NSTableColumn alloc] initWithIdentifier:kNameColumn];
    nameColumn.title = @"Name";
    nameColumn.width = 220;
    nameColumn.minWidth = 120;
    [self.tableView addTableColumn:nameColumn];

    NSTableColumn *pathColumn = [[NSTableColumn alloc] initWithIdentifier:kPathColumn];
    pathColumn.title = @"Location";
    pathColumn.width = 330;
    pathColumn.minWidth = 160;
    [self.tableView addTableColumn:pathColumn];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.documentView = self.tableView;
    scrollView.hasVerticalScroller = YES;
    scrollView.autohidesScrollers = YES;
    [MCTheme styleCard:scrollView];
    NSView *card = scrollView;

    // --- preview pane ----------------------------------------------------
    self.previewView = [[QLPreviewView alloc] initWithFrame:NSZeroRect
                                                       style:QLPreviewViewStyleNormal];
    self.previewView.translatesAutoresizingMaskIntoConstraints = NO;
    self.previewView.hidden = YES;

    self.placeholderIcon = [[NSImageView alloc] initWithFrame:NSZeroRect];
    self.placeholderIcon.translatesAutoresizingMaskIntoConstraints = NO;
    self.placeholderIcon.image = [NSImage imageWithSystemSymbolName:@"photo.on.rectangle.angled"
                                            accessibilityDescription:@"No preview"];
    self.placeholderIcon.symbolConfiguration =
        [NSImageSymbolConfiguration configurationWithPointSize:44 weight:NSFontWeightLight];
    self.placeholderIcon.contentTintColor = NSColor.tertiaryLabelColor;

    self.placeholderLabel = [NSTextField wrappingLabelWithString:@"Select a media or photo file to preview it."];
    self.placeholderLabel.alignment = NSTextAlignmentCenter;
    self.placeholderLabel.textColor = NSColor.secondaryLabelColor;
    self.placeholderLabel.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    // A long filename in the placeholder must wrap inside the pane, never
    // stretch the pane (and with it the window) to the text's full width.
    self.placeholderLabel.preferredMaxLayoutWidth = 176;
    self.placeholderLabel.maximumNumberOfLines = 4;
    self.placeholderLabel.cell.truncatesLastVisibleLine = YES;
    [self.placeholderLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                     forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.placeholderStack = [NSStackView stackViewWithViews:@[ self.placeholderIcon, self.placeholderLabel ]];
    self.placeholderStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.placeholderStack.alignment = NSLayoutAttributeCenterX;
    self.placeholderStack.spacing = 10;
    self.placeholderStack.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *previewContainer = [[NSView alloc] initWithFrame:NSZeroRect];
    [previewContainer addSubview:self.previewView];
    [previewContainer addSubview:self.placeholderStack];
    [NSLayoutConstraint activateConstraints:@[
        [self.previewView.topAnchor constraintEqualToAnchor:previewContainer.topAnchor],
        [self.previewView.bottomAnchor constraintEqualToAnchor:previewContainer.bottomAnchor],
        [self.previewView.leadingAnchor constraintEqualToAnchor:previewContainer.leadingAnchor],
        [self.previewView.trailingAnchor constraintEqualToAnchor:previewContainer.trailingAnchor],
        [self.placeholderStack.centerXAnchor constraintEqualToAnchor:previewContainer.centerXAnchor],
        [self.placeholderStack.centerYAnchor constraintEqualToAnchor:previewContainer.centerYAnchor],
        [self.placeholderStack.leadingAnchor
            constraintGreaterThanOrEqualToAnchor:previewContainer.leadingAnchor constant:12],
        [self.placeholderStack.trailingAnchor
            constraintLessThanOrEqualToAnchor:previewContainer.trailingAnchor constant:-12],
    ]];

    NSSplitView *splitView = [[NSSplitView alloc] initWithFrame:NSZeroRect];
    splitView.vertical = YES;
    splitView.dividerStyle = NSSplitViewDividerStyleThin;
    [splitView addArrangedSubview:card];
    [splitView addArrangedSubview:previewContainer];
    // The preview holds its width; the table absorbs window resizes. The
    // divider position survives relaunches via the autosave name.
    [splitView setHoldingPriority:NSLayoutPriorityDefaultLow + 10 forSubviewAtIndex:1];
    splitView.autosaveName = @"MCLargeFilesSplit";
    splitView.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [scrollView.widthAnchor constraintGreaterThanOrEqualToConstant:320],
        [previewContainer.widthAnchor constraintGreaterThanOrEqualToConstant:200],
    ]];

    // --- bottom bar ------------------------------------------------------
    self.statusLabel = [NSTextField labelWithString:@"Choose a folder and press Scan."];
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    self.statusLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    // The scan status carries an ever-changing directory path; it must
    // truncate, not resize the window ~4x a second (see rootLabel above).
    [self.statusLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.quickLookButton = [NSButton buttonWithTitle:@"Quick Look" target:self action:@selector(togglePreviewPanel:)];
    self.quickLookButton.bezelStyle = NSBezelStyleRounded;
    self.quickLookButton.toolTip = @"Open the full Quick Look panel (Space)";
    self.quickLookButton.enabled = NO;

    self.revealButton = [NSButton buttonWithTitle:@"Reveal in Finder" target:self action:@selector(revealSelection:)];
    self.revealButton.bezelStyle = NSBezelStyleRounded;
    self.revealButton.enabled = NO;

    self.trashButton = [NSButton buttonWithTitle:@"Move to Trash…" target:self action:@selector(trashSelection:)];
    self.trashButton.bezelStyle = NSBezelStyleRounded;
    self.trashButton.enabled = NO;

    NSView *spacer = [[NSView alloc] initWithFrame:NSZeroRect];
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow
                        forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *bottomBar = [NSStackView stackViewWithViews:@[
        self.statusLabel, spacer, self.quickLookButton, self.revealButton, self.trashButton
    ]];
    bottomBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bottomBar.spacing = 8;
    bottomBar.translatesAutoresizingMaskIntoConstraints = NO;

    // --- results banner and start screen ---------------------------------
    self.banner = [[MCToolBanner alloc] initWithTool:MCToolLargeFiles symbol:@"doc.text.magnifyingglass"];
    self.banner.actions = @[ self.scanButton ];

    self.hero = [[MCHeroView alloc] initWithTool:MCToolLargeFiles
                                          symbol:@"doc.text.magnifyingglass"
                                           title:@"Large Files"
                                        subtitle:@"Find the biggest files in a folder and decide what goes."];
    self.hero.actions = @[
        [MCGlassButton buttonWithTitle:@"Scan" style:MCGlassButtonStyleRound tool:MCToolLargeFiles
                                target:self action:@selector(scanOrCancel:)],
        [MCGlassButton buttonWithTitle:@"Choose Folder…" style:MCGlassButtonStylePill tool:MCToolLargeFiles
                                target:self action:@selector(chooseRoot:)],
    ];
    self.hero.scanningAccessory = [MCGlassButton buttonWithTitle:@"Stop" style:MCGlassButtonStylePill
                                                            tool:MCToolLargeFiles target:self
                                                          action:@selector(scanOrCancel:)];

    [self.view addSubview:self.banner];
    [self.view addSubview:topBar];
    [self.view addSubview:splitView];
    [self.view addSubview:bottomBar];
    [self.view addSubview:self.hero];

    const CGFloat margin = 16;
    [NSLayoutConstraint activateConstraints:@[
        [self.banner.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.banner.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [self.banner.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],

        [topBar.topAnchor constraintEqualToAnchor:self.banner.bottomAnchor constant:12],
        [topBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [topBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],

        [splitView.topAnchor constraintEqualToAnchor:topBar.bottomAnchor constant:12],
        [splitView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [splitView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],

        [bottomBar.topAnchor constraintEqualToAnchor:splitView.bottomAnchor constant:12],
        [bottomBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [bottomBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],
        [bottomBar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-margin],

        [self.hero.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.hero.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.hero.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.hero.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    [self updatePreview];
    [self updateHero];
}

/// The start screen until a scan shows its first row. After a finished
/// scan the results stay, even when empty, so the threshold and folder
/// controls are at hand for the next try.
- (NSInteger)selectedMegabytes {
    const NSInteger tag = self.thresholdPopUp.selectedTag;
    return tag > 0 ? tag : MCSettings.largeFilesMinSizeMB;
}

// A new default in Settings applies at once, but never under a running scan.
// Other settings changes (every tool switch writes one) must not undo a
// threshold the user picked here, so act only when the default itself moved.
- (void)settingsDidChange:(NSNotification *)note {
    const NSInteger stored = MCSettings.largeFilesMinSizeMB;
    if (stored == self.appliedDefaultMB || self.model.scanning) {
        return;
    }
    self.appliedDefaultMB = stored;
    [self.thresholdPopUp selectItemWithTag:stored];
    [self updateHero];
}

- (void)updateHero {
    unsigned long long total = 0;
    for (MCBigFileItem *item in self.items) {
        total += item.sizeBytes;
    }
    NSString *threshold = thresholdText(self.selectedMegabytes);
    NSString *root = [self displayPath:self.scanRoot != nil ? self.scanRoot : self.pendingRoot];
    self.banner.value = humanSize(total);
    self.banner.caption = [NSString stringWithFormat:@"in %lu file(s) of %@ or more · %@", (unsigned long)self.items.count,
                                                     threshold, root];

    const BOOL presented = self.items.count == 0 && (self.model.scanning || !self.hasScanned);
    [self.hero setPresented:presented];
    if (!presented) {
        return;
    }
    if (self.model.scanning) {
        [self.hero showScanningWithStatus:@"Walking the folder for large files…"];
    } else {
        [self.hero showIdleWithMessage:[NSString stringWithFormat:@"Searches %@ for files of %@ or more", root,
                                                                  threshold]];
    }
}

- (void)dealloc {
    // QLPreviewView documents an explicit close to release its resources
    // (video playback in particular) when the view is going away.
    [_previewView close];
}

- (NSString *)displayPath:(NSString *)path {
    return [path stringByAbbreviatingWithTildeInPath];
}

#pragma mark - Actions

- (void)chooseRoot:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.directoryURL = [NSURL fileURLWithPath:self.pendingRoot isDirectory:YES];
    panel.prompt = @"Search Here";

    __weak MCLargeFilesViewController *weakSelf = self;
    [panel beginSheetModalForWindow:self.view.window
                  completionHandler:^(NSModalResponse response) {
                      MCLargeFilesViewController *strongSelf = weakSelf;
                      if (strongSelf == nil || response != NSModalResponseOK || panel.URLs.count == 0) {
                          return;
                      }
                      strongSelf.pendingRoot = panel.URLs.firstObject.path;
                      strongSelf.rootLabel.stringValue = [strongSelf displayPath:strongSelf.pendingRoot];
                      strongSelf.rootLabel.toolTip = strongSelf.pendingRoot;
                      [strongSelf updateHero];
                  }];
}

- (void)scanOrCancel:(id)sender {
    if (self.model.scanning) {
        [self.model cancelScan];
        self.scanButton.enabled = NO; // debounce until the completion flips the UI back
        return;
    }

    const unsigned long long minSize = (unsigned long long)self.selectedMegabytes << 20;

    NSString *root = self.pendingRoot;
    self.scanButton.title = @"Cancel";
    self.chooseButton.enabled = NO;
    self.thresholdPopUp.enabled = NO;
    [self.spinner startAnimation:nil];
    self.statusLabel.stringValue = @"Scanning…";

    // The table fills as the walk finds qualifying files; scanRoot is set up
    // front so actions on streamed rows (reveal, even trash) already have the
    // right allowlist root.
    self.scanRoot = root;
    self.items = @[];
    self.scanVisited = 0;
    self.scanCurrentDir = nil;
    [self.tableView reloadData];

    __weak MCLargeFilesViewController *weakSelf = self;
    [self.model scanUnder:root
              minSizeBytes:minSize
                maxResults:kMaxResults
                  progress:^(uint64_t visited, NSString *currentDir) {
                      MCLargeFilesViewController *strongSelf = weakSelf;
                      if (strongSelf == nil) {
                          return;
                      }
                      strongSelf.scanVisited = visited;
                      strongSelf.scanCurrentDir = currentDir;
                      [strongSelf refreshScanStatus];
                  }
             resultsUpdate:^(NSArray<MCBigFileItem *> *files) {
                 [weakSelf applyStreamedItems:files];
                 [weakSelf updateHero];
             }
                completion:^(NSArray<MCBigFileItem *> *files) {
                    MCLargeFilesViewController *strongSelf = weakSelf;
                    if (strongSelf == nil) {
                        return;
                    }
                    strongSelf.items = files;
                    strongSelf.scanRoot = root;
                    strongSelf.hasScanned = YES;
                    [strongSelf.tableView reloadData];
                    [strongSelf.spinner stopAnimation:nil];
                    strongSelf.scanButton.title = @"Scan";
                    strongSelf.scanButton.enabled = YES;
                    strongSelf.chooseButton.enabled = YES;
                    strongSelf.thresholdPopUp.enabled = YES;

                    unsigned long long total = 0;
                    for (MCBigFileItem *item in files) {
                        total += item.sizeBytes;
                    }
                    strongSelf.statusLabel.stringValue =
                        files.count == 0
                            ? @"No files at or above the threshold."
                            : [NSString stringWithFormat:@"%lu file(s) · %@ total",
                                                          (unsigned long)files.count, humanSize(total)];
                    [strongSelf updateActionButtons];
                    [strongSelf updatePreview];
                    [strongSelf updateHero];
                }];
    [self updateHero]; // after scanUnder:, so `scanning` is already set
}

/// Streams a mid-scan snapshot into the table. Selection is preserved by
/// path -- rows shift as bigger files displace smaller ones, and losing the
/// user's selection (or restarting their Quick Look preview) four times a
/// second would make the streaming worse than useless.
- (void)applyStreamedItems:(NSArray<MCBigFileItem *> *)files {
    NSMutableSet<NSString *> *selectedPaths = [NSMutableSet set];
    for (MCBigFileItem *item in [self selectedItems]) {
        [selectedPaths addObject:item.path];
    }

    self.items = files;
    [self.tableView reloadData];

    if (selectedPaths.count > 0) {
        NSMutableIndexSet *toSelect = [NSMutableIndexSet indexSet];
        [files enumerateObjectsUsingBlock:^(MCBigFileItem *item, NSUInteger index, BOOL *) {
            if ([selectedPaths containsObject:item.path]) {
                [toSelect addIndex:index];
            }
        }];
        // Re-selecting fires tableViewSelectionDidChange, which keeps the
        // inline preview and an open Quick Look panel in sync; the
        // previewedPath guard stops a playing video from restarting.
        [self.tableView selectRowIndexes:toSelect byExtendingSelection:NO];
    }

    [self refreshScanStatus];
}

- (void)refreshScanStatus {
    if (!self.model.scanning) {
        return; // completion owns the final status line
    }
    unsigned long long total = 0;
    for (MCBigFileItem *item in self.items) {
        total += item.sizeBytes;
    }
    NSString *where = self.scanCurrentDir != nil ? [self displayPath:self.scanCurrentDir] : @"";
    self.statusLabel.stringValue =
        [NSString stringWithFormat:@"Scanning… %llu entries · %lu found · %@ · %@",
                                    (unsigned long long)self.scanVisited,
                                    (unsigned long)self.items.count, humanSize(total), where];
    if (self.hero.presented) {
        [self.hero setStatus:[NSString stringWithFormat:@"%llu entries · %@", (unsigned long long)self.scanVisited,
                                                        where]];
    }
}

- (NSArray<MCBigFileItem *> *)selectedItems {
    NSMutableArray<MCBigFileItem *> *selected = [NSMutableArray array];
    [self.tableView.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *) {
        if (index < self.items.count) {
            [selected addObject:self.items[index]];
        }
    }];
    return selected;
}

- (void)revealSelection:(id)sender {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (MCBigFileItem *item in [self selectedItems]) {
        [urls addObject:[NSURL fileURLWithPath:item.path]];
    }
    if (urls.count > 0) {
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:urls];
    }
}

- (void)trashSelection:(id)sender {
    NSArray<MCBigFileItem *> *selected = [self selectedItems];
    if (selected.count == 0 || self.scanRoot == nil) {
        return;
    }

    unsigned long long total = 0;
    for (MCBigFileItem *item in selected) {
        total += item.sizeBytes;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Move the selected files to the Trash?";
    alert.informativeText = [NSString stringWithFormat:@"%lu file(s), %@.",
                                                        (unsigned long)selected.count, humanSize(total)];
    [alert addButtonWithTitle:@"Move to Trash"];
    [alert addButtonWithTitle:@"Cancel"];

    __weak MCLargeFilesViewController *weakSelf = self;
    [alert beginSheetModalForWindow:self.view.window
                  completionHandler:^(NSModalResponse response) {
                      if (response == NSAlertFirstButtonReturn) {
                          [weakSelf performTrash:selected];
                      }
                  }];
}

- (void)performTrash:(NSArray<MCBigFileItem *> *)selected {
    NSMutableArray<NSString *> *problems = [NSMutableArray array];
    NSMutableSet<NSString *> *removedPaths = [NSMutableSet set];
    unsigned long long freed = 0;

    for (MCBigFileItem *item in selected) {
        NSString *error = nil;
        if ([self.model trashItemAtPath:item.path underScanRoot:self.scanRoot error:&error]) {
            [removedPaths addObject:item.path];
            freed += item.sizeBytes;
        } else {
            [problems addObject:[NSString stringWithFormat:@"%@ — %@", item.name,
                                                            error != nil ? error : @"unknown error"]];
        }
    }

    // Drop the removed rows instead of rescanning: a whole-home walk is far
    // too expensive to repeat for a table update.
    NSMutableArray<MCBigFileItem *> *remaining = [NSMutableArray arrayWithCapacity:self.items.count];
    for (MCBigFileItem *item in self.items) {
        if (![removedPaths containsObject:item.path]) {
            [remaining addObject:item];
        }
    }
    self.items = remaining;
    [self.tableView reloadData];
    [self updateActionButtons];
    [self updateHero];
    // The previewed file may be the one just trashed; QLPreviewView keeps
    // videos open, so drop the item rather than previewing a Trash entry.
    [self updatePreview];
    [self reloadPreviewPanelIfVisible];

    if (problems.count == 0) {
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Moved %lu file(s) to Trash · freed %@",
                                                                    (unsigned long)removedPaths.count,
                                                                    humanSize(freed)];
    } else {
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Freed %@ · %lu failed", humanSize(freed),
                                                                    (unsigned long)problems.count];
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = @"Some files could not be moved to the Trash";
        alert.informativeText = [problems componentsJoinedByString:@"\n"];
        [alert addButtonWithTitle:@"OK"];
        [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
    }
}

- (void)updateActionButtons {
    const BOOL hasSelection = self.tableView.selectedRowIndexes.count > 0;
    self.quickLookButton.enabled = hasSelection;
    self.revealButton.enabled = hasSelection;
    self.trashButton.enabled = hasSelection && !self.model.scanning;
}

#pragma mark - Quick Look panel (Finder's Space behaviour)

/// Space in the table, or the Quick Look button. The shared panel asks the
/// responder chain for a controller; this VC volunteers below.
- (void)togglePreviewPanel:(id)sender {
    QLPreviewPanel *panel = [QLPreviewPanel sharedPreviewPanel];
    if ([QLPreviewPanel sharedPreviewPanelExists] && panel.isVisible) {
        [panel orderOut:nil];
    } else {
        [panel makeKeyAndOrderFront:nil];
    }
}

- (BOOL)acceptsPreviewPanelControl:(QLPreviewPanel *)panel {
    return YES;
}

- (void)beginPreviewPanelControl:(QLPreviewPanel *)panel {
    panel.dataSource = self;
    panel.delegate = self;
}

- (void)endPreviewPanelControl:(QLPreviewPanel *)panel {
    panel.dataSource = nil;
    panel.delegate = nil;
}

- (void)reloadPreviewPanelIfVisible {
    if ([QLPreviewPanel sharedPreviewPanelExists] &&
        [QLPreviewPanel sharedPreviewPanel].isVisible &&
        [QLPreviewPanel sharedPreviewPanel].dataSource == self) {
        [[QLPreviewPanel sharedPreviewPanel] reloadData];
    }
}

#pragma mark QLPreviewPanelDataSource

// The panel previews the current selection: one item selected shows that
// item; a multi-selection gets the panel's own left/right arrows. Unlike the
// inline pane there is no media gate -- Quick Look renders PDFs, archives,
// text and whatever else, exactly like Finder's Space.
- (NSInteger)numberOfPreviewItemsInPreviewPanel:(QLPreviewPanel *)panel {
    return (NSInteger)[self selectedItems].count;
}

- (id<QLPreviewItem>)previewPanel:(QLPreviewPanel *)panel previewItemAtIndex:(NSInteger)index {
    NSArray<MCBigFileItem *> *selected = [self selectedItems];
    if (index < 0 || (NSUInteger)index >= selected.count) {
        return nil;
    }
    return [NSURL fileURLWithPath:selected[(NSUInteger)index].path];
}

#pragma mark QLPreviewPanelDelegate

/// Arrow keys land on the panel while it is key; forward them to the table
/// so up/down moves the app's selection and the panel follows -- the same
/// loop Finder runs. Everything else (Space to close, Esc, pinch zoom on
/// images, the video/audio transport controls) is the panel's own.
- (BOOL)previewPanel:(QLPreviewPanel *)panel handleEvent:(NSEvent *)event {
    if (event.type == NSEventTypeKeyDown) {
        const unichar key = event.charactersIgnoringModifiers.length > 0
                                 ? [event.charactersIgnoringModifiers characterAtIndex:0]
                                 : 0;
        if (key == NSUpArrowFunctionKey || key == NSDownArrowFunctionKey) {
            [self.tableView keyDown:event];
            [panel reloadData];
            return YES;
        }
    }
    return NO;
}

/// Anchors the panel's open/close zoom animation to the previewed row.
- (NSRect)previewPanel:(QLPreviewPanel *)panel sourceFrameOnScreenForPreviewItem:(id<QLPreviewItem>)item {
    NSString *path = [(NSURL *)item path];
    const NSUInteger index = [self.items indexOfObjectPassingTest:^BOOL(MCBigFileItem *candidate, NSUInteger, BOOL *) {
        return [candidate.path isEqualToString:path];
    }];
    if (index == NSNotFound) {
        return NSZeroRect;
    }
    const NSInteger row = (NSInteger)index;
    const NSRect rowRect = [self.tableView rectOfRow:row];
    if (!NSIntersectsRect(rowRect, self.tableView.visibleRect)) {
        return NSZeroRect; // row scrolled away: let the panel fade instead
    }
    const NSRect inWindow = [self.tableView convertRect:rowRect toView:nil];
    return [self.view.window convertRectToScreen:inWindow];
}

#pragma mark - Preview

/// Media/photo gate for the preview pane. Uses the on-disk content type
/// (which sees through wrong/missing extensions), falling back to the
/// extension when the file is unreadable. Audio is included: it conforms to
/// UTTypeAudiovisualContent alongside movies.
- (BOOL)isPreviewableMediaAtURL:(NSURL *)url {
    UTType *type = nil;
    [url getResourceValue:&type forKey:NSURLContentTypeKey error:nil];
    if (type == nil) {
        type = [UTType typeWithFilenameExtension:url.pathExtension.lowercaseString];
    }
    if (type == nil) {
        return NO;
    }
    return [type conformsToType:UTTypeImage] || [type conformsToType:UTTypeAudiovisualContent];
}

- (void)showPlaceholder:(NSString *)message {
    // Clearing the item also stops any in-flight video/audio playback.
    if (self.previewedPath != nil) {
        self.previewView.previewItem = nil;
        self.previewedPath = nil;
    }
    self.previewView.hidden = YES;
    self.placeholderStack.hidden = NO;
    self.placeholderLabel.stringValue = message;
}

- (void)updatePreview {
    NSArray<MCBigFileItem *> *selected = [self selectedItems];

    if (selected.count == 0) {
        [self showPlaceholder:@"Select a media or photo file to preview it."];
        return;
    }
    if (selected.count > 1) {
        unsigned long long total = 0;
        for (MCBigFileItem *item in selected) {
            total += item.sizeBytes;
        }
        [self showPlaceholder:[NSString stringWithFormat:@"%lu files selected · %@",
                                                          (unsigned long)selected.count, humanSize(total)]];
        return;
    }

    MCBigFileItem *item = selected.firstObject;
    NSURL *url = [NSURL fileURLWithPath:item.path];
    if (![self isPreviewableMediaAtURL:url]) {
        [self showPlaceholder:[NSString stringWithFormat:@"%@\n%@ · no media preview",
                                                          item.name, humanSize(item.sizeBytes)]];
        return;
    }

    if ([self.previewedPath isEqualToString:item.path]) {
        return; // same file re-selected; don't restart a playing video
    }
    self.previewedPath = item.path;
    self.placeholderStack.hidden = YES;
    self.previewView.hidden = NO;
    // NSURL conforms to QLPreviewItem, so the URL itself is the item.
    self.previewView.previewItem = url;
}

#pragma mark - NSTableViewDataSource / Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.items.count;
}

- (NSView *)tableView:(NSTableView *)tableView
    viewForTableColumn:(NSTableColumn *)tableColumn
                    row:(NSInteger)row {
    MCBigFileItem *item = self.items[(NSUInteger)row];
    NSString *identifier = tableColumn.identifier;

    NSTextField *field = [tableView makeViewWithIdentifier:identifier owner:self];
    if (field == nil) {
        field = [NSTextField labelWithString:@""];
        field.identifier = identifier;
        field.lineBreakMode = NSLineBreakByTruncatingMiddle;
        if ([identifier isEqualToString:kSizeColumn]) {
            field.alignment = NSTextAlignmentRight;
            field.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize
                                                          weight:NSFontWeightRegular];
        }
    }

    if ([identifier isEqualToString:kSizeColumn]) {
        field.stringValue = humanSize(item.sizeBytes);
    } else if ([identifier isEqualToString:kNameColumn]) {
        field.stringValue = item.name;
        field.toolTip = item.path;
    } else {
        field.stringValue = [self displayPath:[item.path stringByDeletingLastPathComponent]];
        field.textColor = NSColor.secondaryLabelColor;
        field.toolTip = item.path;
    }
    return field;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    [self updateActionButtons];
    [self updatePreview];
    // Clicking through rows while the panel floats open must retarget it,
    // Finder-style, without requiring another Space press.
    [self reloadPreviewPanelIfVisible];
}

@end
