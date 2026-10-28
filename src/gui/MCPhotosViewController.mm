#import "MCPhotosViewController.h"

#import "MCPhotoModel.h"

#import <Quartz/Quartz.h>

#include "maccleaner/format.hpp"
#include "maccleaner/photos.hpp"

namespace {

NSString *humanSize(unsigned long long bytes) {
    // Same formatter as the CLI and the other tools, so every surface agrees.
    return [NSString stringWithUTF8String:maccleaner::humanReadableBytes(bytes).c_str()];
}

NSString *const kCheckColumn = @"check";
NSString *const kPhotoColumn = @"photo";
NSString *const kDetailColumn = @"detail";

constexpr CGFloat kThumbnailPixels = 96;   // 48 pt rows on Retina
constexpr CGFloat kPreviewPixels = 1600;
constexpr NSInteger kMaxDistanceStep = 16; // beyond this, unrelated photos merge

} // namespace

/// One row of the outline. A photo can sit in a duplicate group *and* in the
/// blurry list, and NSOutlineView needs a distinct object per row, so rows
/// wrap the shared MCPhotoItem rather than being it.
@interface MCPhotoNode : NSObject
@property(nonatomic, copy) NSString *title;                    // headers and groups
@property(nonatomic, copy) NSArray<MCPhotoNode *> *children;
@property(nonatomic, strong, nullable) MCPhotoItem *item;     // leaves only
@property(nonatomic) BOOL keeper;
@end

@implementation MCPhotoNode
@end

/// Space toggles the Quick Look panel, exactly like Finder (and Large Files).
@interface MCPhotoOutlineView : NSOutlineView
@end

@implementation MCPhotoOutlineView

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

@interface MCPhotosViewController () <NSOutlineViewDataSource, NSOutlineViewDelegate, QLPreviewPanelDataSource,
                                      QLPreviewPanelDelegate>

@property(nonatomic, strong) MCPhotoModel *model;
@property(nonatomic, copy) NSArray<MCPhotoItem *> *items;       // every analysed photo
@property(nonatomic, copy) NSArray<MCPhotoNode *> *roots;       // Duplicates, Blurry
@property(nonatomic, strong) NSMutableSet<NSString *> *checked; // by identifier
@property(nonatomic, copy, nullable) NSString *scanRoot;        // nil = library results
@property(nonatomic) NSUInteger skipped;
@property(nonatomic, strong) NSCache<NSString *, NSImage *> *thumbnails;

@property(nonatomic, strong) NSTextField *sourceLabel;
@property(nonatomic, strong) NSButton *folderButton;
@property(nonatomic, strong) NSButton *libraryButton;
@property(nonatomic, strong) NSButton *stopButton;
@property(nonatomic, strong) NSProgressIndicator *spinner;
@property(nonatomic, strong) NSStepper *distanceStepper;
@property(nonatomic, strong) NSTextField *distanceLabel;
@property(nonatomic, strong) NSTextField *blurField;
@property(nonatomic, strong) MCPhotoOutlineView *outlineView;
@property(nonatomic, strong) NSImageView *previewView;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSButton *trashButton;

@end

@implementation MCPhotosViewController

- (instancetype)init {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _model = [[MCPhotoModel alloc] init];
        _items = @[];
        _roots = @[];
        _checked = [NSMutableSet set];
        _thumbnails = [[NSCache alloc] init];
    }
    return self;
}

#pragma mark - Layout

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 760, 560)];

    // --- top bar: source + thresholds -----------------------------------
    self.sourceLabel = [NSTextField labelWithString:@"No photos scanned yet."];
    self.sourceLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.sourceLabel setContentHuggingPriority:NSLayoutPriorityDefaultLow
                                  forOrientation:NSLayoutConstraintOrientationHorizontal];
    // A deep path must truncate, not grow the window (see Large Files).
    [self.sourceLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.folderButton = [NSButton buttonWithTitle:@"Scan Folder…" target:self action:@selector(scanFolder:)];
    self.libraryButton = [NSButton buttonWithTitle:@"Scan Photos Library" target:self action:@selector(scanLibrary:)];
    self.stopButton = [NSButton buttonWithTitle:@"Stop" target:self action:@selector(stopScan:)];
    self.stopButton.hidden = YES;

    self.spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.controlSize = NSControlSizeSmall;
    self.spinner.displayedWhenStopped = NO;

    NSStackView *sourceBar = [NSStackView stackViewWithViews:@[
        self.sourceLabel, self.folderButton, self.libraryButton, self.stopButton, self.spinner
    ]];
    sourceBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    sourceBar.spacing = 8;
    sourceBar.translatesAutoresizingMaskIntoConstraints = NO;

    self.distanceStepper = [[NSStepper alloc] initWithFrame:NSZeroRect];
    self.distanceStepper.minValue = 0;
    self.distanceStepper.maxValue = kMaxDistanceStep;
    self.distanceStepper.integerValue = maccleaner::photos::kDefaultMaxDistance;
    self.distanceStepper.target = self;
    self.distanceStepper.action = @selector(thresholdsChanged:);
    self.distanceLabel = [NSTextField labelWithString:@""];
    self.distanceLabel.toolTip = @"How different two photos may be and still count as duplicates (0 = identical).";

    self.blurField = [NSTextField textFieldWithString:
        [NSString stringWithFormat:@"%g", maccleaner::photos::kDefaultBlurThreshold]];
    self.blurField.target = self;
    self.blurField.action = @selector(thresholdsChanged:);
    self.blurField.toolTip = @"Photos with a sharpness score below this are listed as blurry.";
    [self.blurField.widthAnchor constraintEqualToConstant:60].active = YES;

    NSStackView *thresholdBar = [NSStackView stackViewWithViews:@[
        self.distanceLabel, self.distanceStepper, [NSTextField labelWithString:@"Blurry below sharpness"],
        self.blurField
    ]];
    thresholdBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    thresholdBar.spacing = 6;
    thresholdBar.translatesAutoresizingMaskIntoConstraints = NO;
    [thresholdBar setCustomSpacing:20 afterView:self.distanceStepper];

    // --- outline -----------------------------------------------------------
    self.outlineView = [[MCPhotoOutlineView alloc] initWithFrame:NSZeroRect];
    self.outlineView.dataSource = self;
    self.outlineView.delegate = self;
    self.outlineView.rowHeight = 52;
    self.outlineView.usesAlternatingRowBackgroundColors = YES;
    self.outlineView.allowsMultipleSelection = YES;

    NSTableColumn *checkColumn = [[NSTableColumn alloc] initWithIdentifier:kCheckColumn];
    checkColumn.title = @"";
    checkColumn.width = 44;
    checkColumn.minWidth = 44;
    checkColumn.maxWidth = 44;
    [self.outlineView addTableColumn:checkColumn];
    self.outlineView.outlineTableColumn = checkColumn;

    NSTableColumn *photoColumn = [[NSTableColumn alloc] initWithIdentifier:kPhotoColumn];
    photoColumn.title = @"Photo";
    photoColumn.width = 260;
    photoColumn.minWidth = 160;
    [self.outlineView addTableColumn:photoColumn];

    NSTableColumn *detailColumn = [[NSTableColumn alloc] initWithIdentifier:kDetailColumn];
    detailColumn.title = @"Details";
    detailColumn.width = 260;
    detailColumn.minWidth = 140;
    [self.outlineView addTableColumn:detailColumn];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.documentView = self.outlineView;
    scrollView.hasVerticalScroller = YES;
    scrollView.autohidesScrollers = YES;
    scrollView.borderType = NSBezelBorder;

    // --- preview -----------------------------------------------------------
    self.previewView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    self.previewView.imageScaling = NSImageScaleProportionallyDown;
    [self.previewView setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.previewView setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                forOrientation:NSLayoutConstraintOrientationVertical];

    NSSplitView *splitView = [[NSSplitView alloc] initWithFrame:NSZeroRect];
    splitView.vertical = YES;
    splitView.dividerStyle = NSSplitViewDividerStyleThin;
    [splitView addArrangedSubview:scrollView];
    [splitView addArrangedSubview:self.previewView];
    [splitView setHoldingPriority:NSLayoutPriorityDefaultLow + 10 forSubviewAtIndex:1];
    splitView.autosaveName = @"MCPhotosSplit";
    splitView.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [scrollView.widthAnchor constraintGreaterThanOrEqualToConstant:380],
        [self.previewView.widthAnchor constraintGreaterThanOrEqualToConstant:200],
    ]];

    // --- bottom bar ----------------------------------------------------------
    self.statusLabel = [NSTextField labelWithString:@"Scan a folder or your Photos library."];
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    self.statusLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    // Carries an ever-changing path during scans; must truncate, not resize.
    [self.statusLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.trashButton = [NSButton buttonWithTitle:@"Move to Trash…" target:self action:@selector(removeChecked:)];
    self.trashButton.enabled = NO;

    NSView *spacer = [[NSView alloc] initWithFrame:NSZeroRect];
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *bottomBar = [NSStackView stackViewWithViews:@[ self.statusLabel, spacer, self.trashButton ]];
    bottomBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bottomBar.spacing = 8;
    bottomBar.translatesAutoresizingMaskIntoConstraints = NO;

    // The bars keep their natural height and the split view takes the rest;
    // without this a stack can absorb the spare height and squash the list
    // to zero (the split view has no intrinsic height to defend).
    for (NSStackView *bar in @[ sourceBar, thresholdBar, bottomBar ]) {
        [bar setHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationVertical];
    }

    [self.view addSubview:sourceBar];
    [self.view addSubview:thresholdBar];
    [self.view addSubview:splitView];
    [self.view addSubview:bottomBar];

    const CGFloat margin = 16;
    [NSLayoutConstraint activateConstraints:@[
        [sourceBar.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:margin],
        [sourceBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [sourceBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],

        [thresholdBar.topAnchor constraintEqualToAnchor:sourceBar.bottomAnchor constant:8],
        [thresholdBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [thresholdBar.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-margin],

        [splitView.topAnchor constraintEqualToAnchor:thresholdBar.bottomAnchor constant:12],
        [splitView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [splitView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],

        [bottomBar.topAnchor constraintEqualToAnchor:splitView.bottomAnchor constant:12],
        [bottomBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [bottomBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],
        [bottomBar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-margin],
    ]];

    [self updateDistanceLabel];
}

#pragma mark - Scanning

- (void)scanFolder:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.directoryURL = [NSURL fileURLWithPath:self.scanRoot != nil ? self.scanRoot : NSHomeDirectory() isDirectory:YES];
    panel.prompt = @"Scan";

    __weak MCPhotosViewController *weakSelf = self;
    [panel beginSheetModalForWindow:self.view.window
                  completionHandler:^(NSModalResponse response) {
                      MCPhotosViewController *strongSelf = weakSelf;
                      if (strongSelf == nil || response != NSModalResponseOK || panel.URLs.count == 0) {
                          return;
                      }
                      [strongSelf startFolderScan:panel.URLs.firstObject.path];
                  }];
}

- (void)startFolderScan:(NSString *)root {
    [self beginScanWithSource:[root stringByAbbreviatingWithTildeInPath]];
    __weak MCPhotosViewController *weakSelf = self;
    [self.model scanFolder:root
                  progress:^(uint64_t done, NSString *current) {
                      weakSelf.statusLabel.stringValue =
                          [NSString stringWithFormat:@"%llu photos · %@", done, current.lastPathComponent];
                  }
                completion:^(NSArray<MCPhotoItem *> *items, NSUInteger skipped) {
                    [weakSelf finishScanWithItems:items skipped:skipped root:root];
                }];
}

- (void)scanLibrary:(id)sender {
    [self beginScanWithSource:@"Photos Library"];
    __weak MCPhotosViewController *weakSelf = self;
    [self.model scanLibraryWithProgress:^(uint64_t done, NSString *current) {
        weakSelf.statusLabel.stringValue = [NSString stringWithFormat:@"%llu photos · %@", done, current];
    }
        completion:^(NSArray<MCPhotoItem *> *items, NSUInteger skipped, NSString *error) {
            MCPhotosViewController *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            [strongSelf finishScanWithItems:items != nil ? items : @[] skipped:skipped root:nil];
            if (error != nil) {
                strongSelf.statusLabel.stringValue = error;
            }
        }];
}

- (void)stopScan:(id)sender {
    [self.model cancelScan];
    self.stopButton.enabled = NO; // debounce until the completion flips the UI back
}

- (void)beginScanWithSource:(NSString *)source {
    self.sourceLabel.stringValue = source;
    self.folderButton.enabled = NO;
    self.libraryButton.enabled = NO;
    self.stopButton.hidden = NO;
    self.stopButton.enabled = YES;
    self.trashButton.enabled = NO;
    [self.spinner startAnimation:nil];
    self.statusLabel.stringValue = @"Scanning…";
    self.items = @[];
    [self.checked removeAllObjects];
    [self rebuildTree];
}

- (void)finishScanWithItems:(NSArray<MCPhotoItem *> *)items skipped:(NSUInteger)skipped root:(nullable NSString *)root {
    self.folderButton.enabled = YES;
    self.libraryButton.enabled = YES;
    self.stopButton.hidden = YES;
    [self.spinner stopAnimation:nil];

    self.scanRoot = root;
    self.items = items;
    self.skipped = skipped;
    [self.thumbnails removeAllObjects];
    [self rebuildTree];
    [self showSummary];
}

#pragma mark - Tree

- (void)thresholdsChanged:(id)sender {
    [self updateDistanceLabel];
    [self rebuildTree];
    [self showSummary];
}

- (void)updateDistanceLabel {
    self.distanceLabel.stringValue =
        [NSString stringWithFormat:@"Duplicate tolerance: %ld", (long)self.distanceStepper.integerValue];
}

- (double)blurThreshold {
    const double value = self.blurField.doubleValue;
    return value >= 0 ? value : 0;
}

/// Rebuilds both sections from `items`. Nothing is checked for the user: they
/// look at every photo and pick what goes, which may be nothing. Each group's
/// best copy is only labelled.
- (void)rebuildTree {
    NSArray<NSArray<MCPhotoItem *> *> *groups = [self.model groupsOfItems:self.items
                                                              maxDistance:self.distanceStepper.integerValue];

    NSMutableArray<MCPhotoNode *> *groupNodes = [NSMutableArray arrayWithCapacity:groups.count];
    for (NSUInteger g = 0; g < groups.count; ++g) {
        NSMutableArray<MCPhotoNode *> *leaves = [NSMutableArray array];
        for (NSUInteger i = 0; i < groups[g].count; ++i) {
            MCPhotoNode *leaf = [[MCPhotoNode alloc] init];
            leaf.item = groups[g][i];
            leaf.keeper = (i == 0);
            [leaves addObject:leaf];
        }
        MCPhotoNode *groupNode = [[MCPhotoNode alloc] init];
        groupNode.title = [NSString stringWithFormat:@"Group %lu · %lu photos", (unsigned long)(g + 1),
                                                     (unsigned long)leaves.count];
        groupNode.children = leaves;
        [groupNodes addObject:groupNode];
    }

    const double threshold = [self blurThreshold];
    NSArray<MCPhotoItem *> *blurry = [[self.items filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(MCPhotoItem *item, NSDictionary *) {
            return item.sharpness < threshold;
        }]] sortedArrayUsingComparator:^NSComparisonResult(MCPhotoItem *a, MCPhotoItem *b) {
        return a.sharpness < b.sharpness ? NSOrderedAscending
               : a.sharpness > b.sharpness ? NSOrderedDescending : NSOrderedSame;
    }];
    NSMutableArray<MCPhotoNode *> *blurryLeaves = [NSMutableArray arrayWithCapacity:blurry.count];
    for (MCPhotoItem *item in blurry) {
        MCPhotoNode *leaf = [[MCPhotoNode alloc] init];
        leaf.item = item;
        [blurryLeaves addObject:leaf];
    }

    MCPhotoNode *duplicates = [[MCPhotoNode alloc] init];
    duplicates.title = [NSString stringWithFormat:@"Duplicates (%lu groups)", (unsigned long)groupNodes.count];
    duplicates.children = groupNodes;
    MCPhotoNode *blurryRoot = [[MCPhotoNode alloc] init];
    blurryRoot.title = [NSString stringWithFormat:@"Blurry (%lu)", (unsigned long)blurryLeaves.count];
    blurryRoot.children = blurryLeaves;
    self.roots = @[ duplicates, blurryRoot ];

    [self.outlineView reloadData];
    [self.outlineView expandItem:duplicates expandChildren:YES];
    [self.outlineView expandItem:blurryRoot];
    [self updateTrashButton];
    [self updatePreview];
}

- (void)showSummary {
    if (self.model.scanning) {
        return;
    }
    self.statusLabel.stringValue = [NSString stringWithFormat:
        @"%lu photos · %lu duplicate groups · %lu blurry · %lu skipped · %lu checked",
        (unsigned long)self.items.count, (unsigned long)self.roots.firstObject.children.count,
        (unsigned long)self.roots.lastObject.children.count, (unsigned long)self.skipped,
        (unsigned long)[self checkedItems].count];
}

- (NSArray<MCPhotoItem *> *)checkedItems {
    NSMutableArray<MCPhotoItem *> *result = [NSMutableArray array];
    for (MCPhotoItem *item in self.items) {
        if ([self.checked containsObject:item.identifier]) {
            [result addObject:item];
        }
    }
    return result;
}

- (void)toggleCheck:(NSButton *)sender {
    MCPhotoNode *node = [self.outlineView itemAtRow:[self.outlineView rowForView:sender]];
    if (node.item == nil) {
        return;
    }
    if (sender.state == NSControlStateValueOn) {
        [self.checked addObject:node.item.identifier];
    } else {
        [self.checked removeObject:node.item.identifier];
    }
    // The same photo may have a second row in the other section.
    [self.outlineView reloadData];
    [self updateTrashButton];
    [self showSummary];
}

- (void)updateTrashButton {
    self.trashButton.title = self.scanRoot == nil && self.items.count > 0 ? @"Delete from Photos…" : @"Move to Trash…";
    self.trashButton.enabled = !self.model.scanning && [self checkedItems].count > 0;
}

#pragma mark - Removal

- (void)removeChecked:(id)sender {
    NSArray<MCPhotoItem *> *selected = [self checkedItems];
    if (selected.count == 0) {
        return;
    }

    if (self.scanRoot == nil) {
        // Photos shows its own confirmation and keeps the photos in Recently
        // Deleted, so a second alert here would only be noise.
        NSArray<NSString *> *identifiers = [selected valueForKey:@"identifier"];
        __weak MCPhotosViewController *weakSelf = self;
        [self.model deleteLibraryAssets:identifiers
                             completion:^(BOOL ok, NSString *error) {
                                 MCPhotosViewController *strongSelf = weakSelf;
                                 if (strongSelf == nil) {
                                     return;
                                 }
                                 if (!ok) {
                                     strongSelf.statusLabel.stringValue =
                                         [NSString stringWithFormat:@"Nothing deleted: %@", error != nil ? error : @"cancelled"];
                                     return;
                                 }
                                 [strongSelf dropItemsWithIdentifiers:[NSSet setWithArray:identifiers]];
                                 strongSelf.statusLabel.stringValue = [NSString stringWithFormat:
                                     @"Deleted %lu photo(s) · they stay in Recently Deleted for 30 days",
                                     (unsigned long)identifiers.count];
                             }];
        return;
    }

    unsigned long long total = 0;
    for (MCPhotoItem *item in selected) {
        total += item.sizeBytes;
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Move the checked photos to the Trash?";
    alert.informativeText = [NSString stringWithFormat:@"%lu photo(s), %@.", (unsigned long)selected.count,
                                                        humanSize(total)];
    [alert addButtonWithTitle:@"Move to Trash"];
    [alert addButtonWithTitle:@"Cancel"];

    __weak MCPhotosViewController *weakSelf = self;
    [alert beginSheetModalForWindow:self.view.window
                  completionHandler:^(NSModalResponse response) {
                      if (response == NSAlertFirstButtonReturn) {
                          [weakSelf trashItems:selected];
                      }
                  }];
}

- (void)trashItems:(NSArray<MCPhotoItem *> *)selected {
    NSMutableArray<NSString *> *problems = [NSMutableArray array];
    NSMutableSet<NSString *> *removed = [NSMutableSet set];
    unsigned long long freed = 0;

    for (MCPhotoItem *item in selected) {
        NSString *error = nil;
        if ([self.model trashFileAtPath:item.identifier underScanRoot:self.scanRoot error:&error]) {
            [removed addObject:item.identifier];
            freed += item.sizeBytes;
        } else {
            [problems addObject:[NSString stringWithFormat:@"%@ — %@", item.name, error != nil ? error : @"unknown error"]];
        }
    }

    [self dropItemsWithIdentifiers:removed];

    if (problems.count == 0) {
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Moved %lu photo(s) to Trash · freed %@",
                                                                    (unsigned long)removed.count, humanSize(freed)];
    } else {
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Freed %@ · %lu failed", humanSize(freed),
                                                                    (unsigned long)problems.count];
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = @"Some photos could not be moved to the Trash";
        alert.informativeText = [problems componentsJoinedByString:@"\n"];
        [alert addButtonWithTitle:@"OK"];
        [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
    }
}

/// Drops removed photos without rescanning.
- (void)dropItemsWithIdentifiers:(NSSet<NSString *> *)identifiers {
    self.items = [self.items filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(MCPhotoItem *item, NSDictionary *) {
            return ![identifiers containsObject:item.identifier];
        }]];
    [self.checked minusSet:identifiers];
    [self rebuildTree];
    [self reloadPreviewPanelIfVisible];
}

#pragma mark - Preview

- (NSArray<MCPhotoItem *> *)selectedItems {
    NSMutableArray<MCPhotoItem *> *result = [NSMutableArray array];
    [self.outlineView.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *) {
        MCPhotoItem *item = [(MCPhotoNode *)[self.outlineView itemAtRow:(NSInteger)row] item];
        if (item != nil) {
            [result addObject:item];
        }
    }];
    return result;
}

- (void)updatePreview {
    MCPhotoItem *item = [self selectedItems].firstObject;
    self.previewView.image = nil;
    if (item == nil) {
        return;
    }
    __weak MCPhotosViewController *weakSelf = self;
    [self.model imageForItem:item
                   maxPixels:kPreviewPixels
                  completion:^(NSImage *image) {
                      // A newer selection may have won the race.
                      if ([weakSelf selectedItems].firstObject == item) {
                          weakSelf.previewView.image = image;
                      }
                  }];
}

#pragma mark - Quick Look panel (folder photos only)

/// Quick Look needs a file URL; library assets have none, so the panel shows
/// only the selected folder photos.
- (NSArray<NSURL *> *)previewURLs {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (MCPhotoItem *item in [self selectedItems]) {
        if (!item.isLibraryAsset) {
            [urls addObject:[NSURL fileURLWithPath:item.identifier]];
        }
    }
    return urls;
}

- (void)togglePreviewPanel:(id)sender {
    QLPreviewPanel *panel = [QLPreviewPanel sharedPreviewPanel];
    if ([QLPreviewPanel sharedPreviewPanelExists] && panel.isVisible) {
        [panel orderOut:nil];
    } else if ([self previewURLs].count > 0) {
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
    if ([QLPreviewPanel sharedPreviewPanelExists] && [QLPreviewPanel sharedPreviewPanel].isVisible &&
        [QLPreviewPanel sharedPreviewPanel].dataSource == self) {
        [[QLPreviewPanel sharedPreviewPanel] reloadData];
    }
}

- (NSInteger)numberOfPreviewItemsInPreviewPanel:(QLPreviewPanel *)panel {
    return (NSInteger)[self previewURLs].count;
}

- (id<QLPreviewItem>)previewPanel:(QLPreviewPanel *)panel previewItemAtIndex:(NSInteger)index {
    NSArray<NSURL *> *urls = [self previewURLs];
    return index >= 0 && (NSUInteger)index < urls.count ? urls[(NSUInteger)index] : nil;
}

/// Up/down on the panel moves the outline selection, like Finder.
- (BOOL)previewPanel:(QLPreviewPanel *)panel handleEvent:(NSEvent *)event {
    if (event.type == NSEventTypeKeyDown && event.charactersIgnoringModifiers.length > 0) {
        const unichar key = [event.charactersIgnoringModifiers characterAtIndex:0];
        if (key == NSUpArrowFunctionKey || key == NSDownArrowFunctionKey) {
            [self.outlineView keyDown:event];
            [panel reloadData];
            return YES;
        }
    }
    return NO;
}

#pragma mark - NSOutlineViewDataSource / Delegate

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(nullable id)item {
    return (NSInteger)(item == nil ? self.roots : [(MCPhotoNode *)item children]).count;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(nullable id)item {
    return (item == nil ? self.roots : [(MCPhotoNode *)item children])[(NSUInteger)index];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item {
    return [(MCPhotoNode *)item item] == nil && [(MCPhotoNode *)item children].count > 0;
}

- (CGFloat)outlineView:(NSOutlineView *)outlineView heightOfRowByItem:(id)item {
    return [(MCPhotoNode *)item item] != nil ? 52 : 24;
}

- (nullable NSView *)outlineView:(NSOutlineView *)outlineView
              viewForTableColumn:(nullable NSTableColumn *)tableColumn
                            item:(id)item {
    MCPhotoNode *node = item;
    NSString *column = tableColumn.identifier;

    if (node.item == nil) {
        // Section and group rows: one bold title in the photo column.
        if (![column isEqualToString:kPhotoColumn]) {
            return nil;
        }
        NSTextField *label = [NSTextField labelWithString:node.title];
        label.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
        return label;
    }

    MCPhotoItem *photo = node.item;
    if ([column isEqualToString:kCheckColumn]) {
        NSButton *box = [NSButton checkboxWithTitle:@"" target:self action:@selector(toggleCheck:)];
        box.state = [self.checked containsObject:photo.identifier] ? NSControlStateValueOn : NSControlStateValueOff;
        box.toolTip = node.keeper ? @"Best copy in this group: most pixels, then sharpest, then oldest." : nil;
        box.accessibilityLabel = [NSString stringWithFormat:@"Remove %@", photo.name];
        return box;
    }

    if ([column isEqualToString:kPhotoColumn]) {
        NSImageView *thumbnail = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"photo"
                                                                       accessibilityDescription:nil]];
        thumbnail.imageScaling = NSImageScaleProportionallyUpOrDown;
        thumbnail.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [thumbnail.widthAnchor constraintEqualToConstant:48],
            [thumbnail.heightAnchor constraintEqualToConstant:48],
        ]];
        NSImage *cached = [self.thumbnails objectForKey:photo.identifier];
        if (cached != nil) {
            thumbnail.image = cached;
        } else {
            __weak NSImageView *weakThumbnail = thumbnail;
            __weak MCPhotosViewController *weakSelf = self;
            [self.model imageForItem:photo
                           maxPixels:kThumbnailPixels
                          completion:^(NSImage *image) {
                              if (image != nil) {
                                  [weakSelf.thumbnails setObject:image forKey:photo.identifier];
                                  weakThumbnail.image = image;
                              }
                          }];
        }

        NSTextField *name = [NSTextField labelWithString:node.keeper ? [photo.name stringByAppendingString:@"  (best copy)"]
                                                                     : photo.name];
        name.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [name setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                       forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSStackView *stack = [NSStackView stackViewWithViews:@[ thumbnail, name ]];
        stack.spacing = 8;
        return stack;
    }

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:[NSString stringWithFormat:@"%ld×%ld", (long)photo.pixelWidth, (long)photo.pixelHeight]];
    [parts addObject:[NSString stringWithFormat:@"sharpness %.0f", photo.sharpness]];
    if (photo.sizeBytes > 0) {
        [parts addObject:humanSize(photo.sizeBytes)];
    }
    if (photo.created != nil) {
        [parts addObject:[NSDateFormatter localizedStringFromDate:photo.created
                                                        dateStyle:NSDateFormatterShortStyle
                                                        timeStyle:NSDateFormatterNoStyle]];
    }
    NSTextField *detail = [NSTextField labelWithString:[parts componentsJoinedByString:@" · "]];
    detail.textColor = NSColor.secondaryLabelColor;
    detail.lineBreakMode = NSLineBreakByTruncatingTail;
    [detail setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                     forOrientation:NSLayoutConstraintOrientationHorizontal];
    return detail;
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification {
    [self updatePreview];
    [self reloadPreviewPanelIfVisible];
}

@end
