# File Organizer — design

Date: 2026-10-29. Branch: `organizer-develop` (from `main`).

## Goal

Sort a flat or mixed folder (for example `Photos/unCategorized`, 10,982
photos and videos) into folders by file type, then by date (media) or by
artist and album (music). The tool is a new sidebar entry. It is not part
of Photo Cleaner.

Success: run on a copy of `/Volumes/ecHDD/Photos/unCategorized`, preview
the plan, organize, and get every file under the destination with no file
lost, overwritten or left in a wrong place.

## Layout rules

Each file goes to `<dest>/<relative target>`:

| Kind | Extensions (case-insensitive) | Target |
|---|---|---|
| Photos | jpg jpeg heic heif png gif tif tiff bmp webp dng cr2 cr3 nef arw raf orf rw2 | `Photos/YYYY/YYYY-MM/<name>` |
| Videos | mp4 mov m4v avi mkv mts m2ts 3gp wmv webm | `Videos/YYYY/YYYY-MM/<name>` |
| Music | mp3 m4a aac flac wav aiff aif alac ogg opus wma | `Music/<Artist>/<Album>/<name>` |
| Documents | pdf doc docx xls xlsx ppt pptx key pages numbers txt rtf md csv odt | `Documents/<name>` |
| Other | everything else | `Other/<name>` |

- Date for photos: EXIF `DateTimeOriginal`, else TIFF `DateTime`.
- Date for videos: the AVFoundation `creationDate` of the asset.
- If metadata has no date, use the file birth time (`st_birthtime`).
- Music: the AVFoundation common metadata `artist` and `albumName`. Use
  `Unknown Artist` / `Unknown Album` when a tag is missing. Replace `/`
  and `:` in tag values with `-`, trim spaces, and use the fallback for
  an empty result or for `.` / `..`.
- Dates use the local time zone.

## Collisions and no-ops

- A file whose target equals its current path is skipped (already
  organized). Running the tool twice moves nothing the second time.
- The planner never gives two files the same target. It also never
  targets a path that exists on disk. The second file gets
  `name (2).ext`, then `(3)`, and so on.
- The move itself does not replace an existing file. If the target
  appears between plan and move, the file stays and the problem is
  reported.

## Safety

- Every source passes `safety::isSafeToDelete()` with the source folder
  as the allowed root. A move removes the file from its old place, so it
  gets the same check as a delete.
- The destination must not be inside a Photos library
  (`isInsidePhotosLibrary`) and must not be under `hardDenylist()`.
- The walk does not enter `*.photoslibrary`, app bundles (`*.app`),
  hidden directories, or the destination's own `Photos/ Videos/ Music/
  Documents/ Other/` folders when the destination is inside the source.
  Hidden files (dot files) are skipped.
- Moves use `rename(2)` on the same volume. Across volumes they use
  NSFileManager `moveItemAtURL:` (copy, then remove). A failed cross-volume
  move keeps the source.
- Empty source folders stay. The tool deletes no file or folder.

## Components

```mermaid
flowchart LR
  W[walkFiles] --> M[readMetadata<br/>metadata_mac.mm]
  M --> P[planOrganize<br/>organizer.cpp]
  P --> V[preview: CLI / GUI]
  V -->|apply| X[applyPlan<br/>safety + move]
```

1. `include/maccleaner/organizer.hpp`, `src/organizer.cpp` (pure C++):
   - `enum class Kind { Photos, Videos, Music, Documents, Other }`,
     `kindName()`, `kindFromPath()`.
   - `struct FileMeta { path; Kind; optional<time_t> date; artist; album; }`.
   - `struct Move { from; to; }`.
   - `planOrganize(files, dest, existsFn) -> vector<Move>`: applies the
     layout rules, the skip rule and the collision rule. `existsFn` is
     injected, like `PathExistsFn` in the optimizer, so tests need no
     real files.
   - `scanForOrganize(source, dest, cancelled, progress) -> vector<FileMeta>`:
     walks with `walkFiles` and the directory filter above, and calls the
     metadata reader.
   - `applyPlan(moves, allowed, progress, cancelled) -> Result {moved, problems}`.
2. `src/platform/metadata_mac.{h,mm}`: `readMetadata(path, kind, FileMeta&)`
   with ImageIO (`CGImageSourceCopyPropertiesAtIndex`, no decode) and
   AVFoundation (`AVURLAsset` metadata). `src/platform/move_mac.mm`
   gives `moveFile()`. `src/platform/metadata_fallback.cpp` for the
   non-Apple build uses birth time only and `std::filesystem::rename`
   (the same pattern as `image_fallback.cpp`).
3. CLI: `mac_cleaner organize <dir> [--dest <dir>] [--apply]`. The default
   is a dry run. It prints a count per kind and the first moves. With
   `--apply`, it asks for confirmation the same way the cleaner does.
4. GUI: `MCOrganizerModel` (serial queue, callbacks on main) and
   `MCOrganizerViewController`:
   - Source and destination pickers. The destination is the source by
     default. The last folders are remembered in `NSUserDefaults`.
   - **Preview** builds the plan and shows an outline view: kind > year
     (or artist) > month (or album) > files, with counts.
   - **Organize** applies the plan with progress and Cancel, then shows
     the moved count and a sheet with any problems.
   - A new `MCToolEntry` "File Organizer" in `MCMainWindowController.mm`.
5. CMake: add the new sources to the `if(APPLE)` platform list, and link
   AVFoundation to `maccleaner_core` next to ImageIO (already linked).

## Error handling

- An unreadable directory is skipped by `walkFiles` and the walk goes on.
- A file with unreadable metadata uses birth time / Unknown tags.
- A rejected or failed move is a problem entry `path: reason`. The other
  moves continue.
- Cancel stops between files. Files already moved stay moved, and a new
  run continues with the rest.

## Testing

- Unit tests in `tests/maccleaner_tests.cpp`:
  - `kindFromPath` for each kind and for upper-case extensions.
  - `planOrganize`: date paths, music paths, the Unknown fallbacks, tag
    sanitizing, the skip rule, collisions inside the plan and with
    existing files.
  - `applyPlan` on a temporary folder under `$HOME` (the safety layer
    rejects `/private`): moves, a refused move outside the allowed root,
    a second run that moves nothing.
- Live check on a copy of about 200 files from
  `/Volumes/ecHDD/Photos/unCategorized` in `~/MCOrganizeTest`, with the
  CLI and the GUI model. Never on the original files.
- Ninja build with no new warnings; `ctest` passes; README updated.

## Not in scope

Copy mode; undo and a move log; deleting empty folders; content
(Vision) categories; matching photos to existing event folders by date;
duplicate detection (Photo Cleaner does that).
