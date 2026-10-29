#import "MCOrganizerViewController.h"

#import <MapKit/MapKit.h>

#import "MCHeroView.h"
#import "MCOrganizerModel.h"
#import "MCTheme.h"
#import "MCToolBanner.h"

namespace {

NSString *const kSourceKey = @"MCOrganizerSource";
NSString *const kDestinationKey = @"MCOrganizerDestination"; // absent = the source itself
NSString *const kByPlaceKey = @"MCOrganizerByPlace";
NSString *const kSymbol = @"folder.badge.gearshape";

// A label whose text changes: compressible, so a long path truncates instead
// of Auto Layout growing the window.
NSTextField *pathLabel(NSString *text) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [label setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    return label;
}

} // namespace

@interface MCOrganizerViewController () <NSOutlineViewDataSource, NSOutlineViewDelegate>
@property(nonatomic, strong) MCOrganizerModel *model;
@property(nonatomic, copy, nullable) NSString *source;
@property(nonatomic, copy, nullable) NSString *destination; // nil = source
@property(nonatomic, copy) NSArray<MCOrganizerGroup *> *groups;
@property(nonatomic) NSUInteger moveCount;
@property(nonatomic) BOOL hasPreview;

@property(nonatomic, strong) MCHeroView *hero;
@property(nonatomic, strong) MCToolBanner *banner;
@property(nonatomic, strong) NSTextField *sourceLabel;
@property(nonatomic, strong) NSTextField *destinationLabel;
@property(nonatomic, strong) NSPopUpButton *layoutPopUp;
@property(nonatomic, strong) NSSegmentedControl *viewSwitch;
@property(nonatomic, strong) NSScrollView *outlineScroll;
@property(nonatomic, strong) NSOutlineView *outlineView;
@property(nonatomic, strong) MKMapView *mapView;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSButton *organizeButton;
@property(nonatomic, strong) NSButton *previewButton;
@end

@implementation MCOrganizerViewController

- (instancetype)init {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _model = [[MCOrganizerModel alloc] init];
        _groups = @[];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        _source = [defaults stringForKey:kSourceKey];
        _destination = [defaults stringForKey:kDestinationKey];
    }
    return self;
}

- (NSString *)effectiveDestination {
    return self.destination != nil ? self.destination : self.source;
}

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 720, 560)];

    // --- folders, layout and view switch ---------------------------------
    self.sourceLabel = pathLabel(@"");
    self.destinationLabel = pathLabel(@"");
    NSButton *chooseSource = [NSButton buttonWithTitle:@"Choose…" target:self action:@selector(chooseSource:)];
    NSButton *chooseDestination = [NSButton buttonWithTitle:@"Choose…" target:self action:@selector(chooseDestination:)];

    self.layoutPopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.layoutPopUp addItemsWithTitles:@[ @"Photos by Content", @"Photos by Place" ]];
    self.layoutPopUp.toolTip = @"Place looks up country, province and city with Apple Maps "
                               @"(one rounded location per ~5 km is sent; results are cached).";
    [self.layoutPopUp selectItemAtIndex:[NSUserDefaults.standardUserDefaults boolForKey:kByPlaceKey] ? 1 : 0];
    self.layoutPopUp.target = self;
    self.layoutPopUp.action = @selector(layoutChanged:);

    self.viewSwitch = [NSSegmentedControl segmentedControlWithLabels:@[ @"Folders", @"Map" ]
                                                        trackingMode:NSSegmentSwitchTrackingSelectOne
                                                              target:self
                                                              action:@selector(viewSwitched:)];
    self.viewSwitch.selectedSegment = 0;

    NSStackView *sourceRow = [NSStackView stackViewWithViews:@[
        [NSTextField labelWithString:@"Folder:"], self.sourceLabel, chooseSource
    ]];
    NSStackView *destinationRow = [NSStackView stackViewWithViews:@[
        [NSTextField labelWithString:@"Into:"], self.destinationLabel, chooseDestination, self.layoutPopUp,
        self.viewSwitch
    ]];
    NSStackView *topBar = [NSStackView stackViewWithViews:@[ sourceRow, destinationRow ]];
    topBar.orientation = NSUserInterfaceLayoutOrientationVertical;
    topBar.alignment = NSLayoutAttributeLeading;
    topBar.spacing = 6;
    topBar.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSStackView *row in @[ sourceRow, destinationRow ]) {
        [row.widthAnchor constraintEqualToAnchor:topBar.widthAnchor].active = YES;
    }

    // --- outline of the planned folders, and the map ---------------------
    self.outlineView = [[NSOutlineView alloc] initWithFrame:NSZeroRect];
    NSTableColumn *nameColumn = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    nameColumn.title = @"Folder";
    NSTableColumn *countColumn = [[NSTableColumn alloc] initWithIdentifier:@"count"];
    countColumn.title = @"Files";
    countColumn.width = 80;
    [self.outlineView addTableColumn:nameColumn];
    [self.outlineView addTableColumn:countColumn];
    self.outlineView.outlineTableColumn = nameColumn;
    self.outlineView.dataSource = self;
    self.outlineView.delegate = self;
    self.outlineView.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;

    self.outlineScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.outlineScroll.documentView = self.outlineView;
    self.outlineScroll.hasVerticalScroller = YES;
    self.outlineScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [MCTheme styleCard:self.outlineScroll];

    self.mapView = [[MKMapView alloc] initWithFrame:NSZeroRect];
    self.mapView.translatesAutoresizingMaskIntoConstraints = NO;
    self.mapView.hidden = YES;
    self.mapView.wantsLayer = YES;
    self.mapView.layer.cornerRadius = 10;

    // --- status and actions ----------------------------------------------
    self.statusLabel = pathLabel(@"");
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.organizeButton = [MCGlassButton buttonWithTitle:@"Organize" style:MCGlassButtonStylePillPrimary
                                                    tool:MCToolOrganizer target:self action:@selector(organize:)];
    self.previewButton = [MCGlassButton buttonWithTitle:@"Preview" style:MCGlassButtonStylePill
                                                   tool:MCToolOrganizer target:self action:@selector(previewOrStop:)];
    self.banner = [[MCToolBanner alloc] initWithTool:MCToolOrganizer symbol:kSymbol];
    self.banner.actions = @[ self.previewButton, self.organizeButton ];

    self.hero = [[MCHeroView alloc] initWithTool:MCToolOrganizer
                                          symbol:kSymbol
                                           title:@"File Organizer"
                                        subtitle:@"Sort a folder into Photos, Videos, Music and Documents."];
    self.hero.actions = @[
        [MCGlassButton buttonWithTitle:@"Preview" style:MCGlassButtonStyleRound tool:MCToolOrganizer
                                target:self action:@selector(previewOrStop:)],
        [MCGlassButton buttonWithTitle:@"Choose Folder…" style:MCGlassButtonStylePill tool:MCToolOrganizer
                                target:self action:@selector(chooseSource:)],
    ];
    self.hero.scanningAccessory = [MCGlassButton buttonWithTitle:@"Stop" style:MCGlassButtonStylePill
                                                            tool:MCToolOrganizer target:self
                                                          action:@selector(previewOrStop:)];

    for (NSView *view in @[ self.banner, topBar, self.outlineScroll, self.mapView, self.statusLabel, self.hero ]) {
        [self.view addSubview:view];
    }
    const CGFloat margin = 16;
    [NSLayoutConstraint activateConstraints:@[
        [self.banner.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.banner.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [self.banner.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],

        [topBar.topAnchor constraintEqualToAnchor:self.banner.bottomAnchor constant:12],
        [topBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [topBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],

        [self.outlineScroll.topAnchor constraintEqualToAnchor:topBar.bottomAnchor constant:12],
        [self.outlineScroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [self.outlineScroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],

        [self.mapView.topAnchor constraintEqualToAnchor:self.outlineScroll.topAnchor],
        [self.mapView.bottomAnchor constraintEqualToAnchor:self.outlineScroll.bottomAnchor],
        [self.mapView.leadingAnchor constraintEqualToAnchor:self.outlineScroll.leadingAnchor],
        [self.mapView.trailingAnchor constraintEqualToAnchor:self.outlineScroll.trailingAnchor],

        [self.statusLabel.topAnchor constraintEqualToAnchor:self.outlineScroll.bottomAnchor constant:12],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],
        [self.statusLabel.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-margin],

        [self.hero.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.hero.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.hero.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.hero.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    [self updateLabels];
    [self updateState];
}

- (NSString *)displayPath:(NSString *)path {
    return [path stringByAbbreviatingWithTildeInPath];
}

- (void)updateLabels {
    self.sourceLabel.stringValue = self.source != nil ? [self displayPath:self.source] : @"No folder chosen";
    self.sourceLabel.toolTip = self.source;
    self.destinationLabel.stringValue =
        self.destination != nil ? [self displayPath:self.destination] : @"The same folder";
    self.destinationLabel.toolTip = self.effectiveDestination;
}

/// The start screen until the first preview; afterwards the results stay so
/// the folder and layout controls are at hand.
- (void)updateState {
    const BOOL busy = self.model.busy;
    self.banner.value = [NSString stringWithFormat:@"%lu", (unsigned long)self.moveCount];
    self.banner.caption = self.source != nil
                              ? [NSString stringWithFormat:@"file(s) to move into %@",
                                                           [self displayPath:self.effectiveDestination]]
                              : @"Choose a folder to organize";
    self.previewButton.title = busy ? @"Stop" : @"Preview";
    self.previewButton.enabled = self.source != nil;
    self.organizeButton.enabled = !busy && self.hasPreview && self.moveCount > 0;

    const BOOL presented = !self.hasPreview;
    [self.hero setPresented:presented];
    if (!presented) {
        return;
    }
    if (busy) {
        [self.hero showScanningWithStatus:@"Reading the folder…"];
    } else {
        [self.hero showIdleWithMessage:self.source != nil
                                           ? [NSString stringWithFormat:@"Organizes %@", [self displayPath:self.source]]
                                           : @"Choose the folder to organize first"];
    }
}

- (void)setStatus:(NSString *)status {
    self.statusLabel.stringValue = status;
    if (self.hero.presented) {
        [self.hero setStatus:status];
    }
}

#pragma mark - Actions

- (void)chooseFolderWithPrompt:(NSString *)prompt start:(nullable NSString *)start then:(void (^)(NSString *path))then {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.canCreateDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.prompt = prompt;
    if (start != nil) {
        panel.directoryURL = [NSURL fileURLWithPath:start isDirectory:YES];
    }
    [panel beginSheetModalForWindow:self.view.window
                  completionHandler:^(NSModalResponse response) {
                      if (response == NSModalResponseOK && panel.URLs.count > 0) {
                          then(panel.URLs.firstObject.path);
                      }
                  }];
}

- (void)invalidatePreview {
    self.hasPreview = NO;
    self.moveCount = 0;
    self.groups = @[];
    [self.outlineView reloadData];
    [self.mapView removeAnnotations:self.mapView.annotations];
    [self updateState];
}

- (void)chooseSource:(id)sender {
    if (self.model.busy) {
        return;
    }
    __weak MCOrganizerViewController *weakSelf = self;
    [self chooseFolderWithPrompt:@"Organize" start:self.source then:^(NSString *path) {
        MCOrganizerViewController *strongSelf = weakSelf;
        strongSelf.source = path;
        [NSUserDefaults.standardUserDefaults setObject:path forKey:kSourceKey];
        [strongSelf updateLabels];
        [strongSelf invalidatePreview];
    }];
}

- (void)chooseDestination:(id)sender {
    if (self.model.busy) {
        return;
    }
    __weak MCOrganizerViewController *weakSelf = self;
    [self chooseFolderWithPrompt:@"Move Here" start:self.effectiveDestination then:^(NSString *path) {
        MCOrganizerViewController *strongSelf = weakSelf;
        strongSelf.destination = [path isEqualToString:strongSelf.source] ? nil : path;
        if (strongSelf.destination != nil) {
            [NSUserDefaults.standardUserDefaults setObject:path forKey:kDestinationKey];
        } else {
            [NSUserDefaults.standardUserDefaults removeObjectForKey:kDestinationKey];
        }
        [strongSelf updateLabels];
        [strongSelf invalidatePreview];
    }];
}

- (void)layoutChanged:(id)sender {
    [NSUserDefaults.standardUserDefaults setBool:self.layoutPopUp.indexOfSelectedItem == 1 forKey:kByPlaceKey];
    if (self.hasPreview && !self.model.busy) {
        [self previewOrStop:nil];
    }
}

- (void)viewSwitched:(id)sender {
    const BOOL map = self.viewSwitch.selectedSegment == 1;
    self.mapView.hidden = !map;
    self.outlineScroll.hidden = map;
}

- (void)previewOrStop:(id)sender {
    if (self.model.busy) {
        [self.model cancel];
        return;
    }
    if (self.source == nil) {
        [self chooseSource:nil];
        return;
    }
    __weak MCOrganizerViewController *weakSelf = self;
    [self setStatus:@"Reading files…"];
    [self.model previewSource:self.source
        destination:self.effectiveDestination
        byPlace:self.layoutPopUp.indexOfSelectedItem == 1
        progress:^(NSString *status) {
            [weakSelf setStatus:status];
        }
        completion:^(NSArray<MCOrganizerGroup *> *groups, NSArray<MCOrganizerPin *> *pins, NSUInteger moveCount,
                     NSUInteger fileCount, NSString *error) {
            MCOrganizerViewController *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            strongSelf.groups = groups;
            strongSelf.moveCount = moveCount;
            strongSelf.hasPreview = error == nil;
            [strongSelf.outlineView reloadData];
            [strongSelf showPins:pins];
            [strongSelf setStatus:error != nil
                                      ? error
                                      : [NSString stringWithFormat:@"%lu of %lu file(s) will move; %lu photo place(s) "
                                                                   @"on the map.",
                                                                   (unsigned long)moveCount, (unsigned long)fileCount,
                                                                   (unsigned long)pins.count]];
            [strongSelf updateState];
            if (error != nil) {
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = @"This destination cannot be used";
                alert.informativeText = error;
                [alert beginSheetModalForWindow:strongSelf.view.window completionHandler:nil];
            }
        }];
    [self updateState];
}

- (void)showPins:(NSArray<MCOrganizerPin *> *)pins {
    [self.mapView removeAnnotations:self.mapView.annotations];
    NSMutableArray<MKPointAnnotation *> *annotations = [NSMutableArray array];
    for (MCOrganizerPin *pin in pins) {
        MKPointAnnotation *annotation = [[MKPointAnnotation alloc] init];
        annotation.coordinate = CLLocationCoordinate2DMake(pin.latitude, pin.longitude);
        annotation.title = [NSString stringWithFormat:@"%lu photo(s)", (unsigned long)pin.count];
        annotation.subtitle = pin.placeName;
        [annotations addObject:annotation];
    }
    [self.mapView showAnnotations:annotations animated:NO];
}

- (void)organize:(id)sender {
    if (self.model.busy || self.moveCount == 0) {
        return;
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"Move %lu file(s) into %@?", (unsigned long)self.moveCount,
                                                   [self displayPath:self.effectiveDestination]];
    alert.informativeText = @"Files are moved, not copied. Nothing is overwritten: a name that is taken gets "
                            @"a number, like \"IMG_1 (2).jpg\".";
    [alert addButtonWithTitle:@"Move"];
    [alert addButtonWithTitle:@"Cancel"];
    __weak MCOrganizerViewController *weakSelf = self;
    [alert beginSheetModalForWindow:self.view.window
                  completionHandler:^(NSModalResponse response) {
                      if (response == NSAlertFirstButtonReturn) {
                          [weakSelf performOrganize];
                      }
                  }];
}

- (void)performOrganize {
    __weak MCOrganizerViewController *weakSelf = self;
    [self.model
        organizeWithProgress:^(NSUInteger done, NSUInteger total) {
            [weakSelf setStatus:[NSString stringWithFormat:@"Moving… %lu of %lu", (unsigned long)done,
                                                           (unsigned long)total]];
        }
        completion:^(NSUInteger moved, NSArray<NSString *> *problems) {
            MCOrganizerViewController *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            [strongSelf invalidatePreview];
            strongSelf.hasPreview = YES;
            [strongSelf setStatus:[NSString stringWithFormat:@"Moved %lu file(s); %lu problem(s).",
                                                             (unsigned long)moved, (unsigned long)problems.count]];
            [strongSelf updateState];
            if (problems.count > 0) {
                [strongSelf showProblems:problems];
            }
        }];
    [self updateState];
}

- (void)showProblems:(NSArray<NSString *> *)problems {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"%lu file(s) were not moved", (unsigned long)problems.count];
    const NSUInteger shown = MIN(problems.count, (NSUInteger)20);
    NSString *list = [[problems subarrayWithRange:NSMakeRange(0, shown)] componentsJoinedByString:@"\n"];
    alert.informativeText = shown < problems.count
                                ? [list stringByAppendingFormat:@"\n… and %lu more", (unsigned long)(problems.count - shown)]
                                : list;
    [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
}

#pragma mark - NSOutlineView

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(nullable id)item {
    return (NSInteger)(item != nil ? [(MCOrganizerGroup *)item children] : self.groups).count;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(nullable id)item {
    return (item != nil ? [(MCOrganizerGroup *)item children] : self.groups)[(NSUInteger)index];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item {
    return [(MCOrganizerGroup *)item children].count > 0;
}

- (nullable NSView *)outlineView:(NSOutlineView *)outlineView
              viewForTableColumn:(nullable NSTableColumn *)tableColumn
                            item:(id)item {
    MCOrganizerGroup *group = item;
    const BOOL isCount = [tableColumn.identifier isEqualToString:@"count"];
    NSTableCellView *cell = [outlineView makeViewWithIdentifier:tableColumn.identifier owner:self];
    if (cell == nil) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = tableColumn.identifier;
        NSTextField *text = [NSTextField labelWithString:@""];
        text.translatesAutoresizingMaskIntoConstraints = NO;
        text.lineBreakMode = NSLineBreakByTruncatingTail;
        if (isCount) {
            text.alignment = NSTextAlignmentRight;
            text.textColor = NSColor.secondaryLabelColor;
        }
        [cell addSubview:text];
        cell.textField = text;
        [NSLayoutConstraint activateConstraints:@[
            [text.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
            [text.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-2],
            [text.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }
    cell.textField.stringValue = isCount ? [NSString stringWithFormat:@"%lu", (unsigned long)group.count] : group.title;
    return cell;
}

@end
