# Uninstaller Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an Uninstaller tool. It moves a selected app bundle and the app's leftovers in the user's Library to the Trash.

**Architecture:** The matching logic is pure C++ in `maccleaner::uninstaller` and reads the machine through an injected `Environment`. A platform `.mm` file supplies the real `readApp` and `readLaunchAgent` (CFBundle, Security.framework, CFPropertyList). `safety::isSafeToUninstall` is a narrow allowance for the bundle itself. The leftovers go through the existing `isSafeToDelete`. The CLI and an ObjC model + view controller sit on top, like every other tool.

**Tech Stack:** C++20, ObjC++ (ARC in platform files), AppKit, CoreFoundation, Security.framework, CMake + Ninja.

**Spec:** `docs/superpowers/specs/2026-11-01-uninstaller-design.md`

## Global Constraints

- Branch `uninstaller-develop`. Never push to `main`. Push or open a PR only when the user asks.
- Commits: Conventional Commits, subject ≤ 72 chars, body explains why, **no `Co-Authored-By` trailer**.
- No new dependencies beyond system frameworks.
- Trash only. No permanent delete. No `sudo`, no privileged helper, no Spotlight, no `brew` call, no `launchctl`.
- Root-owned matches: `needsAdmin = true`, listed, never removed.
- No substring name match. ID rule: equal to the bundle ID, or starts with `<bundleId>.`, case-insensitive. Name rule: full name equal, case-insensitive.
- Leave out of `listApps`: Apple-signed apps, apps without a bundle ID, and `com.maccleaner.app`.
- Never range-for over `directory_iterator`. Use `increment(ec)`.
- Test fixtures live under `$HOME` (`ScratchTree` pattern), because `/private` is hard-denylisted.
- Build: `cmake --build build`. If the build fails, `ctest` runs a stale binary. Check the build output first.

## Review Focus

1. **Top-level symlinks in an app folder** (for example `~/Applications/Chrome Apps.localized` items, or a cask symlink): `listApps` must skip them and `isSafeToUninstall` must reject them. Test in Task 1 and Task 2.
2. **A malformed or binary LaunchAgent plist**: `readLaunchAgent` returns `nullopt`. That agent is not matched, and the scan does not fail. Test in Task 1 (fake returns `nullopt`).
3. **Bundle IDs that differ in case** from the folder name (`com.Foo.App` vs `com.foo.app`): they still match. Test in Task 1.
4. **The app is running at uninstall time** (the CLI, or a GUI quit that times out): no item moves. Test in Task 3.
5. **A leftover that is a symlink** (for example a Caches entry that links elsewhere): `isSafeToDelete` rejects it. The row reports the failure and the other rows continue. Test in Task 3.

---

### Task 1: Core matching (`listApps`, `findLeftovers`)

**Files:**
- Create: `include/maccleaner/uninstaller.hpp`, `src/uninstaller.cpp`
- Modify: `CMakeLists.txt` (add `src/uninstaller.cpp` to the core sources next to `src/updater.cpp`)
- Test: `tests/maccleaner_tests.cpp` (register each test in `main()`)

**Interfaces:**
- Produces, in `namespace maccleaner::uninstaller`:
  - `struct AppInfo`, `enum class LeftoverKind`, `struct Leftover` exactly as in the spec "Data" section.
  - `struct LaunchAgentInfo { std::string label; std::string program; };` where `program` is `Program`, else `ProgramArguments[0]`.
  - `struct Environment { std::vector<std::string> appFolders; std::string home; std::function<std::optional<AppInfo>(const std::string&)> readApp; std::function<bool(const std::string&)> ownedByUser; std::function<std::optional<LaunchAgentInfo>(const std::string& plistPath)> readLaunchAgent; std::string systemLibrary = "/Library"; };`. `systemLibrary` lets the tests point the `/Library` scan at a temp dir.
  - `constexpr const char* kSelfBundleId = "com.maccleaner.app";`
  - `std::string toString(LeftoverKind kind);` returns "App", "Application Support", "Caches", "Preferences", "Container", "Group Container", "Saved State", "Logs", "HTTP Storage", "WebKit", "Cookies", "Launch Agent".
  - `std::vector<AppInfo> listApps(const Environment& env);`
  - `std::vector<Leftover> findLeftovers(const Environment& env, const AppInfo& app);`
  - `bool matchesId(std::string_view entryName, std::string_view bundleId);` (exposed for tests)

- [ ] **Step 1: Write the failing tests.** Build a fake tree under a `ScratchTree` root: `Applications/Foo.app`, `Applications/Bar.app`, `Applications/Apple.app`, `Applications/link.app` (symlink to Foo.app), and `home/Library/...`. The fake `readApp` returns an `AppInfo` per path: Foo is `com.foo.app`, name "Foo", teamId "TEAM1", appGroups `{"group.com.foo"}`. Apple has `appleSigned = true`. `ownedByUser` returns false for the paths in a set the test fills. `readLaunchAgent` returns values from a map.
  - `testUninstallerMatchesIdRule`: `matchesId("com.foo.app.helper","com.foo.app")` is true. `matchesId("com.foo.appbaz","com.foo.app")` is false. `matchesId("COM.FOO.APP","com.foo.app")` is true.
  - `testUninstallerListAppsFilters`: the result has only Bar and Foo, sorted by name. Apple, the symlink, an entry without a bundle ID, and an app with ID `com.maccleaner.app` are left out.
  - `testUninstallerFindsEachLocation`: create one match per row of the spec table (`Application Support/Foo`, `Application Support/com.foo.app`, `Caches/com.foo.app`, `Preferences/com.foo.app.plist`, `Preferences/ByHost/com.foo.app.ABC.plist`, `Containers/com.foo.app`, `Group Containers/group.com.foo`, `Group Containers/TEAM1.com.foo.app`, `Saved Application State/com.foo.app.savedState`, `Logs/Foo`, `HTTPStorages/com.foo.app`, `WebKit/com.foo.app`, `Cookies/com.foo.app.binarycookies`). Assert every one is in the result with the right `LeftoverKind`. Row 0 is the bundle (`AppBundle`).
  - `testUninstallerNameRuleIsExact`: for an app named "Code" with ID `com.microsoft.VSCode`, `Application Support/Xcode` and `Application Support/Code Helper` are not in the result. `Application Support/Code` is.
  - `testUninstallerLaunchAgentByProgram`: `LaunchAgents/x.plist` with `program` inside `Foo.app/Contents/MacOS/` matches. `LaunchAgents/y.plist` for which `readLaunchAgent` returns `nullopt` does not match, and there is no throw.
  - `testUninstallerSystemLibraryNeedsAdmin`: `systemLibrary/LaunchDaemons/com.foo.app.helper.plist` is in the set that is not owned by the user. It is in the result with `needsAdmin == true`.
  - `testUninstallerUnrelatedFilesUntouched`: `Caches/com.foobar.app` and `Application Support/Foobar` are not in the result.

- [ ] **Step 2: Run them and make sure they fail.** Run: `cmake --build build && ctest --test-dir build --output-on-failure`. Expected: the build fails because `maccleaner/uninstaller.hpp` does not exist.

- [ ] **Step 3: Implement** the header and `src/uninstaller.cpp`. Walk only the top level of each location with `directory_iterator` + `increment(ec)`. For `Preferences`, also check `Preferences/ByHost`. Use `lstat` and skip symlinks in `listApps`. Fill `sizeBytes` with `directorySizeBytes` (directories) or `lstat` (files). Set `needsAdmin = !env.ownedByUser(path)` for every row, the bundle row included.

- [ ] **Step 4: Run the tests and make sure they pass.** Same command. Expected: `100% tests passed`.

- [ ] **Step 5: Commit.** `feat(core): find app leftovers for the Uninstaller`

### Task 2: `safety::isSafeToUninstall`

**Files:**
- Modify: `include/maccleaner/safety.hpp`, `src/safety.cpp`
- Test: `tests/maccleaner_tests.cpp`

**Interfaces:**
- Produces: `bool safety::isSafeToUninstall(const std::filesystem::path& appBundle, const std::vector<std::filesystem::path>& appFolders, std::string* reasonIfUnsafe = nullptr);`
  The `appFolders` parameter is a change from the spec signature. Without it, the tests cannot use a temp tree. Production callers pass `defaultEnvironment().appFolders`.

- [ ] **Step 1: Write the failing tests** on a `ScratchTree` with `apps/Foo.app/Contents/MacOS/foo`:
  - `testUninstallSafetyAcceptsBundle`: `apps/Foo.app` with `appFolders = {apps}` is true.
  - `testUninstallSafetyRejects`: false for `apps` itself, `apps/Foo.app/Contents`, `apps/Foo.app/Contents/Helper.app`, `apps/notes.txt`, a symlink `apps/Link.app` to Foo.app, `outside/Foo.app` (not in `appFolders`), and a path that does not exist. Each case fills `reasonIfUnsafe` with a non-empty string.
  - `testUninstallSafetyKeepsHardDenylist`: `isSafeToDelete("/Applications/Foo.app", ...)` with `~/Library/Caches` as the allowed root is still false.

- [ ] **Step 2: Run them and make sure they fail.** Expected: a compile error for `isSafeToUninstall`.

- [ ] **Step 3: Implement.** The checks: `lstat` succeeds and the path is not a symlink. It is a directory whose extension is `.app`, case-insensitive. Its parent, compared with `weakly_canonical`, equals one of `appFolders`. It is owned by `geteuid()`. Do not change `hardDenylist`.

- [ ] **Step 4: Run the tests and make sure they pass.**

- [ ] **Step 5: Commit.** `feat(safety): allow trashing an app bundle for the Uninstaller`

### Task 3: `uninstall`, running check, real environment

**Files:**
- Modify: `include/maccleaner/uninstaller.hpp`, `src/uninstaller.cpp`, `CMakeLists.txt` (add the platform files to both platform lists, the `.mm` to the `-fobjc-arc` list)
- Create: `src/platform/uninstaller_mac.mm`, `src/platform/uninstaller_fallback.cpp`
- Test: `tests/maccleaner_tests.cpp`

**Interfaces:**
- Consumes: Task 1 types, `safety::isSafeToUninstall` (Task 2), `safety::isSafeToDelete`, `trash::moveToTrash`, `sampleProcesses(uid_t)`.
- Produces:
  - `struct RemovalResult { std::string path; bool ok = false; std::string error; };`
  - `using TrashFn = std::function<bool(const std::filesystem::path&, std::string& error)>;`
  - `using RunningFn = std::function<bool(const std::string& appPath)>;`
  - `bool isAppRunning(const std::string& appPath);`: true if any `sampleProcesses(getuid())` entry has a `path` that starts with `appPath + "/"`.
  - `safety::AllowedRoots leftoverRoots(const Environment& env);`: the `<home>/Library` locations of the spec table.
  - `std::vector<RemovalResult> uninstall(const Environment& env, const AppInfo& app, const std::vector<Leftover>& selected, const TrashFn& trash, const RunningFn& running, std::string* refusal);`
  - `Environment defaultEnvironment();` (in the platform files): `appFolders = {"/Applications", "<home>/Applications"}`, the real `readApp`, `ownedByUser` (lstat `st_uid == geteuid()`), and `readLaunchAgent` (CFPropertyList, XML or binary).

- [ ] **Step 1: Write the failing tests** with a recording fake `TrashFn`:
  - `testUninstallRefusesWhenRunning`: `running` returns true. The result is empty, `*refusal == "Quit Foo first"`, and the fake was not called.
  - `testUninstallOrderAndSkips`: the trash calls happen in the order leftovers first, bundle last. A `needsAdmin` row is not passed to trash and is not in the result. A Caches leftover that is a symlink gets `ok == false` with the `isSafeToDelete` reason, and the next rows still run.
  - `testUninstallMissingItemIsSuccess`: a selected leftover that does not exist gets `ok == true`.
  - `testUninstallRefusesAppleSigned`: `app.appleSigned == true`. The result is empty and `refusal` is set.

- [ ] **Step 2: Run them and make sure they fail.**

- [ ] **Step 3: Implement** `uninstall`, `isAppRunning`, `leftoverRoots`, and the platform `readApp`. `readApp` uses `CFBundleCreate` / `CFBundleGetValueForInfoDictionaryKey` for the ID, name and version. It uses `SecStaticCodeCreateWithPath` + `SecCodeCopySigningInformation(kSecCSSigningInformation)` for `kSecCodeInfoTeamIdentifier` and `kSecCodeInfoEntitlementsDict["com.apple.security.application-groups"]`. For `appleSigned` it uses `SecRequirementCreateWithString("anchor apple")` + `SecStaticCodeCheckValidity`. The fallback returns `nullopt` and `false`.

- [ ] **Step 4: Run the tests and make sure they pass.**

- [ ] **Step 5: Commit.** `feat(core): move an app and its leftovers to the Trash`

### Task 4: CLI `uninstall`

**Files:**
- Modify: `include/maccleaner/cli.hpp` (`Command::Uninstall`; reuse `paths` for the target and `apply`), `src/cli.cpp`, `src/main.cpp`
- Test: `tests/maccleaner_tests.cpp`

**Interfaces:**
- Consumes: `defaultEnvironment`, `listApps`, `findLeftovers`, `uninstall`, `isAppRunning`, `trash::moveToTrash`, `updater::parseBrewCaskApps`, `updater::runCommand`.
- Produces: `mac_cleaner uninstall --list` and `mac_cleaner uninstall <name|bundle-id|path> [--apply]`. Add a `bool listApps` field to `CliOptions`.

- [ ] **Step 1: Write the failing parse tests:** `testCliParsesUninstallList` (`{"uninstall","--list"}` → `Command::Uninstall`, `listApps == true`). `testCliParsesUninstallTarget` (`{"uninstall","Foo","--apply"}` → `paths == {"Foo"}`, `apply == true`). `testCliUninstallNeedsTarget` (`{"uninstall"}` → `CliParseError`).

- [ ] **Step 2: Run them and make sure they fail.**

- [ ] **Step 3: Implement** the parse and `runUninstall` in `main.cpp`. Match the target in this order: exact path, bundle ID, then name (case-insensitive). If there are several name matches, print them and exit 2. The dry run prints one row per item: kind, size, path, and `[needs admin]` where it applies. Then a total. Run `brew info --cask --json=v2 --installed` only if `brew` exists. If the bundle name is in the result, print the Homebrew note from the spec. With `--apply`, a running app prints `Quit <name> first` and exits 1. Add the command to the usage text.

- [ ] **Step 4: Run the tests and make sure they pass.** Then run `./build/mac_cleaner uninstall --list` and make sure that it lists your apps, with no Apple apps.

- [ ] **Step 5: Commit.** `feat(cli): add uninstall subcommand`

### Task 5: GUI

**Files:**
- Create: `src/gui/MCUninstallerModel.h/.mm`, `src/gui/MCUninstallerViewController.h/.mm`
- Modify: `src/gui/MCTheme.h` (`MCToolUninstaller`), `src/gui/MCTheme.mm` (gradient `{0x7c3aed, 0xdb2777}`, violet to pink), `src/gui/MCMainWindowController.mm` (entry: title "Uninstaller", symbol `trash.square`, after Updater in `_tools`), `src/gui/MCHomeViewController.mm` (`staticSummaryForTool`: "Remove apps and their leftovers"), `CMakeLists.txt` (the GUI source list)

**Interfaces:**
- Consumes: Task 1 and Task 3 core API, `MCToolBanner`, `MCHeroView`, `setStickyStatusMessage:` (the same pattern the Performance tool uses).
- Produces: `MCUninstallerModel` with `- (void)loadApps:(void (^)(NSArray<MCAppRow *> *))done;`, `- (void)loadLeftoversForApp:(MCAppRow *)app done:(void (^)(NSArray<MCLeftoverRow *> *))done;`, and `- (void)uninstallApp:(MCAppRow *)app items:(NSArray<MCLeftoverRow *> *)items done:(void (^)(NSArray<MCRemovalRow *> *, NSString *refusal))done;`. All work runs on one serial queue. The callbacks run on main.

- [ ] **Step 1: Implement the model and the view controller.**
  - The view controller has a hero screen, a search field, and a table of apps. The app icon comes from `NSWorkspace iconForFile:`.
  - The review table shows the kind, the path and the size, with a checkbox. `needsAdmin` rows are unchecked and disabled, with the "Needs admin" note.
  - Show the Homebrew note when it applies.
  - The "Uninstall" action: if `NSRunningApplication runningApplicationsWithBundleIdentifier:` is not empty, call `terminate` and poll for up to 10 s. On a timeout, set a sticky message "<name> did not quit" and stop. Then call the model.
  - The results banner shows the freed size. A row that failed with EPERM shows "Needs Full Disk Access".
  - Labels with changing text get `setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal`.

- [ ] **Step 2: Build and run the tests.** Run: `cmake --build build && ctest --test-dir build --output-on-failure`. Expected: no compiler warnings about an unhandled `MCTool` in a switch, and `100% tests passed`.

- [ ] **Step 3: Check visually.** Run: `open build/MacCleaner.app`, then `screencapture -x <scratchpad>/uninstaller.png`. Make sure that the Home hub shows an Uninstaller card and that the sidebar has the row. Tell the user which clicks they must do, because Claude has no Accessibility permission.

- [ ] **Step 4: Commit.** `feat(gui): add Uninstaller tool`

### Task 6: Real-machine check and README

**Files:**
- Modify: `README.md` (an Uninstaller section: what it matches, Needs admin, Trash only, the CLI usage)
- Scratch only, not in the repo: the test app sources

- [ ] **Step 1: Build the test app.** Compile `int main(){for(;;)pause();}` with `cc` into `~/Applications/MCTestApp.app/Contents/MacOS/MCTestApp`. Write an `Info.plist` with `CFBundleIdentifier` `com.maccleaner.testapp` and `CFBundleName` `MCTestApp`. Ad-hoc sign it: `codesign -s - ~/Applications/MCTestApp.app`.
- [ ] **Step 2: Create the leftovers.** Create `Application Support/MCTestApp`, `Caches/com.maccleaner.testapp`, `Preferences/com.maccleaner.testapp.plist`, `Saved Application State/com.maccleaner.testapp.savedState`, `Logs/MCTestApp`, and `LaunchAgents/com.maccleaner.testapp.agent.plist` (with `Program` inside the bundle, and do not load it). Also create the decoy `Caches/com.maccleaner.testappx`.
- [ ] **Step 3: Run the dry run.** Run `./build/mac_cleaner uninstall com.maccleaner.testapp`. Expected: 7 rows (the bundle + 6), and the decoy is not listed.
- [ ] **Step 4: Run it with the app running.** Run `open ~/Applications/MCTestApp.app`, then `./build/mac_cleaner uninstall com.maccleaner.testapp --apply`. Expected: `Quit MCTestApp first`, exit 1, nothing moved.
- [ ] **Step 5: Run it after the quit.** Run `pkill -x MCTestApp`, then run the `--apply` command again. Expected: 7 rows ok. All 7 are in `~/.Trash`, and the decoy is still in Caches.
- [ ] **Step 6: Do the GUI pass.** Create the test app and the leftovers again. Ask the user to uninstall MCTestApp in the GUI. Then check `~/.Trash` with `ls` and take a screenshot of the results banner.
- [ ] **Step 7: Clean up.** Delete the decoy and the scratch sources. Then update the README.
- [ ] **Step 8: Commit.** `docs: document the Uninstaller tool`
