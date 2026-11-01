# Uninstaller — design

Date: 2026-11-01. Branch: `uninstaller-develop` (from `main`).

## Goal

Add an Uninstaller tool. The user selects an installed app. The tool finds
the app bundle and the files that the app left in the user's Library. The
user reviews the list. The selected items move to the Trash.

Success: a self-built test app (a small C program in an `.app` bundle) and
its test leftovers in the Library (Application Support, Caches,
Preferences, Saved Application State, Logs, a LaunchAgent) move to the
Trash in one operation, from the GUI and from the CLI. No file outside the
match rules is touched.

## Decisions

- **Installed apps only.** The tool does not scan for leftovers of apps
  that are already deleted ("orphans"). The bundle ID comes from the app
  itself, so matches are exact. An orphan scan has a high false-positive
  rate.
- **The user's own files only.** The tool removes files that the current
  user owns. Root-owned matches (for example `/Library/LaunchDaemons`,
  `/Library/PrivilegedHelperTools`, a root-owned app from a `.pkg`) show in
  the list as "Needs admin". The tool does not delete them and never asks
  for a password.
- **Match by bundle ID and exact name.** The tool uses a fixed list of
  locations. It does not use Spotlight and does not use partial name
  matches.
- **Trash only.** Every removal goes through the existing Trash backend.
  There is no permanent delete.

## Non-goals

- No orphan scan.
- No privileged helper and no `sudo`.
- No Spotlight (`mdfind`) search.
- No `brew uninstall --zap`. A Homebrew cask app gets a warning only (see
  "Homebrew").
- No `launchctl bootout`. A trashed LaunchAgent plist stops loading at the
  next login. The app itself is quit before the removal.
- No uninstall of Apple apps, of apps under `/System`, or of MacCleaner
  itself.

## Core: `include/maccleaner/uninstaller.hpp`, `src/uninstaller.cpp`

Namespace `maccleaner::uninstaller`.

### Data

```cpp
struct AppInfo {
    std::string path;          // /Applications/Foo.app
    std::string name;          // CFBundleName, else the bundle file name without ".app"
    std::string bundleId;      // CFBundleIdentifier
    std::string version;       // CFBundleShortVersionString
    std::string teamId;        // from the code signature, "" if unsigned or ad hoc
    std::vector<std::string> appGroups; // com.apple.security.application-groups
    bool appleSigned = false;  // signed by Apple (anchor apple)
    std::uint64_t sizeBytes = 0;
};

enum class LeftoverKind { AppBundle, Support, Cache, Preferences, Container,
                          GroupContainer, SavedState, Logs, HTTPStorage,
                          WebKit, Cookies, LaunchAgent };

struct Leftover {
    std::string path;
    LeftoverKind kind;
    std::uint64_t sizeBytes = 0;
    bool needsAdmin = false;   // not owned by the current user: listed, never removed
};
```

### Environment (injected)

Like `updater::Environment` and the optimizer's `PathExistsFn`, the tool
reads the machine through one struct. The tests replace it with a fake
tree.

```cpp
struct Environment {
    std::vector<std::string> appFolders;   // /Applications, ~/Applications
    std::string home;
    std::function<std::optional<AppInfo>(const std::string& appPath)> readApp;
    std::function<bool(const std::string& path)> ownedByUser; // lstat st_uid == geteuid()
};
Environment defaultEnvironment();
```

`readApp` lives in `src/platform/uninstaller_mac.mm`. It reads
`Info.plist` through CFBundle. It reads the team ID, the app groups and
the Apple anchor through `SecStaticCodeCreateWithPath` and
`SecCodeCopySigningInformation` (`kSecCodeInfoEntitlementsDict`,
`kSecCodeInfoTeamIdentifier`). `uninstaller_fallback.cpp` returns
`nullopt`.

### `listApps(env)`

- List the `*.app` entries at the top level of each `appFolders` entry.
  Do not descend into the bundles. Do not follow symlinks.
- Leave out: apps that `readApp` cannot read, apps without a bundle ID,
  Apple-signed apps, and MacCleaner itself (its own bundle ID).
- Sort by name, case-insensitive.

### `findLeftovers(env, app)`

The app bundle itself is always the first row (`AppBundle`). Then the tool
checks these locations under `<home>/Library`:

| Location | Kind | Match |
|---|---|---|
| `Application Support` | Support | ID rule, or name equals `app.name` |
| `Caches` | Cache | ID rule |
| `Preferences` | Preferences | `<id>.plist`, or ID rule (also `ByHost/<id>.<UUID>.plist`) |
| `Containers` | Container | ID rule |
| `Group Containers` | GroupContainer | name in `app.appGroups`, or `<teamId>.<id>`, or ID rule |
| `Saved Application State` | SavedState | `<id>.savedState` |
| `Logs` | Logs | ID rule, or name equals `app.name` |
| `HTTPStorages` | HTTPStorage | ID rule |
| `WebKit` | WebKit | ID rule |
| `Cookies` | Cookies | `<id>.binarycookies` |
| `LaunchAgents` | LaunchAgent | the plist `Label` follows the ID rule, or `Program` / `ProgramArguments[0]` is inside the app bundle |

**ID rule:** the entry name equals the bundle ID, or it starts with
`<bundleId>.`. The comparison is case-insensitive. The name rule compares
the full name, case-insensitive. There is no substring match. For example,
an app named "Code" never matches a folder named "Xcode".

The tool checks the same locations under `/Library` (Application Support,
Caches, Preferences, LaunchAgents, LaunchDaemons, PrivilegedHelperTools)
with the same rules. A match there that the current user does not own
gets `needsAdmin = true`.

`sizeBytes` comes from `directorySizeBytes` for directories and from
`lstat` for files.

### Safety

Add one function to `safety`:

```cpp
// True only for an app bundle: a direct child named *.app of
// /Applications or ~/Applications. The other isSafeToDelete checks still
// apply: not a symlink, owned by the current user, not Apple-signed.
bool isSafeToUninstall(const std::filesystem::path& appBundle, std::string* reasonIfUnsafe = nullptr);
```

`/Applications` stays in `hardDenylist`. `isSafeToUninstall` is a separate,
narrow allowance for the bundle itself. It rejects `/Applications` itself,
any path inside a bundle, a nested `.app`, a symlink, and a bundle that
the current user does not own.

The leftovers go through the existing `isSafeToDelete`. The allowed roots
are the `<home>/Library` locations in the table above. The `/Library`
locations are never allowed roots. Their rows are `needsAdmin` and are
not removed.

### `uninstall(app, leftovers, trash)`

1. Make sure that the app is not running. If it is running, stop and
   report "Quit <name> first". The GUI quits the app before this call.
2. Move each selected item to the Trash: first the leftovers, then the
   bundle. A missing item counts as success. A failure does not stop the
   other items.
3. Return one result per item (path, ok, error text).

## Homebrew

If `updater::parseBrewCaskApps` lists the bundle name, the review sheet
shows a note: "Installed with Homebrew. Run `brew uninstall --cask <token>`
too, or Homebrew will think it is still installed." The tool does not run
brew.

## CLI

```
mac_cleaner uninstall --list
mac_cleaner uninstall <name|bundle-id|path> [--apply]
```

Without `--apply` the command prints the items and their sizes, and it
marks the "Needs admin" rows. With `--apply` it moves the user-owned items
to the Trash. If the app is running, the command refuses and exits
non-zero.

## GUI

- New `MCToolUninstaller` in `MCTheme`, with its own gradient. Add one
  `MCToolEntry` row in `MCMainWindowController.mm` and one card on the
  Home hub.
- `MCUninstallerModel` (ObjC, serial queue, callbacks on main) wraps
  `listApps`, `findLeftovers` and `uninstall`.
- `MCUninstallerViewController`:
  1. A hero screen and a searchable list of apps (icon, name, version,
     size).
  2. A click on an app shows the review list: the bundle and each
     leftover with kind, path and size, all checked. The "Needs admin"
     rows are unchecked and disabled.
  3. "Uninstall": if the app is running, call
     `NSRunningApplication terminate` and wait up to 10 s. If it does
     not quit, stop with a sticky message. Then call `uninstall`.
  4. A results banner shows the freed size. A row that failed with EPERM
     says "Needs Full Disk Access".
- Labels with changing text get low horizontal compression resistance.

## Errors

- TCC: `~/Library/Containers/<id>` can return EPERM without Full Disk
  Access. The row stays in the list. The failure text names Full Disk
  Access.
- A bundle that is root-owned shows as "Needs admin" and is not removed.
  The leftovers of the user can still be removed.
- An app that disappears between the scan and the removal counts as
  removed.

## Testing

Unit tests in `tests/maccleaner_tests.cpp`, on a temp tree with a fake
`readApp`:

- Each row of the location table matches.
- The ID rule: `com.foo.bar` matches `com.foo.bar.helper`, but not
  `com.foo.barbaz`.
- Name rule regression: an app named "Code" does not match `Xcode`.
- Group Containers through `appGroups` and through `<teamId>.<id>`.
- A LaunchAgent that matches through `ProgramArguments[0]`.
- A file owned by another user gets `needsAdmin`. (Simulated through an
  injected owner check, because tests cannot chown.)
- `isSafeToUninstall` rejects: `/Applications`, a path inside a bundle, a
  symlink to a bundle, a non-`.app` entry, a path outside the app folders.
- `listApps` leaves out Apple-signed apps and the app itself.

Real-machine check:

1. Build a small C program into `~/Applications/MCTestApp.app` with a
   bundle ID `com.maccleaner.testapp`.
2. Create its leftovers in the Library locations and one LaunchAgent plist.
3. Run the CLI dry run, then `--apply`. Do the same in the GUI.
4. Make sure that all of them are in the Trash and that nothing else
   moved.

Do not uninstall a real app for this test.
