# mac-cleaner

A CLI tool for finding and reclaiming disk space on macOS: application
caches, logs, Xcode DerivedData/Archives/DeviceSupport, Simulator caches,
and package-manager caches (Homebrew, npm, Yarn, pip).

## Build

Requires a recent Xcode / Command Line Tools (Clang with `std::filesystem`
and Objective-C++ support) and CMake >= 3.21.

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build -j
```

Run the tests:

```sh
ctest --test-dir build --output-on-failure
```

## Usage

```sh
build/mac_cleaner scan                          # report only, all categories
build/mac_cleaner scan --only=derived-data,npm   # report only, subset
build/mac_cleaner clean                          # dry run (same as scan, but through the clean path)
build/mac_cleaner clean --apply                  # actually move items to Trash
build/mac_cleaner clean --apply --permanent      # skip Trash, remove_all (irreversible)
```

`clean` without `--apply` never touches the filesystem. `--permanent`
requires `--apply` and is not the default: normal `--apply` moves items to
the Finder Trash via `NSFileManager`, so anything removed is recoverable
until you empty it.

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
   directory can't inflate a size total or get traversed into.
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
- `directorySizeBytes()` does a full recursive walk per top-level entry on
  every run; for very large `DerivedData`/cache trees this is I/O-bound and
  not cached between invocations.

## Layout

```
include/maccleaner/   public headers (types, safety, scanner, cleaner, trash, cli, format)
src/                  implementation
src/platform/         OS-specific Trash backend (trash_mac.mm / trash_fallback.cpp)
tests/                dependency-free CTest suite
```

## Extending

To add a new cleanup category: add an enum value to `Category`
(`types.hpp`), a case in `toString()`, an entry in `defaultTargets()`
(`scanner.cpp`), and a CLI alias in `parseCategory()` (`cli.cpp`). No
changes to the safety layer are needed — new roots are picked up
automatically via `registerAllowedRoots()`.
