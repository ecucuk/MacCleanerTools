# Standard App Dialogs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add About, Settings, Check for Updates (GitHub Releases), the welcome tour and What's New, Help, a Full Disk Access guide, Report an Issue, and full Edit/View/Help menus to MacCleaner.app.

**Architecture:** A pure C++ `selfupdate` module parses the GitHub release JSON and compares versions; a small platform `httpGet` fetches it for the CLI and the GUI. In the GUI, `MCSettings` is the only reader of `NSUserDefaults`; each dialog is its own AppKit window controller; `main.mm` builds the menus and the app delegate owns the dialogs.

**Tech Stack:** C++20, ObjC++ / AppKit, Foundation `NSURLSession`, CMake + Ninja, the single test runner `tests/maccleaner_tests.cpp`.

**Spec:** `docs/superpowers/specs/2026-11-01-app-dialogs-design.md`

## Global Constraints

- Branch `dialogs-develop`. Never push, never merge to `main`.
- Commits: Conventional Commits, subject ≤ 72 chars, body says *why*. **No `Co-Authored-By` trailer.**
- Code, comments, UI text and docs in English. Match the style of the surrounding file.
- No new dependencies: system frameworks only. No Sparkle, no markdown renderer.
- Deployment target macOS 11.0: no API newer than macOS 11 without an `@available` guard.
- Only `MCSettings` reads or writes `NSUserDefaults`.
- With `offlineMode` on, the app makes no network request (update check, Updater tool, Uninstaller `brew info`).
- The update "Download" button opens only a `pageUrl` that `parseLatestRelease` accepted (`https://github.com/` prefix).
- Labels with changing text get low horizontal compression resistance (`NSLayoutPriorityDefaultLow`), or Auto Layout grows the window.
- Build: `cmake --build build 2>&1 | grep -E "error|warning" ; ctest --test-dir build --output-on-failure 2>&1 | tail -3`. If the build fails, ctest runs a stale binary: check the build output first.
- Never leave scratch files in the repo; leave the untracked `.vscode/` alone.

## Rulings on the spec

- **No "Toggle Sidebar" item.** `MCMainWindowController.mm` sets `side.canCollapse = NO` on purpose (a collapsed sidebar strands the user). The View menu keeps the tool items and Enter Full Screen only. The spec is updated in Task 1.
- **Large Files minimum size is a choice, not free MB.** The view has a fixed list (`kThresholds`, 50 MB … 5 GB, default 100 MB). `largeFilesMinSizeMB` stores one of those values; Settings shows the same list as a popup. The list moves to `MCSettings` so both read one source.
- **Idle-helper default.** `MCProcessModel.mm` sets `_selected = candidate.recommended`. With `idleHelperRuleDefault` on, unrecommended candidates also start selected. Today the only unrecommended candidates are the idle helpers.
- **Find (⌘F)** sends `focusSearchField:` down the responder chain. `MCMainWindowController` forwards it to the current tool if the tool responds to it. Today only `MCUninstallerViewController` does.

## Review Focus

1. A GitHub response with a `html_url` on another host, a missing `tag_name`, or a non-JSON body (an HTML error page): no crash, no browser opens, a clear message.
2. Offline mode on: zero network requests from the update check, the Updater tool and the Uninstaller. A manual check must not slip through.
3. First launch on a clean defaults domain: the splash, then the tutorial; no What's New on the same launch.
4. Rate limit (403/429) and timeout: the manual check reports the reason; the automatic check stays silent and does not move `lastUpdateCheck`.
5. ⌘1…⌘8 and ⌘0 select the right tool in sidebar order, and the sidebar selection follows.

---

### Task 1: Core `selfupdate` module

**Files:**
- Create: `include/maccleaner/selfupdate.hpp`, `src/selfupdate.cpp`
- Modify: `CMakeLists.txt` (add `src/selfupdate.cpp` to the core sources after `src/uninstaller.cpp`)
- Modify: `tests/maccleaner_tests.cpp` (new tests, registered at the end of `main()`)
- Modify: `docs/superpowers/specs/2026-11-01-app-dialogs-design.md` (View menu: remove "Toggle Sidebar (⌃⌘S)", add one line: the sidebar cannot collapse by design)

**Interfaces:**
- Consumes: `json::parse`, `json::Value::str` (`include/maccleaner/json.hpp`); `updater::compareVersions` (`include/maccleaner/updater.hpp:33`).
- Produces: namespace `maccleaner::selfupdate` with `struct Release { std::string version, name, notes, pageUrl; }`, `std::optional<Release> parseLatestRelease(std::string_view json)`, `bool isNewer(std::string_view latest, std::string_view current)`, `kLatestReleaseUrl`, `kIssuesUrl` — exact declarations as in the spec section "Core".

- [ ] **Step 1: Write the failing tests**

```cpp
void testSelfUpdateParsesRelease() {
    using namespace selfupdate;
    const auto r = parseLatestRelease(R"({"tag_name":"v0.2.0","name":"MacCleaner 0.2","body":"- Fix\n- Add","html_url":"https://github.com/ecucuk/MacCleanerTools/releases/tag/v0.2.0","draft":false})");
    CHECK(r.has_value());
    CHECK_EQ(r->version, std::string("0.2.0"));
    CHECK_EQ(r->name, std::string("MacCleaner 0.2"));
    CHECK_EQ(r->notes, std::string("- Fix\n- Add"));
    CHECK_EQ(r->pageUrl, std::string("https://github.com/ecucuk/MacCleanerTools/releases/tag/v0.2.0"));
    const auto upper = parseLatestRelease(R"({"tag_name":"V1.0","html_url":"https://github.com/x/y/releases/tag/V1.0"})");
    CHECK(upper.has_value());
    CHECK_EQ(upper->version, std::string("1.0"));
    CHECK_EQ(upper->name, std::string("V1.0")); // no "name": falls back to the tag
}

void testSelfUpdateRejectsBadRelease() {
    using namespace selfupdate;
    CHECK(!parseLatestRelease(R"({"html_url":"https://github.com/x/y"})").has_value());            // no tag
    CHECK(!parseLatestRelease("<html>rate limited</html>").has_value());                           // not JSON
    CHECK(!parseLatestRelease(R"({"tag_name":"v1","html_url":"https://evil.example/x"})").has_value());
    CHECK(!parseLatestRelease(R"({"tag_name":"v1","html_url":"http://github.com/x"})").has_value()); // not https
    CHECK(!parseLatestRelease(R"({"tag_name":"v1"})").has_value());                                // no url
}

void testSelfUpdateIsNewer() {
    using selfupdate::isNewer;
    CHECK(isNewer("0.2.0", "0.1.0"));
    CHECK(!isNewer("v0.1.0", "0.1.0"));
    CHECK(!isNewer("0.1.0", "v0.1.0"));
    CHECK(isNewer("0.1.10", "0.1.9"));
    CHECK(!isNewer("1.0.0-beta.1", "1.0.0"));
    CHECK(isNewer("1.0.0", "1.0.0-beta.1"));
    CHECK(!isNewer("0.1.0", "0.2.0"));
}
```

- [ ] **Step 2: Run the tests and make sure they fail** (`selfupdate.hpp` not found).
- [ ] **Step 3: Implement** `parseLatestRelease` and `isNewer` in `src/selfupdate.cpp`. Strip one leading `v`/`V` from both sides in `isNewer` and in `Release::version`. `notes` = `body` as is.
- [ ] **Step 4: Build and run the tests.** Expected: `All tests passed.`
- [ ] **Step 5: Commit** — `feat(core): add selfupdate release parser and version check` (includes the spec edit).

---

### Task 2: HTTP fetch and CLI `--version` / `check-update`

**Files:**
- Create: `include/maccleaner/http.hpp`, `src/platform/http_mac.mm`, `src/platform/http_fallback.cpp`
- Modify: `CMakeLists.txt` (add the two platform files to the Apple / fallback source lists next to `updater_mac.mm` / `updater_fallback.cpp`, and to the `set_source_files_properties` ARC list of the `.mm` files; add `MACCLEANER_VERSION="${PROJECT_VERSION}"` to `target_compile_definitions(maccleaner_core PUBLIC …)`)
- Modify: `include/maccleaner/cli.hpp`, `src/cli.cpp` (`Command::Version`, `Command::CheckUpdate`, usage text), `src/main.cpp` (dispatch)
- Modify: `tests/maccleaner_tests.cpp` (parse tests)

**Interfaces:**
- Consumes: Task 1 `selfupdate::*`.
- Produces:
  ```cpp
  namespace maccleaner::http {
  struct Response { int status = 0; std::string body; };
  // GET with the given headers. nullopt on a transport error or timeout
  // (no HTTP status at all). Blocks the calling thread; never call on main.
  std::optional<Response> get(const std::string& url,
                              const std::vector<std::pair<std::string, std::string>>& headers,
                              double timeoutSeconds);
  }
  ```
  `MACCLEANER_VERSION` (string macro) visible to every target that links `maccleaner_core`.

- [ ] **Step 1: Write failing parse tests:** `parseArgs` of `{"mac_cleaner","--version"}` gives `Command::Version`; `{"mac_cleaner","check-update"}` gives `Command::CheckUpdate`; `{"mac_cleaner","check-update","--apply"}` is a `CliParseError`.
- [ ] **Step 2: Run and make sure they fail.**
- [ ] **Step 3: Implement.** `http_mac.mm`: `NSURLSession` data task with a `dispatch_semaphore` wait of `timeoutSeconds + 1`; `ephemeralSessionConfiguration` (no cookies, no cache on disk). Fallback returns `nullopt`. CLI:
  - `--version` prints `mac_cleaner <MACCLEANER_VERSION>`, exit 0.
  - `check-update`: headers `Accept: application/vnd.github+json`, `User-Agent: mac_cleaner/<version>`, timeout 10 s. 404 → `up to date (no release published)`, exit 0. 200 + parsed + `isNewer` → `new version <v>: <pageUrl>`, exit 0. 200 + not newer → `up to date (<version>)`, exit 0. 403/429 → `error: GitHub rate limit reached, try again later`, exit 1. Transport error or unparsable body → `error: …`, exit 1.
- [ ] **Step 4: Build, run the tests, then run** `./build/mac_cleaner --version` (expect `mac_cleaner 0.1.0`) and `./build/mac_cleaner check-update; echo $?` (today no release exists: expect `up to date (no release published)` and `0`).
- [ ] **Step 5: Commit** — `feat(cli): add --version and check-update`.

---

### Task 3: `MCSettings`, menus and launch behavior

**Files:**
- Create: `src/gui/MCSettings.h`, `src/gui/MCSettings.mm`
- Modify: `src/gui/main.mm` (menus, delegate actions, splash setting, appearance, launch order)
- Modify: `src/gui/MCMainWindowController.h/.mm` (tool menu API, launch tool, `lastTool`, `focusSearchField:` forwarding)
- Modify: `src/gui/MCLargeFilesViewController.mm` (threshold list from `MCSettings`, default from the setting)
- Modify: `src/gui/MCProcessModel.mm` (idle-helper default)
- Modify: `src/gui/MCUninstallerViewController.mm` (implement `focusSearchField:`)
- Modify: `CMakeLists.txt` (add `src/gui/MCSettings.mm`)

**Interfaces:**
- Produces (`MCSettings.h`):
  ```objc
  typedef NS_ENUM(NSInteger, MCLaunchTool) { MCLaunchToolHome, MCLaunchToolLastUsed };
  typedef NS_ENUM(NSInteger, MCAppearance) { MCAppearanceSystem, MCAppearanceLight, MCAppearanceDark };
  extern NSNotificationName const MCSettingsDidChangeNotification;
  @interface MCSettings : NSObject
  + (void)registerDefaults;
  + (void)applyAppearance;                       // sets NSApp.appearance from `appearance`
  @property(class) BOOL showSplash;
  @property(class) MCLaunchTool launchTool;
  @property(class) MCTool lastTool;
  @property(class) BOOL checkUpdatesAtLaunch;
  @property(class, nullable, copy) NSDate *lastUpdateCheck;
  @property(class, nullable, copy) NSString *skippedVersion;
  @property(class) NSInteger largeFilesMinSizeMB; // one of largeFilesChoicesMB
  @property(class, readonly) NSArray<NSNumber *> *largeFilesChoicesMB; // 50,100,250,500,1024,5120
  @property(class) BOOL idleHelperRuleDefault;
  @property(class) MCAppearance appearance;
  @property(class) BOOL offlineMode;
  @property(class) BOOL welcomeShown;
  @property(class, nullable, copy) NSString *lastSeenVersion;
  @property(class) BOOL fullDiskAccessHintSuppressed;
  @end
  ```
  Each setter writes the default and posts `MCSettingsDidChangeNotification`; the `appearance` setter also calls `applyAppearance`. Keys and defaults: the spec table.
- Produces (`MCMainWindowController.h`): `- (NSArray<NSString *> *)toolTitles;` (sidebar order), `- (void)selectToolAtIndex:(NSInteger)index;` (now public), `- (void)showTool:(MCTool)tool;` (now public).
- Produces (`main.mm` delegate actions, used by later tasks): `showAbout:`, `showSettings:`, `checkForUpdates:`, `showHelp:`, `showWelcomeTour:`, `showWhatsNew:`, `reportIssue:`, `showFullDiskAccess:`. In this task each one except the ones fully done here is a stub that does nothing, and the matching menu item validates to **disabled** (`validateMenuItem:` returns NO) until its task lands. Do not ship a menu item that does nothing when clicked.

- [ ] **Step 1: Implement `MCSettings`.**
- [ ] **Step 2: Rebuild the menus** in `main.mm` exactly as the spec section "Menus", without Toggle Sidebar (ruling). Edit items use the standard first-responder selectors (`undo:`, `redo:`, `cut:`, `copy:`, `paste:`, `selectAll:`) with target nil. View tool items: built after the window controller exists, from `toolTitles`; Home is ⌘0 wherever it sits, the other tools get ⌘1… in sidebar order, `tag` = sidebar index, action calls `selectToolAtIndex:`. Enter Full Screen = `toggleFullScreen:` with ⌃⌘F. Window menu adds `performZoom:` and `arrangeInFront:`; set `NSApp.windowsMenu`. Help menu: set `NSApp.helpMenu` so AppKit adds its search field.
- [ ] **Step 3: Launch order** in `applicationWillFinishLaunching`: `[MCSettings registerDefaults]; [MCSettings applyAppearance];`. In `applicationDidFinishLaunching`: show the splash only if `showSplash`; the window controller selects `lastTool` if `launchTool == LastUsed` and the tool exists, else Home; every tool change writes `lastTool`.
- [ ] **Step 4: Large Files and Optimize.** Large Files builds its popup from `largeFilesChoicesMB` (label "≥ 50 MB" … "≥ 1 GB", "≥ 5 GB") and selects `largeFilesMinSizeMB`; it re-reads the setting on `MCSettingsDidChangeNotification` only while no scan runs. `MCProcessModel`: `_selected = candidate.recommended || MCSettings.idleHelperRuleDefault`.
- [ ] **Step 5: Find.** ⌘F item sends `focusSearchField:` (target nil). `MCMainWindowController` implements it: forward to `currentTool` if it responds, and validates the item only then. `MCUninstallerViewController` makes its search field first responder.
- [ ] **Step 6: Build, test, and check by running** `defaults read com.maccleaner.app` after a launch-and-quit (`open build/MacCleaner.app`, then quit with `osascript -e 'quit app "MacCleaner"'`): expect `lastTool`. Menu clicks need Accessibility, which Claude does not have: state in the report that the menu pass is a user step.
- [ ] **Step 7: Commit** — `feat(gui): add settings store and standard menus`.

---

### Task 4: Settings window and offline mode

**Files:**
- Create: `src/gui/MCSettingsWindowController.h/.mm`
- Modify: `src/gui/main.mm` (`showSettings:` opens it; enable the item)
- Modify: `src/gui/MCUpdaterViewController.mm` (offline: Check buttons disabled + hero message)
- Modify: `src/gui/MCUninstallerModel.mm` (offline: skip the `brew info` read at `MCUninstallerModel.mm:158`)
- Modify: `CMakeLists.txt`

**Interfaces:**
- Consumes: Task 3 `MCSettings`, `MCSettingsDidChangeNotification`.
- Produces: `@interface MCSettingsWindowController : NSWindowController` with `+ (instancetype)shared;` and `- (void)showTab:(NSString *)identifier;` with identifiers `@"general"`, `@"cleaning"`, `@"appearance"`, `@"privacy"`.

- [ ] **Step 1: Build the window:** `NSTabViewController` with `tabStyle = NSTabViewControllerTabStyleToolbar`, four tabs with SF Symbols (`gearshape`, `trash`, `paintbrush`, `hand.raised`) guarded by `@available(macOS 11.0, *)`, controls and texts exactly as the spec section "Settings window". Each control writes its `MCSettings` property on change. The window is not resizable; it resizes to the selected tab's fitting size.
- [ ] **Step 2: Offline mode in the Updater tool.** While `MCSettings.offlineMode` is on: both Check buttons are disabled and the hero shows `Offline mode is on — Settings › Privacy`. React to `MCSettingsDidChangeNotification`.
- [ ] **Step 3: Offline mode in the Uninstaller model:** do not run `brew info` while offline; leave `_brewRead` false so it runs once offline mode goes off.
- [ ] **Step 4: Build, test, then check:** `defaults write com.maccleaner.app offlineMode -bool YES lastTool -int <MCToolUpdater value>` with `launchTool` = LastUsed, launch, `screencapture -x` and Read it: the Check button is disabled with the offline text. List in the report every network entry point in `MCUpdaterModel.mm` and `MCUninstallerModel.mm` and the guard on each. Reset with `defaults delete com.maccleaner.app`.
- [ ] **Step 5: Commit** — `feat(gui): add Settings window and offline mode`.

---

### Task 5: Check for Updates in the app

**Files:**
- Create: `src/gui/MCUpdateChecker.h/.mm`
- Modify: `src/gui/main.mm` (`checkForUpdates:`; automatic check after launch)
- Modify: `CMakeLists.txt`

**Interfaces:**
- Consumes: Task 1 `selfupdate::*`, Task 2 `http::get`, Task 3 `MCSettings`, Task 4 `MCSettingsWindowController showTab:@"privacy"`.
- Produces: `@interface MCUpdateChecker : NSObject` with `+ (instancetype)shared;`, `- (void)checkManually;`, `- (void)checkAutomaticallyIfDue;`.

- [ ] **Step 1: Implement** on a private serial queue, results on main. Version from `CFBundleShortVersionString`. Behavior, texts and buttons exactly as the spec section "Check for Updates", steps 1–5. A second manual check while one runs is ignored. The notes show in a read-only, scrollable `NSTextView` (plain text) as the alert's `accessoryView`, max height 240 pt. "Skip This Version" writes `skippedVersion`. `lastUpdateCheck` moves only on a successful response (200 or 404).
- [ ] **Step 2: Wire** the menu item, and call `checkAutomaticallyIfDue` 3 s after launch (after the splash and the welcome window, so the dialogs do not stack).
- [ ] **Step 3: Build, test, and run the app.** Today there is no release: a manual check must report "You're up to date" (404 path). `screencapture -x` the alert and Read it. Then `defaults write com.maccleaner.app offlineMode -bool YES`, check again, capture the offline message, and delete the key.
- [ ] **Step 4: Commit** — `feat(gui): check GitHub Releases for app updates`.

---

### Task 6: About window, Report an Issue, Full Disk Access guide

**Files:**
- Create: `src/gui/MCAboutWindowController.h/.mm`, `src/gui/MCFullDiskAccess.h/.mm`
- Modify: `src/gui/main.mm` (`showAbout:`, `reportIssue:`, `showFullDiskAccess:`)
- Modify: `src/gui/MCUninstallerViewController.mm`, `src/gui/MCCleanerViewController.mm`, `src/gui/MCLargeFilesViewController.mm` (call the guide on EPERM results)
- Modify: `CMakeLists.txt` (new sources; copy `LICENSE` into `Contents/Resources` the same way as the `.icns`)

**Interfaces:**
- Consumes: Task 1 `kIssuesUrl`, Task 3 `MCSettings.fullDiskAccessHintSuppressed`.
- Produces: `+[MCAboutWindowController shared]` with `showWindow:`; `+[MCFullDiskAccess presentIfNeededForWindow:(NSWindow *)window]` (once per launch, honors the suppress flag) and `+[MCFullDiskAccess presentForWindow:]` (menu: always shows, no checkbox).

- [ ] **Step 1: About** exactly as the spec section "About window". Version line `Version <CFBundleShortVersionString> (<CFBundleVersion>)`. License text from the bundled `LICENSE`. The copyright line is the third line of `LICENSE`.
- [ ] **Step 2: Report an Issue:** build the URL with `NSURLComponents` (`queryItems` for `body`), body = `MacCleaner <version>`, `macOS <NSProcessInfo.operatingSystemVersionString>`, `CPU: arm64|x86_64` (from the build arch). Nothing else.
- [ ] **Step 3: Full Disk Access sheet** as the spec section "Full Disk Access guide". Call sites: Uninstaller results with "Needs Full Disk Access"; Storage Cleaner and Large Files results whose error is `strerror(EPERM)` or `NSPOSIXErrorDomain`/`EPERM` — find the exact result paths in each controller and list them in the report.
- [ ] **Step 4: Build, test, and check the bundle:** `ls build/MacCleaner.app/Contents/Resources/LICENSE`. Opening About and the issue page from the menu is a user step. Put the issue-URL builder in a static function and paste one example URL it produces into the report.
- [ ] **Step 5: Commit** — `feat(gui): add About window, issue report and FDA guide`.

---

### Task 7: Welcome tour, What's New and Help window

**Files:**
- Create: `src/gui/MCWelcomeWindowController.h/.mm`, `src/gui/MCHelpWindowController.h/.mm`
- Create: `resources/WhatsNew.html`, `resources/Help/getting-started.html`, `resources/Help/<tool>.html` for each of the 8 tools (`storage-cleaner`, `large-files`, `photo-cleaner`, `file-organizer`, `performance`, `antivirus`, `updater`, `uninstaller`), `resources/Help/safety.html`, `resources/Help/full-disk-access.html`, `resources/Help/command-line.html`
- Modify: `src/gui/main.mm` (`showHelp:`, `showWelcomeTour:`, `showWhatsNew:`; launch logic)
- Modify: `CMakeLists.txt` (sources; resources with `MACOSX_PACKAGE_LOCATION Resources` and `Resources/Help`)
- Modify: `README.md` (GUI section: menus, Settings, update check, offline mode; CLI: `--version`, `check-update`)

**Interfaces:**
- Consumes: Task 3 `MCSettings`, `MCTheme` badges and gradients, Task 6 `MCFullDiskAccess presentForWindow:`.
- Produces: `+[MCWelcomeWindowController shared]` with `- (void)showTour;`, `- (void)showWhatsNew;`, `- (void)showAtLaunchIfNeeded;`; `+[MCHelpWindowController shared]` with `- (void)showTopic:(nullable NSString *)topic;`.

- [ ] **Step 1: Write the HTML.** Content comes from the README sections of each tool, shortened to what a user needs: what it does, what it never touches, how to undo (Trash). One `<style>` block per file with system fonts (`-apple-system`) and no text colors: dark mode is handled in Step 3. `WhatsNew.html`: "MacCleaner 0.1.0" and one bullet per tool in this first release.
- [ ] **Step 2: Welcome window** as the spec section "Welcome window": 5 tour pages, the What's New page, Back/Next/Done, page dots. Launch logic in `showAtLaunchIfNeeded` exactly as the spec; it runs after the splash closes.
- [ ] **Step 3: Help window:** `NSSplitViewController` with a source list and a read-only `NSTextView`. Render with `-[NSAttributedString initWithHTML:documentAttributes:]`, then set `NSForegroundColorAttributeName` to `NSColor.labelColor` over the whole range so text follows dark mode. Missing file → "This page is missing."
- [ ] **Step 4: README.**
- [ ] **Step 5: Build, test, check the bundle** (`ls build/MacCleaner.app/Contents/Resources/Help | wc -l` → 12, `WhatsNew.html` present), then `defaults delete com.maccleaner.app; open build/MacCleaner.app`, wait 2 s, `screencapture -x` and Read it: the tour must show. Quit, `defaults write com.maccleaner.app lastSeenVersion 0.0.1`, relaunch, capture: What's New must show.
- [ ] **Step 6: Commit** — `feat(gui): add welcome tour, What's New and Help window`.
