#import "MCLargeFilesViewController.h"

#import "MCBigFilesModel.h"

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

// Threshold popup entries. Bytes are 1024-based to match humanSize output.
struct ThresholdChoice {
    const char *label;
    unsigned long long bytes;
};
constexpr ThresholdChoice kThresholds[] = {
    {"50 MB", 50ull << 20},
    {"100 MB", 100ull << 20},
    {"250 MB", 250ull << 20},
    {"500 MB", 500ull << 20},
    {"1 GB", 1ull << 30},
    {"5 GB", 5ull << 30},
};
constexpr NSInteger kDefaultThresholdIndex = 1; // 100 MB
constexpr NSUInteger kMaxResults = 200;

} // namespace

@interface MCLargeFilesViewController () <NSTableViewDataSource, NSTableViewDelegate>

@property(nonatomic, strong) MCBigFilesModel *model;
@property(nonatomic, copy) NSArray<MCBigFileItem *> *items;
@property(nonatomic, copy) NSString *scanRoot;      // the root of the *displayed* results
@property(nonatomic, copy) NSString *pendingRoot;   // what the picker shows / next scan uses

@property(nonatomic, strong) NSTextField *rootLabel;
@property(nonatomic, strong) NSPopUpButton *thresholdPopUp;
@property(nonatomic, strong) NSButton *chooseButton;
@property(nonatomic, strong) NSButton *scanButton;
@property(nonatomic, strong) NSProgressIndicator *spinner;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSTableView *tableView;
@property(nonatomic, strong) NSButton *revealButton;
@property(nonatomic, strong) NSButton *trashButton;

// Preview pane: Quick Look for media/photo selections, a placeholder
// (icon + caption) for everything else.
@property(nonatomic, strong) QLPreviewView *previewView;
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

    self.chooseButton = [NSButton buttonWithTitle:@"Choose…" target:self action:@selector(chooseRoot:)];
    self.chooseButton.bezelStyle = NSBezelStyleRounded;

    self.thresholdPopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (const auto &choice : kThresholds) {
        [self.thresholdPopUp addItemWithTitle:[NSString stringWithFormat:@"≥ %s", choice.label]];
    }
    [self.thresholdPopUp selectItemAtIndex:kDefaultThresholdIndex];

    self.scanButton = [NSButton buttonWithTitle:@"Scan" target:self action:@selector(scanOrCancel:)];
    self.scanButton.bezelStyle = NSBezelStyleRounded;
    self.scanButton.keyEquivalent = @"\r";

    self.spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.controlSize = NSControlSizeSmall;
    self.spinner.displayedWhenStopped = NO;

    NSStackView *topBar = [NSStackView stackViewWithViews:@[
        self.rootLabel, self.chooseButton, self.thresholdPopUp, self.scanButton, self.spinner
    ]];
    topBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    topBar.spacing = 8;
    topBar.translatesAutoresizingMaskIntoConstraints = NO;

    // --- table -----------------------------------------------------------
    self.tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.usesAlternatingRowBackgroundColors = YES;
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
    scrollView.borderType = NSBezelBorder;

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
    [splitView addArrangedSubview:scrollView];
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
        self.statusLabel, spacer, self.revealButton, self.trashButton
    ]];
    bottomBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bottomBar.spacing = 8;
    bottomBar.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:topBar];
    [self.view addSubview:splitView];
    [self.view addSubview:bottomBar];

    const CGFloat margin = 16;
    [NSLayoutConstraint activateConstraints:@[
        [topBar.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:margin],
        [topBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [topBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],

        [splitView.topAnchor constraintEqualToAnchor:topBar.bottomAnchor constant:12],
        [splitView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [splitView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],

        [bottomBar.topAnchor constraintEqualToAnchor:splitView.bottomAnchor constant:12],
        [bottomBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [bottomBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],
        [bottomBar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-margin],
    ]];

    [self updatePreview];
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
                  }];
}

- (void)scanOrCancel:(id)sender {
    if (self.model.scanning) {
        [self.model cancelScan];
        self.scanButton.enabled = NO; // debounce until the completion flips the UI back
        return;
    }

    const NSInteger thresholdIndex = self.thresholdPopUp.indexOfSelectedItem;
    const unsigned long long minSize =
        kThresholds[MAX(thresholdIndex, 0)].bytes;

    NSString *root = self.pendingRoot;
    self.scanButton.title = @"Cancel";
    self.chooseButton.enabled = NO;
    self.thresholdPopUp.enabled = NO;
    [self.spinner startAnimation:nil];
    self.statusLabel.stringValue = @"Scanning…";

    __weak MCLargeFilesViewController *weakSelf = self;
    [self.model scanUnder:root
              minSizeBytes:minSize
                maxResults:kMaxResults
                  progress:^(uint64_t visited, NSString *currentDir) {
                      MCLargeFilesViewController *strongSelf = weakSelf;
                      if (strongSelf == nil) {
                          return;
                      }
                      strongSelf.statusLabel.stringValue =
                          [NSString stringWithFormat:@"Scanning… %llu entries · %@",
                                                      (unsigned long long)visited,
                                                      [strongSelf displayPath:currentDir]];
                  }
                completion:^(NSArray<MCBigFileItem *> *files) {
                    MCLargeFilesViewController *strongSelf = weakSelf;
                    if (strongSelf == nil) {
                        return;
                    }
                    strongSelf.items = files;
                    strongSelf.scanRoot = root;
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
                }];
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
    // The previewed file may be the one just trashed; QLPreviewView keeps
    // videos open, so drop the item rather than previewing a Trash entry.
    [self updatePreview];

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
    self.revealButton.enabled = hasSelection;
    self.trashButton.enabled = hasSelection && !self.model.scanning;
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
}

@end
