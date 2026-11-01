#import "MCPhotosViewController.h"

#import "MCHeroView.h"
#import "MCPhotoModel.h"
#import "MCTheme.h"
#import "MCToolBanner.h"

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
constexpr CGFloat kLargePreviewPixels = 3000;
constexpr NSInteger kMaxDistanceStep = 16; // beyond this, unrelated photos merge
NSString *const kLastFolderKey = @"MCPhotosLastFolder";

// A 3000 px photo's intrinsic size would otherwise squash the toolbars or
// grow the window; the view should only ever scale the image into its frame.
NSImageView *imageViewWithoutIntrinsicSize() {
    NSImageView *view = [[NSImageView alloc] initWithFrame:NSZeroRect];
    view.imageScaling = NSImageScaleProportionallyDown;
    for (NSLayoutConstraintOrientation axis :
         {NSLayoutConstraintOrientationHorizontal, NSLayoutConstraintOrientationVertical}) {
        [view setContentCompressionResistancePriority:1 forOrientation:axis];
        [view setContentHuggingPriority:1 forOrientation:axis];
    }
    return view;
}

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

/// Space toggles the large preview, like Finder's Quick Look (and Large Files).
/// Return toggles the check of every selected photo.
@interface MCPhotoOutlineView : NSOutlineView
@end

@implementation MCPhotoOutlineView

- (void)keyDown:(NSEvent *)event {
    NSString *chars = event.charactersIgnoringModifiers;
    if (chars.length == 1 && [chars characterAtIndex:0] == ' ' &&
        (event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask) == 0) {
        [NSApp sendAction:@selector(toggleLargePreview:) to:nil from:self];
        return;
    }
    if (chars.length == 1 && ([chars characterAtIndex:0] == NSCarriageReturnCharacter ||
                              [chars characterAtIndex:0] == NSEnterCharacter) &&
        (event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask & ~NSEventModifierFlagNumericPad) == 0) {
        [NSApp sendAction:@selector(toggleCheckSelection:) to:nil from:self];
        return;
    }
    [super keyDown:event];
}

@end

@interface MCPhotosViewController () <NSOutlineViewDataSource, NSOutlineViewDelegate, QLPreviewPanelDataSource,
                                      QLPreviewPanelDelegate, NSOpenSavePanelDelegate>

@property(nonatomic, strong) MCPhotoModel *model;
@property(nonatomic, copy) NSArray<MCPhotoItem *> *items;       // every analysed photo
@property(nonatomic, copy) NSArray<MCPhotoNode *> *roots;       // Duplicates, Blurry
@property(nonatomic, strong) NSMutableSet<NSString *> *checked; // by identifier
@property(nonatomic, copy, nullable) NSString *scanRoot;        // nil = library results
@property(nonatomic) NSUInteger skipped;
@property(nonatomic) BOOL hasScanned;
@property(nonatomic, strong) MCHeroView *hero;
@property(nonatomic, strong) MCToolBanner *banner;
@property(nonatomic, copy, nullable) NSArray<NSArray<MCPhotoItem *> *> *groups; // cache; nil = stale
@property(nonatomic) NSInteger groupedDistance;
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
@property(nonatomic, strong) NSTextField *previewPlaceholder;
@property(nonatomic, strong) NSButton *largePreviewButton;
@property(nonatomic, strong, nullable) NSWindow *largePreviewWindow; // library photos only
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSButton *trashButton;
@property(nonatomic, strong) NSButton *checkCopiesButton;

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

    self.folderButton = [MCGlassButton buttonWithTitle:@"Scan Folder…" style:MCGlassButtonStylePillPrimary
                                                 tool:MCToolPhotos target:self action:@selector(scanFolder:)];
    self.libraryButton = [MCGlassButton buttonWithTitle:@"Scan Photos Library" style:MCGlassButtonStylePill
                                                  tool:MCToolPhotos target:self action:@selector(scanLibrary:)];
    self.stopButton = [NSButton buttonWithTitle:@"Stop" target:self action:@selector(stopScan:)];
    self.stopButton.hidden = YES;

    self.spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.controlSize = NSControlSizeSmall;
    self.spinner.displayedWhenStopped = NO;

    NSStackView *sourceBar = [NSStackView stackViewWithViews:@[
        self.sourceLabel, self.stopButton, self.spinner
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
    self.outlineView.allowsMultipleSelection = YES;
    self.outlineView.target = self;
    self.outlineView.doubleAction = @selector(showLargePreview:);

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
    [MCTheme styleCard:scrollView];
    NSView *card = scrollView;

    // --- preview -----------------------------------------------------------
    self.previewView = imageViewWithoutIntrinsicSize();
    self.previewView.translatesAutoresizingMaskIntoConstraints = NO;

    self.previewPlaceholder = [NSTextField wrappingLabelWithString:
        @"Select a photo to preview it.\nDouble-click or press Space for a large preview."];
    self.previewPlaceholder.alignment = NSTextAlignmentCenter;
    self.previewPlaceholder.textColor = NSColor.secondaryLabelColor;
    self.previewPlaceholder.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *previewContainer = [[NSView alloc] initWithFrame:NSZeroRect];
    [previewContainer addSubview:self.previewView];
    [previewContainer addSubview:self.previewPlaceholder];
    [NSLayoutConstraint activateConstraints:@[
        [self.previewView.topAnchor constraintEqualToAnchor:previewContainer.topAnchor constant:8],
        [self.previewView.bottomAnchor constraintEqualToAnchor:previewContainer.bottomAnchor constant:-8],
        [self.previewView.leadingAnchor constraintEqualToAnchor:previewContainer.leadingAnchor constant:8],
        [self.previewView.trailingAnchor constraintEqualToAnchor:previewContainer.trailingAnchor constant:-8],
        [self.previewPlaceholder.centerYAnchor constraintEqualToAnchor:previewContainer.centerYAnchor],
        [self.previewPlaceholder.leadingAnchor constraintEqualToAnchor:previewContainer.leadingAnchor constant:12],
        [self.previewPlaceholder.trailingAnchor constraintEqualToAnchor:previewContainer.trailingAnchor constant:-12],
    ]];

    NSSplitView *splitView = [[NSSplitView alloc] initWithFrame:NSZeroRect];
    splitView.vertical = YES;
    splitView.dividerStyle = NSSplitViewDividerStyleThin;
    [splitView addArrangedSubview:card];
    [splitView addArrangedSubview:previewContainer];
    [splitView setHoldingPriority:NSLayoutPriorityDefaultLow + 10 forSubviewAtIndex:1];
    splitView.autosaveName = @"MCPhotosSplit";
    splitView.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [scrollView.widthAnchor constraintGreaterThanOrEqualToConstant:380],
        [previewContainer.widthAnchor constraintGreaterThanOrEqualToConstant:300],
    ]];

    // --- bottom bar ----------------------------------------------------------
    self.statusLabel = [NSTextField labelWithString:@"Scan a folder or your Photos library."];
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    self.statusLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    // Carries an ever-changing path during scans; must truncate, not resize.
    [self.statusLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.largePreviewButton = [NSButton buttonWithTitle:@"Large Preview" target:self
                                                 action:@selector(showLargePreview:)];
    self.largePreviewButton.toolTip = @"Show the selected photo large (double-click or Space)";
    self.largePreviewButton.enabled = NO;

    self.trashButton = [NSButton buttonWithTitle:@"Remove…" target:self action:@selector(removeChecked:)];
    self.trashButton.enabled = NO;

    self.checkCopiesButton = [NSButton buttonWithTitle:@"Check Copies" target:self action:@selector(checkCopies:)];
    self.checkCopiesButton.toolTip =
        @"Check every photo in the duplicate groups except the best copy. Select rows and press Return to toggle them.";
    self.checkCopiesButton.enabled = NO;

    NSView *spacer = [[NSView alloc] initWithFrame:NSZeroRect];
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *bottomBar = [NSStackView stackViewWithViews:@[
        self.statusLabel, spacer, self.checkCopiesButton, self.largePreviewButton, self.trashButton
    ]];
    bottomBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bottomBar.spacing = 8;
    bottomBar.translatesAutoresizingMaskIntoConstraints = NO;

    // The bars keep their natural height and the split view takes the rest;
    // without this a stack can absorb the spare height and squash the list
    // to zero (the split view has no intrinsic height to defend).
    for (NSStackView *bar in @[ sourceBar, thresholdBar, bottomBar ]) {
        [bar setHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationVertical];
    }

    // --- results banner and start screen ---------------------------------
    self.banner = [[MCToolBanner alloc] initWithTool:MCToolPhotos symbol:[MCTheme symbolForTool:MCToolPhotos]];
    self.banner.actions = @[ self.libraryButton, self.folderButton ];

    self.hero = [[MCHeroView alloc] initWithTool:MCToolPhotos
                                          symbol:[MCTheme symbolForTool:MCToolPhotos]
                                           title:@"Photo Cleaner"
                                        subtitle:@"Find duplicate, similar and blurry photos."];
    self.hero.actions = @[
        [MCGlassButton buttonWithTitle:@"Scan" style:MCGlassButtonStyleRound tool:MCToolPhotos
                                target:self action:@selector(scanFolder:)],
        [MCGlassButton buttonWithTitle:@"Scan Photos Library Instead" style:MCGlassButtonStylePill tool:MCToolPhotos
                                target:self action:@selector(scanLibrary:)],
    ];
    self.hero.scanningAccessory = [MCGlassButton buttonWithTitle:@"Stop" style:MCGlassButtonStylePill
                                                            tool:MCToolPhotos target:self
                                                          action:@selector(stopScan:)];

    [self.view addSubview:self.banner];
    [self.view addSubview:sourceBar];
    [self.view addSubview:thresholdBar];
    [self.view addSubview:splitView];
    [self.view addSubview:bottomBar];
    [self.view addSubview:self.hero];

    const CGFloat margin = 16;
    [NSLayoutConstraint activateConstraints:@[
        [self.banner.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.banner.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [self.banner.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],

        [sourceBar.topAnchor constraintEqualToAnchor:self.banner.bottomAnchor constant:12],
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

        [self.hero.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.hero.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.hero.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.hero.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    [self updateDistanceLabel];
    [self updateHero];
    [self restoreLastFolder];
}

/// Shows the last scanned folder from the cache at once, then rescans it in
/// the background: deleted photos drop out and only new or changed files are
/// decoded. Moving to Trash stays off until that rescan is done.
- (void)restoreLastFolder {
    NSString *root = [NSUserDefaults.standardUserDefaults stringForKey:kLastFolderKey];
    if (root == nil) {
        return;
    }
    __weak MCPhotosViewController *weakSelf = self;
    [self.model loadCachedFolder:root
                      completion:^(NSArray<MCPhotoItem *> *items) {
                          MCPhotosViewController *strongSelf = weakSelf;
                          // The user may have started a scan of their own meanwhile.
                          if (strongSelf == nil || items == nil || strongSelf.hasScanned || strongSelf.model.busy) {
                              return;
                          }
                          strongSelf.sourceLabel.stringValue = [root stringByAbbreviatingWithTildeInPath];
                          [strongSelf finishScanWithItems:items skipped:0 root:root];
                          [strongSelf startFolderScan:root keepResults:YES];
                      }];
}

/// The start screen until a scan shows its first result. After a finished
/// scan the results stay, even when empty, so the thresholds are at hand.
- (void)updateHero {
    const NSUInteger groups = self.roots.firstObject.children.count;
    const NSUInteger blurry = self.roots.lastObject.children.count;
    self.banner.value = [NSString stringWithFormat:@"%lu to review", (unsigned long)(groups + blurry)];
    self.banner.caption = [NSString stringWithFormat:@"%lu duplicate groups · %lu blurry · %lu photos in %@",
                                                     (unsigned long)groups, (unsigned long)blurry,
                                                     (unsigned long)self.items.count, self.sourceLabel.stringValue];

    const BOOL presented = groups + blurry == 0 && (self.model.busy || !self.hasScanned);
    [self.hero setPresented:presented];
    if (!presented) {
        return;
    }
    if (self.model.busy) {
        [self.hero showScanningWithStatus:@"Comparing photos and measuring sharpness…"];
    } else {
        [self.hero showIdleWithMessage:@"Scan asks for a folder of photos."];
    }
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
                      [strongSelf startFolderScan:panel.URLs.firstObject.path keepResults:NO];
                  }];
}

- (void)startFolderScan:(NSString *)root keepResults:(BOOL)keepResults {
    [NSUserDefaults.standardUserDefaults setObject:root forKey:kLastFolderKey];
    [self beginScanWithSource:[root stringByAbbreviatingWithTildeInPath] keepResults:keepResults];
    __weak MCPhotosViewController *weakSelf = self;
    [self.model scanFolder:root
                  progress:^(uint64_t done, NSString *current) {
                      weakSelf.statusLabel.stringValue =
                          [NSString stringWithFormat:@"%llu photos · %@", done, current.lastPathComponent];
                      [weakSelf.hero setStatus:weakSelf.statusLabel.stringValue];
                  }
                completion:^(NSArray<MCPhotoItem *> *items, NSUInteger skipped) {
                    [weakSelf finishScanWithItems:items skipped:skipped root:root];
                }];
    [self updateHero]; // after scanFolder:, so `busy` is already set
}

- (void)scanLibrary:(id)sender {
    [self beginScanWithSource:@"Photos Library" keepResults:NO];
    __weak MCPhotosViewController *weakSelf = self;
    [self.model scanLibraryWithProgress:^(uint64_t done, NSString *current) {
        weakSelf.statusLabel.stringValue = [NSString stringWithFormat:@"%llu photos · %@", done, current];
        [weakSelf.hero setStatus:weakSelf.statusLabel.stringValue];
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
    [self updateHero];
}

- (void)stopScan:(id)sender {
    [self.model cancelScan];
    self.stopButton.enabled = NO; // debounce until the completion flips the UI back
}

/// `keepResults` leaves the shown photos and checks in place while a rescan
/// of the same folder checks them.
- (void)beginScanWithSource:(NSString *)source keepResults:(BOOL)keepResults {
    self.sourceLabel.stringValue = source;
    self.folderButton.enabled = NO;
    self.libraryButton.enabled = NO;
    self.stopButton.hidden = NO;
    self.stopButton.enabled = YES;
    self.trashButton.enabled = NO;
    [self.spinner startAnimation:nil];
    self.statusLabel.stringValue = keepResults ? @"Checking for changes…" : @"Scanning…";
    self.checkCopiesButton.enabled = NO;
    if (keepResults) {
        return;
    }
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
    self.hasScanned = YES;
    [self.thumbnails removeAllObjects];
    [self rebuildTree];
    [self showSummary];
}

#pragma mark - Tree

- (void)setItems:(NSArray<MCPhotoItem *> *)items {
    _items = [items copy];
    _groups = nil; // different photos, different groups
}

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
    // Redo grouping only when the photos or the tolerance changed, not for
    // blur-threshold edits. It stays on main: at 30k photos the core takes
    // ~15 ms up to tolerance 11 and ~140 ms above (see groupDuplicates).
    if (self.groups == nil || self.groupedDistance != self.distanceStepper.integerValue) {
        self.groupedDistance = self.distanceStepper.integerValue;
        self.groups = [self.model groupsOfItems:self.items maxDistance:self.groupedDistance];
    }
    NSArray<NSArray<MCPhotoItem *> *> *groups = self.groups;

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

    // A check on a row that a threshold change just hid must not survive:
    // Move to Trash would remove a photo the user can no longer see.
    NSMutableSet<NSString *> *visible = [NSMutableSet set];
    for (NSArray<MCPhotoItem *> *group in groups) {
        [visible addObjectsFromArray:[group valueForKey:@"identifier"]];
    }
    [visible addObjectsFromArray:[blurry valueForKey:@"identifier"]];
    [self.checked intersectSet:visible];

    [self.outlineView reloadData];
    [self.outlineView expandItem:duplicates expandChildren:YES];
    [self.outlineView expandItem:blurryRoot];
    [self updateTrashButton];
    [self updatePreview];
    [self updateHero];
}

- (void)showSummary {
    if (self.model.busy) {
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
    [self reloadChecks];
}

/// Return on the list: checks every selected photo (a group row stands for
/// its photos), or unchecks them all if they are all checked already.
- (void)toggleCheckSelection:(id)sender {
    NSMutableOrderedSet<NSString *> *identifiers = [NSMutableOrderedSet orderedSet];
    [self.outlineView.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *) {
        MCPhotoNode *node = [self.outlineView itemAtRow:(NSInteger)row];
        for (MCPhotoNode *leaf in node.item != nil ? @[ node ] : node.children) {
            if (leaf.item != nil) {
                [identifiers addObject:leaf.item.identifier];
            }
        }
    }];
    if (identifiers.count == 0) {
        return;
    }
    if ([identifiers.set isSubsetOfSet:self.checked]) {
        [self.checked minusSet:identifiers.set];
    } else {
        [self.checked unionSet:identifiers.set];
    }
    [self reloadChecks];
}

/// Checks every copy in the shown duplicate groups except the best one.
- (void)checkCopies:(id)sender {
    for (NSArray<MCPhotoItem *> *group in self.groups) {
        for (NSUInteger i = 1; i < group.count; ++i) {
            [self.checked addObject:group[i].identifier];
        }
    }
    [self reloadChecks];
}

- (void)reloadChecks {
    // Update the boxes in place: reloadData would drop the selection and the
    // scroll position. Rows scrolled in later are built from `checked`, and
    // the same photo may have a second row in the other section.
    NSOutlineView *outline = self.outlineView;
    const NSInteger column = [outline columnWithIdentifier:kCheckColumn];
    const NSRange visible = [outline rowsInRect:outline.visibleRect];
    for (NSUInteger row = visible.location; row < NSMaxRange(visible); ++row) {
        MCPhotoItem *item = [(MCPhotoNode *)[outline itemAtRow:(NSInteger)row] item];
        NSButton *box = [outline viewAtColumn:column row:(NSInteger)row makeIfNecessary:NO];
        if (item != nil && [box isKindOfClass:[NSButton class]]) {
            box.state = [self.checked containsObject:item.identifier] ? NSControlStateValueOn : NSControlStateValueOff;
        }
    }
    [self updateTrashButton];
    [self showSummary];
}

- (void)updateTrashButton {
    self.checkCopiesButton.enabled = !self.model.busy && self.groups.count > 0;
    self.trashButton.title = self.scanRoot == nil && self.items.count > 0 ? @"Delete from Photos…" : @"Remove…";
    self.trashButton.enabled = !self.model.busy && [self checkedItems].count > 0;
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
    alert.messageText = @"Remove the checked photos?";
    alert.informativeText = [NSString stringWithFormat:
        @"%lu photo(s), %@. Back Up & Delete moves them into a folder you choose, keeping their "
        @"subfolders, and stores JPEG, PNG and TIFF as HEIC (about half the size).",
        (unsigned long)selected.count, humanSize(total)];
    [alert addButtonWithTitle:@"Move to Trash"];
    [alert addButtonWithTitle:@"Back Up & Delete…"];
    [alert addButtonWithTitle:@"Delete Permanently…"].hasDestructiveAction = YES;
    [alert addButtonWithTitle:@"Cancel"];

    __weak MCPhotosViewController *weakSelf = self;
    [alert beginSheetModalForWindow:self.view.window
                  completionHandler:^(NSModalResponse response) {
                      if (response == NSAlertFirstButtonReturn) {
                          [weakSelf removeItems:selected how:MCPhotoRemovalTrash backupFolder:nil];
                      } else if (response == NSAlertSecondButtonReturn) {
                          // Let the sheet close before the panel takes its place.
                          dispatch_async(dispatch_get_main_queue(), ^{
                              [weakSelf chooseBackupFolderForItems:selected];
                          });
                      } else if (response == NSAlertThirdButtonReturn) {
                          dispatch_async(dispatch_get_main_queue(), ^{
                              [weakSelf confirmPermanentDeleteOfItems:selected size:total];
                          });
                      }
                  }];
}

- (void)chooseBackupFolderForItems:(NSArray<MCPhotoItem *> *)selected {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.canCreateDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.message = @"Choose a backup folder outside the scanned folder.";
    panel.prompt = @"Back Up & Delete";
    panel.directoryURL = [NSURL fileURLWithPath:self.scanRoot.stringByDeletingLastPathComponent isDirectory:YES];
    panel.delegate = self;

    __weak MCPhotosViewController *weakSelf = self;
    [panel beginSheetModalForWindow:self.view.window
                  completionHandler:^(NSModalResponse response) {
                      if (response == NSModalResponseOK && panel.URL != nil) {
                          [weakSelf removeItems:selected how:MCPhotoRemovalBackup backupFolder:panel.URL.path];
                      }
                  }];
}

/// Refuses a backup folder inside the scanned one while the panel is still
/// open; the model checks again, but only after the user has committed.
- (BOOL)panel:(id)sender validateURL:(NSURL *)url error:(NSError **)outError {
    NSString *root = [NSURL fileURLWithPath:self.scanRoot].URLByResolvingSymlinksInPath.path;
    NSString *chosen = url.URLByResolvingSymlinksInPath.path;
    if (![chosen isEqualToString:root] && ![chosen hasPrefix:[root stringByAppendingString:@"/"]]) {
        return YES;
    }
    if (outError != nullptr) {
        *outError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteInvalidFileNameError userInfo:@{
            NSLocalizedDescriptionKey : @"Choose a folder outside the scanned folder.",
            NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:
                @"Backups inside %@ would be scanned again as duplicates.", root.lastPathComponent],
        }];
    }
    return NO;
}

- (void)confirmPermanentDeleteOfItems:(NSArray<MCPhotoItem *> *)selected size:(unsigned long long)total {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleCritical;
    alert.messageText = [NSString stringWithFormat:@"Permanently delete %lu photo(s)?", (unsigned long)selected.count];
    alert.informativeText = [NSString stringWithFormat:@"%@ will be deleted. This cannot be undone.", humanSize(total)];
    NSButton *cancel = [alert addButtonWithTitle:@"Cancel"];
    NSButton *destroy = [alert addButtonWithTitle:@"Delete Permanently"];
    destroy.hasDestructiveAction = YES;
    // Return must not destroy anything.
    cancel.keyEquivalent = @"\r";
    destroy.keyEquivalent = @"";

    __weak MCPhotosViewController *weakSelf = self;
    [alert beginSheetModalForWindow:self.view.window
                  completionHandler:^(NSModalResponse response) {
                      if (response == NSAlertSecondButtonReturn) {
                          [weakSelf removeItems:selected how:MCPhotoRemovalPermanent backupFolder:nil];
                      }
                  }];
}

/// Runs off the main thread like a scan: Stop and the spinner stay live, the
/// other actions wait for the completion.
- (void)removeItems:(NSArray<MCPhotoItem *> *)selected
                how:(MCPhotoRemoval)how
       backupFolder:(nullable NSString *)backupFolder {
    NSArray<NSString *> *paths = [selected valueForKey:@"identifier"];
    NSDictionary<NSString *, MCPhotoItem *> *byPath = [NSDictionary dictionaryWithObjects:selected forKeys:paths];
    const NSUInteger count = selected.count;
    NSString *verb = how == MCPhotoRemovalTrash ? @"Moving to Trash" : how == MCPhotoRemovalBackup ? @"Backing up" : @"Deleting";

    __weak MCPhotosViewController *weakSelf = self;
    [self.model removeFiles:paths
        underScanRoot:self.scanRoot
        how:how
        backupFolder:backupFolder
        progress:^(uint64_t done, NSString *current) {
            weakSelf.statusLabel.stringValue =
                [NSString stringWithFormat:@"%@ %llu of %lu · %@", verb, done + 1, (unsigned long)count, current];
        }
        completion:^(NSSet<NSString *> *removed, NSArray<NSString *> *problems, uint64_t storedBytes) {
            [weakSelf finishRemovalOf:removed items:byPath how:how stored:storedBytes problems:problems];
        }];
    if (!self.model.busy) {
        return; // a scan is running
    }
    self.folderButton.enabled = NO;
    self.libraryButton.enabled = NO;
    self.stopButton.hidden = NO;
    self.stopButton.enabled = YES;
    [self.spinner startAnimation:nil];
    self.statusLabel.stringValue = [NSString stringWithFormat:@"%@ %lu photo(s)…", verb, (unsigned long)count];
    [self updateTrashButton];
}

- (void)finishRemovalOf:(NSSet<NSString *> *)removed
                  items:(NSDictionary<NSString *, MCPhotoItem *> *)byPath
                    how:(MCPhotoRemoval)how
                 stored:(uint64_t)stored
               problems:(NSArray<NSString *> *)problems {
    self.folderButton.enabled = YES;
    self.libraryButton.enabled = YES;
    self.stopButton.hidden = YES;
    [self.spinner stopAnimation:nil];

    unsigned long long freed = 0;
    for (NSString *path in removed) {
        freed += byPath[path].sizeBytes;
    }
    [self dropItemsWithIdentifiers:removed];

    NSString *done = how == MCPhotoRemovalTrash ? @"Moved %lu photo(s) to Trash"
                     : how == MCPhotoRemovalBackup ? @"Backed up and removed %lu photo(s)"
                                                   : @"Deleted %lu photo(s)";
    NSString *size = how == MCPhotoRemovalBackup
                         ? [NSString stringWithFormat:@"%@ stored as %@", humanSize(freed), humanSize(stored)]
                         : [NSString stringWithFormat:@"freed %@", humanSize(freed)];
    self.statusLabel.stringValue = [NSString stringWithFormat:@"%@ · %@%@",
        [NSString stringWithFormat:done, (unsigned long)removed.count], size,
        problems.count > 0 ? [NSString stringWithFormat:@" · %lu failed", (unsigned long)problems.count] : @""];
    if (problems.count == 0) {
        return;
    }
    // Thousands of identical lines would make the sheet taller than the screen.
    const NSUInteger shown = MIN(problems.count, (NSUInteger)15);
    NSString *details = [[problems subarrayWithRange:NSMakeRange(0, shown)] componentsJoinedByString:@"\n"];
    if (problems.count > shown) {
        details = [details stringByAppendingFormat:@"\n… and %lu more", (unsigned long)(problems.count - shown)];
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Some photos were left in place";
    alert.informativeText = details;
    [alert addButtonWithTitle:@"OK"];
    [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
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
    self.previewPlaceholder.hidden = (item != nil);
    self.largePreviewButton.enabled = (item != nil);
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

/// Space: closes an open large preview, otherwise opens one.
- (void)toggleLargePreview:(id)sender {
    if (self.largePreviewWindow.isVisible) {
        [self.largePreviewWindow orderOut:nil];
    } else {
        [self showLargePreview:sender];
    }
}

/// Double-click, Space or the Large Preview button. Folder photos use the
/// Quick Look panel (zoom, arrow through the selection, like Finder); library
/// photos have no file to hand Quick Look, so they get a plain image window.
- (void)showLargePreview:(id)sender {
    MCPhotoItem *item = [self selectedItems].firstObject;
    if (item == nil) {
        return;
    }
    if (!item.isLibraryAsset) {
        [self togglePreviewPanel:sender];
        return;
    }
    if (self.largePreviewWindow == nil) {
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 900, 680)
                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                        backing:NSBackingStoreBuffered
                          defer:YES];
        window.releasedWhenClosed = NO;
        NSImageView *imageView = imageViewWithoutIntrinsicSize();
        imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
        window.contentView = imageView;
        [window center];
        self.largePreviewWindow = window;
    }
    self.largePreviewWindow.title = item.name;
    NSImageView *imageView = (NSImageView *)self.largePreviewWindow.contentView;
    imageView.image = self.previewView.image; // shown at once, sharpened below
    [self.largePreviewWindow makeKeyAndOrderFront:nil];

    __weak MCPhotosViewController *weakSelf = self;
    [self.model imageForItem:item
                   maxPixels:kLargePreviewPixels
                  completion:^(NSImage *image) {
                      if (image != nil && [weakSelf.largePreviewWindow.title isEqualToString:item.name]) {
                          imageView.image = image;
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
    // An open large preview follows the selection, as the Quick Look panel does.
    if (self.largePreviewWindow.isVisible && [self selectedItems].firstObject.isLibraryAsset) {
        [self showLargePreview:nil];
    }
}

@end
