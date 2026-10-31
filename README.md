# mac-cleaner

A toolbox for reclaiming disk space on macOS. The app hosts multiple tools
behind one sidebar:

- **Storage Cleaner** — scan and clean known junk locations: application
  caches, logs, Xcode DerivedData/Archives/DeviceSupport, Simulator caches,
  and package-manager caches (Homebrew, npm, Yarn, pip).
- **Large Files** — walk any directory (default: your home) and list the
  largest files, with Reveal-in-Finder and Move-to-Trash actions.
- **Photo Cleaner** — find duplicate, near-duplicate and blurry photos in a
  folder or in the Photos library, review them, and remove the ones you
  choose.
- **File Organizer** — sort a folder into `Photos`, `Videos`, `Music`,
  `Documents` and `Other`. Photos go into a content category (Vision) or a
  place (country / province / city from their GPS), then year and month.
  Preview it as folders or on a map before anything moves.
- **Performance** — a live view of your processes by CPU, memory and
  uptime, with heavy consumers flagged, guarded Quit / Force Quit, and a
  one-click **Optimize** that finds processes worth reclaiming.
- **Antivirus** — an on-demand scan of Downloads, Desktop and Applications
  for Apple's XProtect signatures, quarantined unsigned programs and
  suspicious LaunchAgents/LaunchDaemons. Report-only until you move a
  finding to the Trash. It is not a real-time antivirus.

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

### Installing

The build produces a self-contained `build/MacCleaner.app`; copy it to
`/Applications` to install:

```sh
ditto build/MacCleaner.app /Applications/MacCleaner.app
```

### App icon

The icon is drawn from scratch with Core Graphics by `tools/make_icon.m` —
no third-party artwork, so there is nothing to license. `resources/
MacCleaner.icns` is generated from it by `tools/build_icon.sh` and committed,
so a normal build never runs the generator; re-run the script after changing
the design. The script honours `$CC`/`$CFLAGS`, which lets a non-Apple clang
build it against the Command Line Tools SDK when the Xcode toolchain is
unavailable (an unaccepted Xcode license gates every `/usr/bin` compiler,
`xcrun` included):

```sh
CC=/opt/homebrew/opt/llvm/bin/clang \
CFLAGS="-isysroot /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk -B/Library/Developer/CommandLineTools/usr/bin" \
sh tools/build_icon.sh
```

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
build/mac_cleaner photos --under=~/Pictures      # duplicate groups + blurry photos (report only)
build/mac_cleaner photos --under=~/Pictures --distance=3 --blur=50
build/mac_cleaner organize --under=~/Pictures/Unsorted               # dry run: where each file would go
build/mac_cleaner organize --under=~/Pictures/Unsorted --by=place    # photos by country/province/city
build/mac_cleaner organize --under=~/Pictures/Unsorted --dest=~/Pictures/Sorted --apply
build/mac_cleaner optimize                       # report reclaimable processes
build/mac_cleaner optimize --apply               # and terminate them (SIGTERM)
build/mac_cleaner malware                        # scan ~/Downloads, ~/Desktop, ~/Applications, /Applications
build/mac_cleaner malware --path=~/Projects      # scan another folder instead (repeatable)
build/mac_cleaner malware --trash                # then move Detected/Suspicious items to the Trash
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

**Photo Cleaner** scans a folder (**Scan Folder…**) or the Photos library
(**Scan Photos Library**, which asks for Photos access the first time) and
lists two sections: *Duplicates*, grouped, and *Blurry*. Each photo is
decoded once at 512 px (ImageIO for files, PhotoKit for the library) into
grayscale, then:

- **Duplicates** use a 64-bit difference hash (dHash). Two photos whose
  hashes differ in at most *Duplicate tolerance* bits (default 6, 0 =
  identical) are grouped, transitively. This catches resized, re-encoded
  (JPEG ↔ HEIC), lightly edited and burst copies — not merely byte-identical
  files.
- **Blurry** photos have a *sharpness* (variance of the Laplacian) below the
  threshold (default 100). On real photos sharp shots score in the hundreds
  and visibly blurred ones under 20; a soft portrait with a smooth
  background can land low too, so the list is for review, not a verdict.

Nothing is checked for you: you look at each photo and tick what should go,
which may be nothing. To tick many at once, select rows (a group row stands
for its photos) and press **Return**, which toggles them; **Check Copies**
ticks every photo in the duplicate groups except the best copy. Every row has a thumbnail, the selected photo shows in
the preview pane, and **Large Preview** (or double-click, or **Space**)
shows it large: the Quick Look panel for folder photos (zoom, arrow through
the selection), an image window for library photos. Library previews use
what is stored on this Mac and never download from iCloud. Each group's **best copy** — most pixels, then
sharpest, then oldest — is labelled so you can see which one to keep. Both
thresholds can be changed after a scan without rescanning. **Remove…** takes
the checked folder photos away in the background, with progress and **Stop**:
**Move to Trash**, **Back Up & Delete…** (moves them into a folder outside
the scanned one, keeping their subfolders and never replacing a file there;
JPEG, PNG and TIFF are re-encoded as HEIC at quality 0.8 with their metadata
and dates, which halved real JPEGs with no visible loss, and kept as they
are when HEIC would not be smaller),
or **Delete Permanently…** (asks again; Return cancels). Every photo first
passes `isSafeToDelete()` with the scanned folder as the only allowed root.
Library photos are deleted through Photos itself, which shows
its own confirmation and keeps them in *Recently Deleted* for 30 days;
photos that are only in iCloud are never downloaded and count as skipped.

A folder scan is saved in `~/Library/Caches/com.maccleaner.app/photo-scans/`.
Opening Photo Cleaner again shows the last folder at once, then rescans it
in the background: deleted photos drop out, and only new files or files with
a changed size or modification time are decoded again (the same applies to
**Scan Folder…** on a folder scanned before). **Remove…** stays off until
that rescan is done.

**File Organizer** asks for a folder and, optionally, a different
destination (default: the folder itself). **Preview** reads every file
and shows where it would go:

| Kind | Extensions (examples) | Target |
|---|---|---|
| Photos | jpg, heic, png, raw | `Photos/<Category>/YYYY/YYYY-MM/` or `Photos/<Country>/<Province>/<City>/YYYY/YYYY-MM/` |
| Videos | mp4, mov, m4v | `Videos/YYYY/YYYY-MM/` |
| Music | mp3, m4a, flac | `Music/` |
| Documents | pdf, docx, txt | `Documents/` |
| Other | everything else | `Other/` |

- The date is the EXIF capture date for photos and the AVFoundation
  creation date for videos. If a file has no date in its metadata, the
  file's birth time is used. A copied file without metadata can therefore
  land in the month it was copied.
- The content categories come from Vision on a 512 px thumbnail: Screenshots,
  Documents, People, Animals, Food, Vehicles, Buildings, Nature, else Other.
- **Photos by Place** clusters GPS positions on a ~5 km grid. It sends one
  rounded position per cell to Apple Maps and caches the answers in
  `~/Library/Caches/com.maccleaner.app/geocode.tsv`, so a later preview
  stays offline. Photos without GPS go to `Photos/Unknown Place/`.
- **Map** shows one pin per cell with its photo count.
- Hidden files, app bundles, Photos libraries and the five kind folders
  directly under the destination are skipped. Running the tool again on
  the same folder therefore moves nothing.

**Organize** asks first, then moves the files. Nothing is overwritten: when a
name is taken, the file gets a number (`IMG_1 (2).jpg`). Files that cannot
be moved are listed afterwards. Empty source folders stay.

**Performance** samples your processes every two seconds and shows CPU %,
memory, kind (App / System / Background), uptime and pid in a sortable
table. CPU % is a true delta between samples (100 = one saturated core),
so the first refresh reads 0 — there is no baseline yet. The *Heavy /
Long-Running* filter selects processes over 50 % CPU, over 1 GB of memory,
or running for more than a day while still burning 10 %+ CPU. Sampling
stops while the tool is off-screen, and **Pause** freezes it for reading.

**Antivirus** scans on demand. It is a signature and heuristic scanner, not
a real-time engine, and it does not replace XProtect, which already checks
every program macOS launches. It adds a report you can run on any folder,
plus a look at what starts at login. **Scan** checks `~/Downloads`,
`~/Desktop`, `~/Applications` and `/Applications`; **Choose Folder…** scans
one folder instead. A full default scan of one test Mac (467,000 files)
took about 5½ minutes.

| Severity | Kind | Rule |
|---|---|---|
| Detected | Signature | A rule from `XProtect.plist` (or the built-in EICAR test rule) matches the file |
| Suspicious | Quarantine | An executable Mach-O file has `com.apple.quarantine` and is unsigned or ad-hoc signed |
| Suspicious | Persistence | A LaunchAgent/LaunchDaemon starts an unsigned program, a downloaded ad-hoc signed program, any program under `/tmp` or `/Users/Shared`, or an unsigned/ad-hoc one in a hidden folder |
| Info | Persistence | The plist is unreadable, names no program or a relative one, the program is missing, or it is ad-hoc signed but not downloaded (normal for Homebrew services) |

- **Signatures.** The rules come from
  `/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Resources/XProtect.plist`.
  Its hex patterns (with `??`, `{n}`, `{-n}` and `*` wildcards) and SHA-1
  identities are matched in the core. An entry that uses a form the parser
  does not know, for example an alternation `(a|b)`, is dropped whole and
  never loosened: 91 of 94 entries load on macOS 27.2. Apple's newer
  `XProtect.yara` rules need a YARA engine, which would be the first
  third-party dependency, so they are not used. The type constraint of a
  rule is approximated as "has an execute bit or is Mach-O".
- **Code signatures** come from Security.framework
  (`SecStaticCodeCheckValidity`; `anchor apple` marks Apple's own code).
  Apple-signed files and everything under `/System` are never reported and
  never touched.
- **Limits.** Files over 64 MB are not matched against signatures (they still
  get the quarantine check). Rules that describe several files of one bundle
  cannot match a single file. A broken or revoked signature is not flagged.
  Login items registered through `SMAppService` are not listed.
- **Test it** with the harmless EICAR test string in a file under
  `~/Downloads`: it shows as Detected.

**Move to Trash** acts only on the rows you select and asks first. Every
item passes the same safety check as a delete, with the scan roots and the
launch-agent folders as the allowed roots. Items in `/Applications` or
`/Library` therefore stay put: they need an administrator, so remove them in
Finder. A trashed launch agent that is already running stops at the next
login.

### Optimize

**Optimize…** answers one question — *what is running that nobody needs?* —
and it answers it narrowly, because the failure mode of a process optimizer
is closing something that was doing its job. A process is proposed only when
it is:

1. **Finished or suspended** — a zombie waiting for a parent that will never
   reap it, or a stopped process. Doing nothing, and never will again.
2. **An orphaned renderer** — a Chromium/Electron *role* helper
   (`Foo Helper (Renderer)`, `(GPU)`, `(Plugin)`) whose owning `.app` is no
   longer running. Its app quit and leaked it; it can no longer serve anyone.
3. **A program that is no longer installed** — its executable is gone from
   disk, deleted or replaced by an update while the process kept running.
4. **An idle update checker** — an explicit list of known agents (Google
   Keystone, Microsoft AutoUpdate, Adobe CC satellites) plus a generic
   `*Updater` / `*AutoUpdate` / `*UpdateService` name pattern, for the
   vendors a list will never enumerate.
5. **An idle helper of a running app** — a Chromium/Electron or WebKit
   helper over 250 MB that has used essentially no CPU and has been up for
   at least 15 minutes. This one is **opt-in**: it arrives unchecked,
   because unlike 1–4 it is alive and reclaiming it costs a reload of
   whatever it was holding.

And never when it is a **user-facing application** (anything with a Dock
icon, which may be holding unsaved work), a **login item or launchd agent**,
**Apple's own system services or XPC services** (the system starts and stops
those on demand), this app itself, or anything the
[safe-kill guard](#which-processes-can-be-killed) rejects. Termination is
**SIGTERM only** — the optimizer never escalates to SIGKILL on its own.

Two of these exclusions exist because the rules misfired on a real machine
before them: rule 4's generic pattern matched `SetStoreUpdateService`, an
Apple XPC service under `/System/Library/PrivateFrameworks`, and proposed
closing five copies of it. "UpdateService" inside an Apple framework does
not mean what `SomeVendorUpdater` in `/Applications` means.

Rule 2 is restricted to *role* helpers for a reason found the hard way: an
earlier version matched any nested helper whose owning app was not running,
and on a real machine proposed killing `Mac Mouse Fix Helper` — a login item
that *is* the product, whose "app" is only its settings window. A role-less
`Foo Helper` is usually a persistent agent; the parenthesised role is what
marks a genuine per-session child.

Deliberately **not** a rule: "idle process holding a lot of memory". Unused
memory is not a problem to solve — macOS reclaims it under pressure — and
that criterion is precisely how cleaner apps end up closing the editor with
someone's unsaved file in it.

Nothing is signalled until you review it. Clicking Optimize opens a sheet
listing every proposal with its reason and footprint — rules 1–4 checked,
rule 5 unchecked — and you decide row by row (or use Select All). When
there is nothing to reclaim it says so in the status line rather than
interrupting with a dialog.

CPU is sampled over one second, so a helper that happens to twitch during
that window reads as busy and is skipped; run Optimize again if you expect
something that did not appear. `mac_cleaner optimize --apply` acts on the
recommended rows only — the opt-in ones cost a reload, and a non-interactive
flag is no place to make that choice for someone.

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
   `/bin`, `/sbin`, `/private`, `/Applications`, `/Volumes` and each volume
   mount point under it, and the home directory itself are always rejected
   (files *inside* an external volume are allowed), even if something were (wrongly)
   registered as an allowed root that contains them. So is anything inside
   a Photos library package (`*.photoslibrary`): its `originals/` look like
   plain photo files, but removing them behind Photos' back corrupts the
   library. The photo folder scan does not enter these packages either;
   library photos are only removed through PhotoKit.
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
7. **Organizer moves count as deletes.** A move takes a file away from its
   folder, so every source passes `isSafeToDelete()` with the chosen folder
   as the only allowed root. A move on the same volume is one
   `renamex_np(RENAME_EXCL)` call, which refuses to replace an existing
   file. A move to another volume copies first, then removes the source.
   The destination may not be inside a Photos library or a system path.
8. **Antivirus is report-only by default.** `malware::trashFinding()` refuses
   `/System` and Apple-signed code before `isSafeToDelete()` runs, and the
   only remediation is the Trash.
9. **Dry run is the default for `clean`** (and for `organize`). You always see exactly what
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
src/platform/         OS-specific backends: Trash, images, organizer moves, and
                      malware_mac.mm (Security, CommonCrypto, XProtect.plist)
src/gui/              AppKit front end: MCMainWindowController = sidebar shell,
                      MCCleanerViewController / MCLargeFilesViewController /
                      MCPerformanceViewController / MCPhotosViewController /
                      MCOrganizerViewController / MCAntivirusViewController = tools,
                      MCOptimizeSheetController = the Optimize review sheet,
                      MCScanModel / MCBigFilesModel / MCProcessModel /
                      MCPhotoModel / MCOrganizerModel / MCMalwareModel =
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
