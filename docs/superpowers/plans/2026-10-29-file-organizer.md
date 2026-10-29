# File Organizer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "File Organizer" tool (core, CLI, GUI). It moves files into
`Photos/<Category>/YYYY/YYYY-MM`, `Videos/YYYY/YYYY-MM`, `Music`,
`Documents` and `Other`.

**Architecture:** The pure C++ core (`organizer.hpp/.cpp`) owns kind
detection, category mapping, planning, scanning and applying. Two
platform functions are declared in the core header and implemented per
platform: `readMetadata` (ImageIO, Vision, AVFoundation) and `moveFile`
(NSFileManager). This is the same pattern as `decodeImageFile` in
`photos.hpp`. The CLI and an ObjC model and view controller wrap the core.

**Tech Stack:** C++20, ObjC++, ImageIO, Vision, AVFoundation, AppKit,
CMake + Ninja.

**Spec:** `docs/superpowers/specs/2026-10-29-file-organizer-design.md`

## Global Constraints

- Branch `organizer-develop`. Commits: imperative subject, a body that
  says why, **no Co-Authored-By trailer**. Do not push.
- Code, comments and docs are in English.
- A move removes the source, so every source passes
  `safety::isSafeToDelete()` with the source folder as the only allowed root.
- No file is ever overwritten. Collisions get the suffixes ` (2)`, ` (3)`, … before the extension.
- Vision confidence threshold: `0.5`. Thumbnail max pixel size: `512`.
- Tests stay in `tests/maccleaner_tests.cpp` (`CHECK` / `CHECK_EQ`). Register each test in `main()`.
  Temporary folders live under `$HOME` (`/private` is denylisted).
- Build: `cmake --build build 2>&1 | grep -E "error|warning: " ; ctest --test-dir build --output-on-failure | tail -3`.
  Check the build output before you trust ctest, because a failed build
  leaves a stale binary.
- Deviation from the spec: `src/platform/organizer_mac.mm` and
  `organizer_fallback.cpp` hold both `readMetadata` and `moveFile`.
  The spec named separate `metadata_*` and `move_mac.mm` files. One file
  per platform matches `image_mac.mm`.

## Review Focus

1. Destination inside the source (the default): a second run must move
   nothing, and the walk must not re-plan files under `Photos/ Videos/
   Music/ Documents/ Other/` → Task 3 test `testScanSkipsOrganizedFolders`.
2. The same file name from two subfolders (`a/IMG_1.jpg`, `b/IMG_1.jpg`,
   same month) → `IMG_1.jpg` and `IMG_1 (2).jpg` → Task 1
   `testPlanCollisions`.
3. Non-ASCII names and spaces (`Kına ğ.JPG`, `Barış & Semra`) keep their
   bytes, and the extension case does not change the kind → Task 1
   `testKindFromPath`, `testPlanPhotoPaths`.
4. A source that vanishes between plan and apply (an unplugged HDD, or a
   file deleted in Finder) → a problem entry, and the other moves go on →
   Task 2 `testApplyReportsMissingSource`.
5. A target that appears between plan and apply → the source stays and the
   problem is reported, with no overwrite → Task 2
   `testApplyNeverOverwrites`.

---

### Task 1: Core kinds, categories and planner

**Files:**
- Create: `include/maccleaner/organizer.hpp`, `src/organizer.cpp`
- Modify: `CMakeLists.txt` (add `src/organizer.cpp` next to `src/photos.cpp`, line ~50)
- Test: `tests/maccleaner_tests.cpp`

**Interfaces (namespace `maccleaner::organizer`):**
- Produces:
  - `enum class Kind : uint8_t { Photos, Videos, Music, Documents, Other };` and `const char* kindName(Kind)`.
    `kindName` returns the folder name, for example `"Photos"`.
  - `Kind kindFromPath(const std::filesystem::path&)`: uses the extension tables from the spec and is case-insensitive.
  - `enum class PhotoCategory : uint8_t { Other, Screenshots, Documents, People, Animals, Food, Vehicles, Buildings, Nature };`
    Also produce `const char* categoryName(PhotoCategory)`.
  - `struct Label { std::string identifier; float confidence; };` and `constexpr float kMinLabelConfidence = 0.5f;`.
  - `PhotoCategory categoryFromLabels(const std::vector<Label>&)`.
  - `struct FileMeta { std::filesystem::path path; Kind kind; std::optional<std::time_t> date; PhotoCategory category = PhotoCategory::Other; };`
  - `struct Move { std::filesystem::path from, to; };`
  - `using ExistsFn = std::function<bool(const std::filesystem::path&)>;`
  - `std::vector<Move> planOrganize(const std::vector<FileMeta>&, const std::filesystem::path& dest, const ExistsFn& exists);`

- [ ] **Step 1: Write the failing tests**
  - `testKindFromPath`:
    - `a.JPG`, `b.heic` and `Kına ğ.JPG` → Photos.
    - `c.MP4` and `d.mov` → Videos.
    - `e.mp3` → Music.
    - `f.PDF` → Documents.
    - `g`, `h.xyz` and `.DS_Store` → Other.
  - `testCategoryFromLabels`: take the test body from `git show ba1e5f9:tests/maccleaner_tests.cpp` (`testCategoryFromLabels`).
    Change only the namespace and type names.
  - `testPlanPhotoPaths`:
    - Input: a photo with date `1689422400` (2023-07-15 12:00 UTC, the same month in every time zone), category Nature, path `/s/x/Kına ğ.JPG`, and dest `/d`.
    - Expected: `to == "/d/Photos/Nature/2023/2023-07/Kına ğ.JPG"`.
  - `testPlanOtherKinds`, all with the same date:
    - A video goes to `/d/Videos/2023/2023-07/v.mp4`.
    - Music goes to `/d/Music/m.mp3`.
    - A document goes to `/d/Documents/f.pdf`.
    - Other goes to `/d/Other/g`.
    - A file with no date gets no move (the scan always fills in the date, see Task 3).
  - `testPlanSkipsAlreadyPlaced`: a file whose path already equals its target gives no move.
  - `testPlanCollisions`:
    - Two files `a/IMG_1.jpg` and `b/IMG_1.jpg` go to the same folder. The targets are `IMG_1.jpg` and `IMG_1 (2).jpg`.
    - When `exists` returns true for `.../IMG_1.jpg`, the first file gets `IMG_1 (2).jpg`.
- [ ] **Step 2: Run the tests and make sure they fail to compile (the header is missing).**
- [ ] **Step 3: Implement the header and the functions in `organizer.cpp`.**
  - Copy `categoryFromLabels` and its rule table from `git show ba1e5f9:src/photos.cpp`.
  - Format dates with `localtime_r` and `"%Y"` / `"%Y-%m"`.
  - Track the targets already taken in a `std::set<std::filesystem::path>`.
  - Suffix rule: `stem + " (" + n + ")" + extension`, with n starting at 2.
- [ ] **Step 4: Build and run ctest. Expect all tests to pass.**
- [ ] **Step 5: Commit:** `Add the organizer planner with photo categories`

### Task 2: Apply moves safely

**Files:**
- Modify: `include/maccleaner/organizer.hpp`, `src/organizer.cpp`
- Create: `src/platform/organizer_mac.mm` (only `moveFile` in this task), `src/platform/organizer_fallback.cpp`
- Modify: `CMakeLists.txt` (`if(APPLE)` list at line ~59: add `organizer_mac.mm`, else `organizer_fallback.cpp`)
- Test: `tests/maccleaner_tests.cpp`

**Interfaces:**
- Consumes: `Move` (Task 1), `safety::AllowedRoots`, `safety::isSafeToDelete`, `safety::isInsidePhotosLibrary`, `safety::hardDenylist`.
- Produces:
  - `bool moveFile(const std::filesystem::path& from, const std::filesystem::path& to, std::string* error);`
    It creates the parent folders of `to`. It fails when `to` exists. The mac version uses NSFileManager `createDirectoryAtURL` and `moveItemAtURL`.
    The fallback checks `exists`, then calls `fs::rename`.
  - `bool isValidDestination(const std::filesystem::path& dest, std::string* reason);`
    It returns false when `dest` is empty, inside a Photos library, or equal to or under a `hardDenylist()` entry.
  - `struct ApplyResult { std::size_t moved = 0; std::vector<std::string> problems; };`
    Each problem has the form `"<path>: <reason>"`.
  - `using ApplyProgress = std::function<void(std::size_t done, std::size_t total)>;`
  - `ApplyResult applyPlan(const std::vector<Move>&, const std::filesystem::path& source, const std::atomic<bool>* cancelled = nullptr, const ApplyProgress& = {});`

- [ ] **Step 1: Write the failing tests.** Use a scratch folder under `$HOME`, the same pattern as `ScratchTree`.
  - `testApplyMovesFiles`: two files are moved, `moved == 2`, the sources are gone, and the targets exist.
  - `testApplyRefusesOutsideSource`: a move whose `from` is outside `source` stays in place and gives one problem.
  - `testApplyNeverOverwrites`: the target exists with other content. The source stays, the target content does not change, and there is one problem.
  - `testApplyReportsMissingSource`: one source is deleted before the apply. The result is one problem and `moved == 1` for the other file.
  - `testIsValidDestination`:
    - `""` is false.
    - `/System/x` is false.
    - `$HOME/Pictures/P.photoslibrary/x` is false.
    - `$HOME/Org` is true.
- [ ] **Step 2: Run the tests and make sure they fail.**
- [ ] **Step 3: Implement the functions.**
  - `applyPlan` checks `cancelled` before each move.
  - For each move, it calls `isSafeToDelete(from, {source})`, then `moveFile`.
- [ ] **Step 4: Build and run ctest. Expect all tests to pass.**
- [ ] **Step 5: Commit:** `Apply organizer moves through the safety layer`

### Task 3: Metadata reader and scan

**Files:**
- Modify: `include/maccleaner/organizer.hpp`, `src/organizer.cpp`, `src/platform/organizer_mac.mm`, `src/platform/organizer_fallback.cpp`
- Modify: `CMakeLists.txt`: `find_library` AVFoundation and Vision next to ImageIO (line ~87), and link them to `maccleaner_core`
- Test: `tests/maccleaner_tests.cpp`

**Interfaces:**
- Consumes: `walkFiles` (`walk.hpp`), `FileMeta`, `Kind`, `categoryFromLabels`.
- Produces:
  - `void readMetadata(FileMeta& meta);`
    It fills `date` and `category` for Photos, and `date` for Videos. It leaves `date` empty when no metadata date exists.
  - `using MetadataFn = std::function<void(FileMeta&)>;`
  - `using ScanProgress = std::function<void(std::size_t filesSeen)>;`
  - `std::vector<FileMeta> scanForOrganize(const std::filesystem::path& source, const std::filesystem::path& dest, const std::atomic<bool>* cancelled = nullptr, const ScanProgress& = {}, const MetadataFn& read = readMetadata);`

- [ ] **Step 1: Write the failing tests.** Use a fake `read` that sets nothing.
  - `testScanFillsBirthTime`: after the scan, every entry has a `date`. The date is the birth time (`st_birthtimespec.tv_sec`) and comes from the fallback.
  - `testScanSkipsOrganizedFolders`:
    - Input: `dest == source`, and files in `source/Photos/x.jpg`, `source/.hidden/y.jpg`, `source/.z.jpg`, `source/A.app/c.jpg`, `source/L.photoslibrary/d.jpg` and `source/sub/e.jpg`.
    - Expected: only `sub/e.jpg` is returned.
  - `testOrganizeTwiceMovesNothing`: `scanForOrganize`, then `planOrganize`, then `applyPlan`, then repeat. The second plan is empty.
- [ ] **Step 2: Run the tests and make sure they fail.**
- [ ] **Step 3: Implement the scan in `organizer.cpp`.**
  - Call `walkFiles` with a `DirFilter`. The filter rejects names that start with `.`, end in `.app` or `.photoslibrary`, and the five kind folders directly under `dest`.
  - Skip files whose names start with `.`.
  - After `read`, use `st.st_birthtimespec.tv_sec` when `date` is empty.
- [ ] **Step 4: Implement `readMetadata` in `organizer_mac.mm`.**
  - Photos:
    - Get the EXIF `DateTimeOriginal`, else the TIFF `DateTime`, with `CGImageSourceCopyPropertiesAtIndex`.
    - Parse `"%Y:%m:%d %H:%M:%S"` as local time with `mktime`.
    - Make a thumbnail with `CGImageSourceCreateThumbnailAtIndex`: max pixel size 512, transform with the orientation, create it always.
    - Use the Vision body from `git show ba1e5f9:src/platform/image_mac.mm` (`classifyCGImage`), then `categoryFromLabels`.
  - Videos: read `AVURLAsset.creationDate.dateValue` synchronously. This is a deprecated but working API on macOS. If it produces a deprecation warning, use `loadMetadataForFormat`. Do not add new warnings.
  - Wrap each file in `@autoreleasepool`.
  - The fallback leaves `meta` unchanged.
- [ ] **Step 5: Build and run ctest. Expect all tests to pass with no new warnings.**
- [ ] **Step 6: Commit:** `Read photo dates, Vision categories and video dates`

### Task 4: CLI `organize`

**Files:**
- Modify: `include/maccleaner/cli.hpp` (`Command::Organize`, `std::string dest;`), `src/cli.cpp` (parse, usage), `src/main.cpp` (run)
- Test: `tests/maccleaner_tests.cpp`

**Interfaces:**
- Consumes: `scanForOrganize`, `planOrganize`, `applyPlan`, `isValidDestination`.

- [ ] **Step 1: Write the failing test.**
  - `testParseOrganize`:
    - `organize /a --dest /b --apply` → `Organize`, `under == "/a"`, `dest == "/b"`, `apply`.
    - `organize` with no folder → a parse error.
- [ ] **Step 2: Implement parsing and usage.** Follow the existing `photos <dir>` handling.
- [ ] **Step 3: Implement the run in `main.cpp`.**
  - When `dest` is empty, the destination is the source.
  - Reject an invalid destination with its reason and exit code 1.
  - Print the count per kind and per photo category, then the first 20 moves as `from -> to`.
  - With `--apply`, confirm the same way the cleaner does (`--yes` skips the question), then print the moved count and the problems.
- [ ] **Step 4: Build, run ctest, then run a live dry run.**
  - Copy about 200 mixed files from `/Volumes/ecHDD/Photos/unCategorized` to `~/MCOrganizeTest` with `ditto`. Pick them with `find … | head`.
  - Run `build/mac_cleaner organize ~/MCOrganizeTest`.
  - Expected: photos are split across categories, videos are under the right years, and there are 0 problems.
  - Run with `--apply --yes`, then run the dry run again. Expected: 0 moves.
  - Never use the original folder.
- [ ] **Step 5: Commit:** `Add the organize CLI subcommand`

### Task 5: GUI tool

**Files:**
- Create: `src/gui/MCOrganizerModel.{h,mm}`, `src/gui/MCOrganizerViewController.{h,mm}`
- Modify: `src/gui/MCMainWindowController.mm`: add a `MCToolEntry` after Photo Cleaner (line ~164): title `File Organizer`, symbol `folder.badge.gearshape`, and a new `MCToolOrganizer` enum value.
- Modify: `CMakeLists.txt`: add the GUI sources next to `MCPhotosViewController.mm` (line ~159).

**Interfaces:**
- Consumes: the Task 2 and Task 3 functions. Copy the queue, callback and status helper patterns from `MCPhotoModel` and `MCPhotosViewController`.
- Produces (model):
  - `-previewSource:(NSString *)source destination:(NSString *)dest progress:(void (^)(NSUInteger seen))progress completion:(void (^)(NSArray<MCOrganizerGroup *> *groups, NSUInteger moveCount, NSString *error))completion`
    It keeps the plan internally.
  - `-organizeWithProgress:(void (^)(NSUInteger done, NSUInteger total))progress completion:(void (^)(NSUInteger moved, NSArray<NSString *> *problems))completion`
  - `-cancel`
  - `MCOrganizerGroup` has `title`, `count` and `children`. It holds the outline tree kind > category > year > month and holds no file rows.

- [ ] **Step 1: Build the view.**
  - Show the Source and Destination path controls with "Choose…" buttons. The destination is the source by default. Store both in `NSUserDefaults` under the keys `MCOrganizerSource` and `MCOrganizerDestination`.
  - Add the **Preview**, **Organize** and **Cancel** buttons.
  - Show an `NSOutlineView` of groups with counts and a status line.
  - Use `setStickyStatusMessage:` (or the local equivalent) for outcome messages.
  - Give changing labels low horizontal compression resistance.
- [ ] **Step 2: Add the confirmation and the problems sheet.**
  - Before **Organize**, show an `NSAlert`: "Move N files into <dest>?". The buttons are Move and Cancel.
  - After the moves, show the problems in a sheet, as Photo Cleaner does (`showProblems:`).
- [ ] **Step 3: Build and make sure there are no new warnings.**
  - Run `open build/MacCleaner.app`.
  - Ask the user to check Preview and Organize on `~/MCOrganizeTest` (restore the test copy first). Claude cannot click the GUI.
  - Check the model logic through the CLI path, which uses the same core.
- [ ] **Step 4: Commit:** `Add the File Organizer tool to the sidebar`

### Task 6: Docs and wrap-up

**Files:**
- Modify: `README.md` (tool list, `organize` CLI usage, safety notes), `CLAUDE.md` (tool list and branch table)

- [ ] **Step 1: Document the tool and the CLI.**
  - Describe the folder layout, the collision rule, the rule that a move gets the same safety check as a delete, and the dry-run default.
- [ ] **Step 2: Do a full clean build and ctest.**
  - Run `cmake --build build` and expect no new warnings.
  - Run ctest and expect all tests to pass.
  - Delete `~/MCOrganizeTest` only after the user says yes.
- [ ] **Step 3: Commit:** `Document the File Organizer`

---

## Amendment: location (spec addendum)

Run these tasks after Task 3 and before Task 4. Task 4 adds `--by=content|place`. Task 5 adds a
layout pop-up (Content / Place), a Folders/Map segmented control, and an
`MKMapView` with one `MKPointAnnotation` per cell (title `"<count> photos"`).
Link MapKit to the app target, and to `maccleaner_core` for the geocoder.

### Task 3a: GPS, grid cells and the place layout

**Files:** `include/maccleaner/organizer.hpp`, `src/organizer.cpp`, `src/platform/organizer_mac.mm`, tests.

**Produces:**
- `struct GeoPoint { double latitude; double longitude; };`
- `FileMeta` gets `std::optional<GeoPoint> location`, `std::string country`, and `std::string city`.
- `enum class PhotoLayout : std::uint8_t { Content, Place };`
- `planOrganize(files, dest, exists, PhotoLayout layout = PhotoLayout::Content)`
- `struct GeoCell { int lat; int lon; auto operator<=>(const GeoCell&) const = default; };`
  - `GeoCell cellOf(GeoPoint)`: `floor(deg / 0.05)`.
  - `GeoPoint cellCenter(GeoCell)`.
- `std::string folderName(std::string_view raw, std::string_view fallback)`: replaces `/` and `:` with `-` and trims spaces. It returns `fallback` for an empty result or for `.` / `..`.

**Tests:**
- `testCellOf`: (41.0082, 28.9784) and (41.0101, 28.9799) give the same cell. (-33.9, 18.4) gives `lat == -678`.
- `testPlanPlaceLayout`:
  - country `Turkey`, city `Istanbul` → `/d/Photos/Turkey/Istanbul/2023/2023-07/a.jpg`.
  - no location → `/d/Photos/Unknown Place/2023/2023-07/b.jpg`.
  - country set, city empty → `.../Turkey/Unknown City/...`.
  - a video does not change.
- `testFolderName`: `"A/B: C "` → `"A-B- C"`. `""` → fallback. `".."` → fallback.

**Mac:** In `readPhoto`, read `kCGImagePropertyGPSDictionary`. Use a negative sign for `S` and `W`.

**Commit:** `Add GPS locations and the place layout to the organizer`

### Task 3b: Reverse geocoding with cache

**Files:** organizer header and cpp, `organizer_mac.mm`, `organizer_fallback.cpp`, `CMakeLists.txt` (MapKit), tests.

**Produces:**
- `struct Place { std::string country; std::string city; };`
- `enum class GeocodeStatus { Found, NotFound, Throttled, Failed };`
- `using GeocodeFn = std::function<GeocodeStatus(GeoPoint, Place&)>;`
- `GeocodeStatus reverseGeocode(GeoPoint, Place&);` (platform code)
  - Use `MKReverseGeocodingRequest` with `addressRepresentations.regionName` and `cityName`.
  - Its completion runs on the main queue. Off the main thread, wait on a semaphore. On the main thread (CLI), spin `CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, true)` until it is done.
  - A throttled request is `MKErrorLoadingThrottled`.
  - The fallback returns `Failed`.
- `void resolvePlaces(std::vector<FileMeta>&, const std::filesystem::path& cacheFile, const std::atomic<bool>* cancelled = nullptr, const std::function<void(std::size_t done, std::size_t total)>& progress = {}, const GeocodeFn& geocode = reverseGeocode, const std::function<void(std::chrono::milliseconds)>& sleep = <std::this_thread::sleep_for>);`
  - It groups the files by cell and reads the cache.
  - It geocodes only the missing cells, with a 1200 ms sleep between requests. After `Throttled`, it sleeps 60 s and retries once.
  - It saves `Found` and `NotFound` cells (an empty country and city) and does not save `Failed`.
  - It fills `country` and `city` for every file.

**Tests:** Use a fake geocode that counts its calls, and a fake sleep that records its durations.
- `testResolvePlacesGroupsCells`: three photos in two cells → two calls, and every file has its place.
- `testResolvePlacesUsesCache`: a second run with the same cache file → zero calls.
- `testResolvePlacesRetriesThrottled`:
  - The first call returns Throttled and the second returns Found.
  - The sleeps include 60000 ms, and the place is set.
- `testResolvePlacesSkipsFailedInCache`: Failed → the next run asks again.

**Commit:** `Reverse geocode photo locations with a grid cache`
