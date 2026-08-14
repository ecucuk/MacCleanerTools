# mac-cleaner

A toolbox for reclaiming disk space on macOS. The app hosts multiple tools
behind one sidebar:

- **Storage Cleaner** — scan and clean known junk locations: application
  caches, logs, Xcode DerivedData/Archives/DeviceSupport, Simulator caches,
  and package-manager caches (Homebrew, npm, Yarn, pip).
- **Large Files** — walk any directory (default: your home) and list the
  largest files, with Reveal-in-Finder and Move-to-Trash actions.
- **Performance** — a live view of your processes by CPU, memory and
  uptime, with heavy consumers flagged and guarded Quit / Force Quit.

Ships as two front ends over one core library (`maccleaner_core`) — a
`mac_cleaner` CLI and a `MacCleaner.app` AppKit GUI. Scanning, the safety
allowlist and deletion live entirely in the core, so both report identical
numbers and enforce identical rules; neither front end reimplements any of it.

## Build

Requires a recent Xcode / Command Line Tools (Clang with `std::filesystem`,
Objective-C++ and Swift support), CMake >= 3.21 and Ninja.

```sh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build -j
```

Run the tests:

```sh
ctest --test-dir build --output-on-failure
```

Both front ends build by default; pass `-DMACCLEANER_BUILD_GUI=OFF` to skip
the app (and build headless / on non-Apple platforms).

## Usage — CLI

```sh
build/mac_cleaner scan                          # report only, all categories
build/mac_cleaner scan --only=derived-data,npm   # report only, subset
build/mac_cleaner clean                          # dry run (same as scan, but through the clean path)
build/mac_cleaner clean --apply                  # actually move items to Trash
build/mac_cleaner clean --apply --permanent      # skip Trash, remove_all (irreversible)
build/mac_cleaner bigfiles                       # 100 largest files >= 100 MB under $HOME
build/mac_cleaner bigfiles --under=~/Movies --min=1G --top=20
build/mac_cleaner processes                      # your 20 hungriest processes (1s sample)
build/mac_cleaner processes --sort=mem --top=10
```

## Usage — GUI

```sh
open build/MacCleaner.app
```

The sidebar on the left switches tools; each tool is a self-contained view
controller over the shared core (see Extending).

**Storage Cleaner** lists each non-empty category, expandable to the
individual items underneath it, largest first. Check whole categories or
individual items, pick **Move to Trash** or **Delete permanently**, and
confirm.

**Large Files** searches any folder for files at or above a size threshold
(50 MB – 5 GB presets), streaming progress as it walks and cancellable
mid-scan — a cold whole-home walk is I/O-bound and can take minutes.
Results support Reveal in Finder (double-click too) and Move to Trash;
deletion re-validates every path through the same safety layer, with the
chosen search root as the only allowed root. Selecting a photo, video or
audio file shows an inline Quick Look preview in the right-hand pane; the
media gate reads the on-disk content type, so a wrongly named file is still
recognized. **Space** (or the Quick Look button) opens the full Quick Look
panel exactly like Finder: play videos and music with transport controls,
zoom into photos, arrow through a multi-selection — and unlike the inline
pane it previews any file type, PDFs and archives included.

**Performance** samples your processes every two seconds and shows CPU %,
memory, kind (App / System / Background), uptime and pid in a sortable
table. CPU % is a true delta between samples (100 = one saturated core),
so the first refresh reads 0 — there is no baseline yet. The *Heavy /
Long-Running* filter selects processes over 50 % CPU, over 1 GB of memory,
or running for more than a day while still burning 10 %+ CPU. Sampling
stops while the tool is off-screen, and **Pause** freezes it for reading.

### Which processes can be killed

Quit (SIGTERM) and Force Quit (SIGKILL) both go through `isSafeToKill()`,
which is to processes what the deletion allowlist is to files:

- Only processes owned by the **current effective user** — the process
  list itself is filtered by uid, and the guard re-checks ownership, so
  root's and other users' processes are never offered (they are also
  unkillable by the kernel, but the UI should not pretend otherwise).
- Never **pid ≤ 1** (launchd) and never **this app itself**.
- Never **loginwindow**, whose death ends the login session — an
  "optimizer" that logs you out is not optimizing anything.
- Everything else, macOS services included, is killable *with
  confirmation*; the sheet warns when the selection contains system
  services, which launchd generally restarts on its own. Force Quit makes
  Cancel the default button.

Processes that fail the guard are greyed out with the reason in a tooltip
rather than silently failing when you press the button.

The GUI's equivalent of the CLI's dry run is the confirmation sheet: nothing
is touched until you confirm, and the sheet states the item count and total
size first. For the permanent path, **Cancel** is the default button, so
pressing Return cancels rather than deletes. Scanning and deleting both run
off the main thread, so the window stays responsive on large `DerivedData`
trees.

In a build without native Trash support the "Move to Trash" option is removed
rather than shown as a lie (see below).

`clean` without `--apply` never touches the filesystem. `--permanent`
requires `--apply` and is not the default: normal `--apply` moves items to
the Finder Trash via `NSFileManager`, so anything removed is recoverable
until you empty it.

Two exceptions where a delete is permanent even without `--permanent`, both
called out in the confirmation prompt before anything happens:

- **The `trash` category.** Its items are already in `~/.Trash`, so trashing
  them again would reclaim nothing; emptying is the only meaningful
  operation.
- **Builds without native Trash support** (non-Apple, or
  `-DMACCLEANER_USE_NATIVE_TRASH=OFF`). There is no portable "move to trash"
  primitive, so the fallback backend removes outright.

## Categories and overlapping roots

Several category roots nest inside others — `~/Library/Caches/Homebrew`,
`Yarn` and `pip` all live under `~/Library/Caches`, and
`~/Library/Logs/DiagnosticReports` lives under `~/Library/Logs`. Each nested
root belongs to its own category and is excluded from its parent's, so that:

- the grand total never counts the same bytes twice, and
- `clean --only=caches` cannot silently wipe the Homebrew/Yarn/pip caches
  that the user did not select.

Exclusions are resolved over the *complete* category list before any
`--only` filtering, so a category means the same thing regardless of what
else was selected in the same invocation.

## Safety model

This is a tool whose entire job is deleting files, so the design leans
allowlist-first rather than denylist-first:

1. **Known roots only.** The scanner only ever looks inside a fixed set of
   cache/log/build-artifact directories under `$HOME` (see
   `defaultTargets()` in `include/maccleaner/scanner.hpp`). It never walks
   arbitrary user-supplied paths.
2. **Allowlist, re-checked at delete time.** Every one of those roots is
   registered in a `safety::AllowedRoots`. Before anything is deleted,
   `safety::isSafeToDelete()` re-resolves the path and requires it to be a
   *strict descendant* of one of those roots — not the root itself, and
   not merely "somewhere under `$HOME`". This is deliberately narrower than
   a denylist approach: a scanner bug that produces a stray path (e.g. a
   parsing error yielding `/Users/alice` instead of
   `/Users/alice/Library/Caches/Foo`) is rejected here instead of acted on.
3. **Hard denylist as a second layer.** `/`, `/System`, `/Library`, `/usr`,
   `/bin`, `/sbin`, `/private`, `/Applications`, `/Volumes`, and the home
   directory itself are always rejected, even if something were (wrongly)
   registered as an allowed root that contains them.
4. **No deleting through symlinks.** `isSafeToDelete` `lstat`s the
   candidate first and refuses anything that is itself a symlink. The
   scanner's directory-size walk also never follows symlinked children when
   computing sizes, so a cyclic or outward-pointing symlink under a cache
   directory can't inflate a size total or get traversed into. A symlink is
   sized by `lstat` (its own target-path length), not `std::filesystem::
   file_size` — the latter follows the link, and *fails* on a
   symlink-to-directory or a broken link, returning `uintmax_t(-1)` rather
   than 0.
5. **Ownership check.** The resolved path must be owned by the current
   effective user (`geteuid()`). Nothing owned by another account — including
   root — is touched, even if it's nominally under an allowed root.
6. **Trash by default.** `moveToTrash()` (in `src/platform/trash_mac.mm`)
   calls `-[NSFileManager trashItemAtURL:resultingItemURL:error:]`, the same
   API Finder uses for "Move to Trash". Permanent deletion
   (`std::filesystem::remove_all`) is opt-in via `--permanent` and still
   requires `--apply`.
7. **Dry run is the default for `clean`.** You always see exactly what
   would be deleted, and its size, before anything happens; `--apply` is a
   separate, explicit step.

### Known limitations

- The safety re-check and the actual delete are not atomic (classic
  TOCTOU): between `lstat`/`stat` and the `NSFileManager`/`remove_all` call,
  the filesystem could change underneath us. Closing this fully would mean
  operating on open file descriptors (`openat`/`fstatat`/`unlinkat`) instead
  of paths throughout, which the scaffold doesn't do yet.
- SIP (System Integrity Protection) isn't queried directly — the tool
  simply never targets SIP-protected locations in the first place (they're
  outside every allowed root), so there's nothing to bypass. If you extend
  `defaultTargets()`, keep new roots under paths the current user actually
  owns and can freely modify.
- Protected entries *inside* allowed roots are excluded at scan time.
  `~/Library/Caches` contains directories the OS will not let a normal
  process touch even though the user owns them and their mode bits look
  ordinary: SIP data vaults (marked `UF_DATAVAULT`/`SF_RESTRICTED` on the
  inode) and TCC-protected caches such as `com.apple.homed`, `CloudKit`,
  `FamilyCircle` and Safari's caches, which carry **no** flags at all and
  are only detectable by probing (`opendir` failing with `EPERM`; `EACCES`
  by contrast means plain permissions and such entries stay listed, since
  moving to Trash only needs write access on the parent). Offering these
  would just manufacture guaranteed "couldn't be moved to the trash"
  failures. The probe runs with the scanning process's own privileges, so
  granting the app Full Disk Access (System Settings → Privacy & Security)
  automatically makes the TCC-only ones visible and cleanable — the data
  vaults stay off-limits regardless, by design.
- `directorySizeBytes()` does a full recursive walk per top-level entry on
  every run; for very large `DerivedData`/cache trees this is I/O-bound and
  not cached between invocations.
- Process killing has the same check-then-act gap as deletion: a pid
  validated by `isSafeToKill()` could in principle be reused by another
  process before the signal lands. macOS allocates pids sequentially and
  the window is sub-millisecond, but closing it properly would mean holding
  a task port or `pidfd`-style handle across the check.

## Layout

```text
include/maccleaner/   public headers (types, safety, scanner, cleaner, trash, cli, format)
src/                  core implementation + CLI front end (main.cpp)
src/platform/         OS-specific Trash backend (trash_mac.mm / trash_fallback.cpp)
src/gui/              AppKit front end: MCMainWindowController = sidebar shell,
                      MCCleanerViewController / MCLargeFilesViewController /
                      MCPerformanceViewController = tools,
                      MCScanModel / MCBigFilesModel / MCProcessModel =
                      core wrappers + threading,
                      main.mm = NSApplication
src/gui/viz/          SwiftUI Activity window (own static lib, bridged via
                      the generated MacCleanerViz-Swift.h)
cmake/                bundle Info.plist template
tests/                dependency-free CTest suite
```

The GUI adds no dependency beyond system frameworks and builds from the same
`cmake --build build`; the UI is constructed in code, so there are no
xib/storyboard resources to keep in sync.

## Development workflow

`main` is the stable base. Each tool is developed on its own
`<tool>-develop` branch (e.g. `large-files-develop`) and merged into `main`
when it holds together; the sidebar shell means a new tool lands as one new
view controller plus one `MCToolEntry` row in `MCMainWindowController.mm`.

## Extending

To add a new cleanup category: add an enum value to `Category`
(`types.hpp`), a case in `toString()`, an entry in `defaultTargets()`
(`scanner.cpp`), and a CLI alias in `parseCategory()` (`cli.cpp`). No
changes to the safety layer are needed — new roots are picked up
automatically via `registerAllowedRoots()`, and any nesting against existing
roots is picked up automatically via `resolveExclusions()`.

To add a new *tool*: put its core logic in the C++ library (own header, own
tests, ideally a CLI subcommand), wrap threading in a small ObjC model like
MCBigFilesModel, build the UI as an NSViewController, and register it as an
MCToolEntry in the shell. If the tool deletes anything, route every path
through `safety::isSafeToDelete()` with an AllowedRoots scoped to what the
user actually asked to operate on.

Note that a category's deletable units are always the *direct children* of
its root, never the root itself: `isSafeToDelete()` only accepts strict
descendants of an allowlisted root, so a "delete the whole root" mode could
never pass the safety check. A category whose root should end up empty (like
`trash`) expresses that by deleting every child.
