# Theme refresh and Smart Optimize Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A vivid aurora + glass theme with Liquid Glass on macOS 26+, a
Smart Optimize button on Home that orchestrates the existing tools, and a
modernized app icon.

**Architecture:** Theme work stays in the shared components (`MCTheme`,
new `MCAuroraView`, `MCHeroView`, `MCToolBanner`, `MCHomeViewController`,
`MCSplashWindow`, sidebar). Smart Optimize is one orchestrator
(`MCSmartOptimizer`) over the existing `MC*Model` classes plus a review
sheet; the only new rule is a core function with a unit test.

**Tech Stack:** C++20 core, Objective-C++ AppKit, Core Animation, CMake +
Ninja.

**Spec:** `docs/superpowers/specs/2026-11-01-theme-smart-optimize-design.md`

## Global Constraints

- Deployment target stays macOS 14.0. Every macOS 26 API is behind
  `if (@available(macOS 26.0, *))`.
- The build has no warnings; `ctest --test-dir build --output-on-failure`
  passes.
- Nothing is deleted or killed without the review sheet's confirm button.
  Deletes go through `MCScanModel cleanSelectedPermanently:NO` (Trash);
  kills through `MCProcessModel killPid:force:NO`.
- Reduce Motion (`NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion`)
  stops aurora, pulse and orbit animations. Reduce Transparency
  (`accessibilityDisplayShouldReduceTransparency`) makes glass a solid colour.
- Code, comments, UI strings, commits in English. Conventional Commits. No
  `Co-Authored-By` trailer.
- Labels with changing text get low horizontal compression resistance
  (else Auto Layout grows the window).
- Work in the worktree `.claude/worktrees/theme-develop`, branch
  `theme-develop`. Scratch files go in the session scratchpad.
- Any debug hook (for example forcing the fallback path) is uncommitted and
  removed before commit.

## Review Focus

1. **Stop during a step** — the run goes to the review with partial
   results; no model keeps running in the background. Task 5 pins this with
   a live stop during the Storage step.
2. **Offline mode on** — the Updater step is "Skipped" and makes no network
   request. Task 5 runs once with offline mode on.
3. **Nothing to do** (no recommended entries, no candidates) — the apply
   button is disabled and the sheet says so; no empty clean call. Task 6.
4. **Process exits between review and apply** — counts as success, not an
   error (existing `killPid` behaviour). Task 6 summary check.
5. **Reduce Motion / Reduce Transparency on** — no animations, no glass,
   layout unchanged. Task 3 and Task 4 screenshot checks.

---

### Task 1: Core rule `isRecommendedForAutoClean`

**Files:**
- Modify: `include/maccleaner/cleaner.hpp` (next to `requiresPermanentDelete`)
- Modify: `src/cleaner.cpp`
- Test: `tests/maccleaner_tests.cpp`

**Interfaces:**
- Produces: `bool maccleaner::isRecommendedForAutoClean(Category category);`

- [ ] **Step 1: Write the failing test** `testRecommendedForAutoClean()`,
  registered in `main()` after the `requiresPermanentDelete` test:

```cpp
for (Category c : {Category::UserCaches, Category::UserLogs, Category::DiagnosticReports,
                   Category::XcodeDerivedData, Category::SimulatorCaches, Category::HomebrewCache,
                   Category::NpmCache, Category::YarnCache, Category::PipCache})
    CHECK(isRecommendedForAutoClean(c));
for (Category c : {Category::XcodeArchives, Category::XcodeDeviceSupport, Category::Trash})
    CHECK(!isRecommendedForAutoClean(c));
```

- [ ] **Step 2:** `cmake --build build 2>&1 | grep -E "error|warning"` → fails: undeclared identifier.
- [ ] **Step 3:** Implement as an exhaustive `switch` with no `default`, so
  a new category is a compile warning (`-Wswitch`).
- [ ] **Step 4:** Build clean, `ctest --test-dir build --output-on-failure` → 100% passed.
- [ ] **Step 5:** Commit `feat(core): add isRecommendedForAutoClean rule`.

### Task 2: Theme primitives — colours, glass, badges, symbols

**Files:**
- Modify: `src/gui/MCTheme.h`, `src/gui/MCTheme.mm`
- Modify: `src/gui/MCMainWindowController.mm` (symbol names in `MCToolEntry` rows)

**Interfaces:**
- Produces:
  - `typedef NS_ENUM … MCToolSmartOptimize` appended to `MCTool` (after `MCToolUninstaller`).
  - `+ (NSArray<NSColor *> *)colorsForTool:(MCTool)tool;` — three stops.
    `startColorForTool:` / `endColorForTool:` keep working (first / last stop).
  - `+ (NSView *)glassViewWithCornerRadius:(CGFloat)radius;` — `NSGlassEffectView`
    on 26+, else `NSVisualEffectView` (material `NSVisualEffectMaterialPopover`,
    blending `NSVisualEffectBlendingModeWithinWindow`, layer corner radius,
    0.5 pt border white 0.25 alpha). Reduce Transparency → plain view with
    `NSColor.windowBackgroundColor` layer fill.
  - `+ (BOOL)reduceMotion;` — reads the NSWorkspace flag.
  - `badgeWithSymbol:size:tool:` redrawn: gradient tile, top glass highlight
    (white 0.35 → 0 linear over the top 50%), soft drop shadow inside the
    canvas, symbol with `NSImageSymbolConfiguration
    configurationWithHierarchicalColor:NSColor.whiteColor` (macOS 12+).
  - `MCGlassButton`: on 26+, pill styles set `bezelStyle = NSBezelStyleGlass`,
    `bordered = YES`, `bezelColor` = tool start colour (primary) and use the
    system drawing (skip `drawRect:`). Round style and fallback: draw a top
    highlight, an inner shadow, hover glow (`NSTrackingArea`, `mouseEntered/Exited`).
- Symbols per spec table; Smart Optimize = `wand.and.stars`.

- [ ] **Step 1:** Check each symbol exists on the macOS 14 SDK level: write
  a scratchpad ObjC snippet that calls `imageWithSystemSymbolName:` for each
  name and prints missing ones; replace any missing with the nearest older
  name and note it in the commit body.
- [ ] **Step 2:** Implement the interfaces above; Smart Optimize gradient
  `{0xa21caf, 0x7c3aed, 0x06b6d4}` (fuchsia → violet → cyan). Other tools:
  add a saturated middle stop between the existing two.
- [ ] **Step 3:** Build with no warnings; run the app; `screencapture -x`
  of the sidebar and Home cards → new badges visible.
- [ ] **Step 4:** Commit `feat(gui): add glass, three-stop gradients and new badges`.

### Task 3: `MCAuroraView` and animated hero / banner / splash

**Files:**
- Create: `src/gui/MCAuroraView.h`, `src/gui/MCAuroraView.mm`; add to `CMakeLists.txt` GUI sources
- Modify: `src/gui/MCHeroView.mm`, `src/gui/MCToolBanner.mm`, `src/gui/MCSplashWindow.mm`

**Interfaces:**
- Produces: `@interface MCAuroraView : NSView - (instancetype)initWithTool:(MCTool)tool;`
  — layer-backed; base `gradientLayerForTool:` plus three
  `kCAGradientLayerRadial` blobs (one per colour stop, white-tinted
  centre → clear edge, ~60% of the view's size). Each blob gets an
  autoreversing `position` animation, durations 12, 16, 20 s. No
  animations when `MCTheme.reduceMotion`. Blobs relayout in `layout`.
- `MCHeroView`: replace its gradient layer with an `MCAuroraView` filling
  the view. Scanning adds a `CAShapeLayer` progress arc (indeterminate:
  animated `strokeEnd`) and three 6 pt glowing dots orbiting the emblem
  (rotation animations on a container layer, 3 s, phase-shifted). The round
  button gets a pulsing halo (`CAShapeLayer`, `transform.scale` 1 → 1.15 +
  `opacity` 0.6 → 0, 1.8 s repeat). `setPresented:` animates: alpha 0 → 1
  and scale 0.97 → 1 over 0.25 s (NSAnimationContext). All gated by
  `reduceMotion`.
- `MCToolBanner`: aurora background; value + caption sit on
  `glassViewWithCornerRadius:12`.
- `MCSplashWindow`: aurora background for `MCToolHome`.

- [ ] **Step 1:** Implement `MCAuroraView`; add to CMake.
- [ ] **Step 2:** Wire into hero, banner, splash.
- [ ] **Step 3:** Build no warnings. Screenshots: one hero idle, one hero
  scanning (Storage Cleaner), one banner, the splash. Then System Settings
  Reduce Motion on (the user toggles it, or `defaults write com.apple.universalaccess reduceMotion -bool true` if permitted) → screenshot, no animation.
- [ ] **Step 4:** Commit `feat(gui): animated aurora hero, banner and splash`.

### Task 4: Home redesign — hover cards and Smart Optimize hero shell

**Files:**
- Modify: `src/gui/MCHomeViewController.h`, `src/gui/MCHomeViewController.mm`

**Interfaces:**
- Consumes: `glassViewWithCornerRadius:`, `MCAuroraView`, `MCGlassButton`
  round style, `MCToolSmartOptimize`.
- Produces (used by Task 6): in the .mm, a top section with
  - `MCGlassButton` round titled "Optimize" (action `-startSmartOptimize:`),
  - checkbox "Also scan Photos" (`self.includePhotosCheckbox`, off),
  - a glass step-list card (`NSStackView`, hidden while idle) with one row
    per step: status image view + title label + detail label,
  - a Stop button (`-stopSmartOptimize:`), visible while running,
  - a sticky result label for the last summary.
- `MCHomeCard`: on hover (`NSTrackingArea`) animate layer
  `transform` to scale 1.03 around the centre and shadow radius 6 → 14
  over 0.15 s; card background is a glass view. Reduce Motion → no scale.

- [ ] **Step 1:** Implement the layout with the action methods as empty
  stubs that log nothing (Task 6 fills them).
- [ ] **Step 2:** Build no warnings; screenshot Home idle in light and dark
  mode; hover screenshot via a temporary env-var hook that forces the
  hovered state (no Accessibility permission to move the pointer), removed
  before commit.
- [ ] **Step 3:** Commit `feat(gui): redesign Home with glass cards and Optimize hero`.

### Task 5: `MCSmartOptimizer` orchestrator

**Files:**
- Create: `src/gui/MCSmartOptimizer.h`, `src/gui/MCSmartOptimizer.mm`; add to CMake

**Interfaces:**
- Consumes: `isRecommendedForAutoClean` (Task 1) via
  `MCCategoryNode.rawCategory` cast to `maccleaner::Category`; the existing
  models' methods exactly as in their headers.
- Produces:

```objc
typedef NS_ENUM(NSInteger, MCSmartStep) {
    MCSmartStepStorage, MCSmartStepLargeFiles, MCSmartStepPhotos,
    MCSmartStepProcesses, MCSmartStepUpdater, MCSmartStepAntivirus,
};
typedef NS_ENUM(NSInteger, MCSmartStepState) {
    MCSmartStepStateWaiting, MCSmartStepStateRunning, MCSmartStepStateDone,
    MCSmartStepStateSkipped, MCSmartStepStateFailed,
};
@interface MCSmartOptimizer : NSObject
@property(nonatomic, readonly) BOOL running;
@property(nonatomic, strong, readonly) MCScanModel *scanModel;      // categories + selection after Storage
@property(nonatomic, strong, readonly) MCProcessModel *processModel;
@property(nonatomic, copy, readonly) NSArray<MCOptimizationCandidate *> *candidates;
@property(nonatomic, copy, readonly) NSArray<MCBigFileItem *> *largeFiles;
@property(nonatomic, readonly) NSUInteger photoGroupCount;
@property(nonatomic, readonly) unsigned long long photoExtraBytes;
@property(nonatomic, readonly) NSUInteger upgradableCount;
@property(nonatomic, copy, readonly) NSArray<MCMalwareFinding *> *findings;
- (MCSmartStepState)stateOfStep:(MCSmartStep)step;
- (NSString *)summaryOfStep:(MCSmartStep)step; // one line, "" while waiting
- (void)runIncludingPhotos:(BOOL)photos
               stepChanged:(void (^)(MCSmartStep step))stepChanged
                completion:(void (^)(BOOL cancelled))completion;
- (void)stop;
- (void)applyWithCompletion:(void (^)(NSString *summary))completion;
@end
```

- Steps run strictly one after another (each starts in the previous
  step's completion block). Values: Large Files root `NSHomeDirectory()`,
  `minSizeBytes` 500 MB (`500ull * 1000 * 1000`), `maxResults` 10. Photos
  root `~/Pictures`, distance `maccleaner::photos::kDefaultMaxDistance`;
  `photoExtraBytes` = sum of sizes of every item except the first in each
  group. Updater skipped (state Skipped, summary "Offline mode") when
  `MCSettings.offlineMode`; summary for a disabled Photos step "Not
  selected".
- `stop` sets a flag and calls `cancelScan` / `cancel` on the current
  model; remaining steps become Skipped; completion gets `cancelled = YES`.
- After Storage: for each category, `setAllEntriesSelected:` with
  `isRecommendedForAutoClean(category)`.
- `applyWithCompletion:`: first `cleanSelectedPermanently:NO`, then for
  each candidate with `selected == YES`, `killPid:force:NO`; summary
  "<size> moved to the Trash, <n> processes quit" (omit a part that is
  zero; "Nothing changed" when both are zero). Errors from the clean
  summary's `problems` and failed kills append " — <n> problems".

- [ ] **Step 1:** Implement; wire Home's `-startSmartOptimize:` /
  `-stopSmartOptimize:` to it, updating the step rows from `stepChanged`.
- [ ] **Step 2:** Build no warnings. Live run on this Mac with Photos off →
  every step reaches Done or Skipped; screenshot the step list.
- [ ] **Step 3:** Live run, press Stop during Storage → remaining steps
  Skipped, no further progress (Review Focus 1).
- [ ] **Step 4:** Live run with offline mode on → Updater "Offline mode"
  (Review Focus 2).
- [ ] **Step 5:** Commit `feat(gui): add Smart Optimize orchestrator`.

### Task 6: Review sheet and apply

**Files:**
- Create: `src/gui/MCSmartReviewController.h`, `src/gui/MCSmartReviewController.mm`; add to CMake
- Modify: `src/gui/MCHomeViewController.mm`

**Interfaces:**
- Consumes: `MCSmartOptimizer` (Task 5), `MCHomeViewController.openTool`.
- Produces:

```objc
@interface MCSmartReviewController : NSWindowController
- (instancetype)initWithOptimizer:(MCSmartOptimizer *)optimizer;
@property(nonatomic, copy, nullable) void (^openTool)(MCTool tool);
@property(nonatomic, copy, nullable) void (^didApply)(NSString *summary);
@end
```

- Layout follows `MCOptimizeSheetController` (the existing review sheet):
  glass header with the Smart Optimize badge and total reclaimable size;
  scrolling `NSStackView` of sections in step order. Storage: one checkbox
  row per category with selected bytes > 0 (checkbox toggles
  `setAllEntriesSelected:`). Processes: one checkbox row per candidate
  (`name — reason`, bound to `selected`). Report rows: Large Files
  ("<n> files over 500 MB, <size>"), Photos, Updater ("<n> updates
  available"), Antivirus ("<n> findings" or "No threats found"), each with
  an "Open" button → `openTool(MCToolLargeFiles / Photos / Updater /
  Antivirus)` after ending the sheet.
- Buttons: "Cancel" (Esc) and "Move to Trash & Quit Processes" (default),
  disabled when nothing is checked; with nothing to do the header reads
  "Your Mac is in good shape" (Review Focus 3).
- Apply: disable both buttons, show a spinner, call
  `applyWithCompletion:`, then `didApply(summary)` and end the sheet. Home
  shows the summary in its sticky result label.

- [ ] **Step 1:** Implement; Home presents it with `beginSheet:` when the
  run completes (also after Stop).
- [ ] **Step 2:** Build no warnings. Live run → screenshot of the review
  sheet. Check that only recommended categories and recommended processes
  are checked.
- [ ] **Step 3:** STOP and ask the user before pressing apply on the real
  machine. After the user's yes: apply, screenshot Home's summary, check
  the Trash for the moved cache folders (`ls ~/.Trash | head`).
- [ ] **Step 4:** Commit `feat(gui): add Smart Optimize review and apply`.

### Task 7: App icon

**Files:**
- Modify: `tools/make_icon.m`, `resources/MacCleaner.icns`

- [ ] **Step 1:** Redraw per spec Part 3: three-stop tile gradient
  `{0x4338ca, 0x2563eb, 0x0891b2}`, radial aurora blob top-left (cyan, 0.45
  alpha), top-half reflection (white 0.22 → 0), 1.5 pt inner edge highlight
  (white 0.5 at top fading to 0.1), tile drop shadow inside the 1024 canvas;
  large sparkle filled white → `0xdbeafe` with a 2 pt white specular stroke
  at 0.8 alpha and a coloured shadow (`0x1e3a8a`, 0.45); small sparkles
  unchanged positions. Update the file's design comment.
- [ ] **Step 2:** `sh tools/build_icon.sh`; render the PNG at 16, 32, 128,
  1024 px into the scratchpad (`sips -z`) and look at each with Read → the
  sparkle silhouette is legible at 16 px.
- [ ] **Step 3:** Commit `feat(icon): modernize app icon with glass depth`.

### Task 8: Verification on both paths, README

**Files:**
- Modify: `README.md`

- [ ] **Step 1:** Clean configure + build + test:
  `cmake --build build 2>&1 | grep -cE "warning|error"` → `0`;
  `ctest --test-dir build --output-on-failure` → 100% passed.
- [ ] **Step 2:** Screenshots on this Mac (macOS 26+ path): Home, a hero,
  a banner, the step list, the review sheet, the splash.
- [ ] **Step 3:** Fallback path: add an uncommitted env-var hook
  (`MC_FORCE_LEGACY_GLASS=1` read in `glassViewWithCornerRadius:` and
  `MCGlassButton`) → same screenshots; remove the hook; `git diff` shows
  it gone.
- [ ] **Step 4:** README: a Smart Optimize section (steps, what is applied,
  what only reports, Trash default, safety re-checks), the new look
  (Liquid Glass on 26+, fallback on 14–25, Reduce Motion/Transparency).
- [ ] **Step 5:** Commit `docs: describe Smart Optimize and the new theme`.
