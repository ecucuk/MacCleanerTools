# CLAUDE.md — MacCleanerTools handoff

Context for Claude Code sessions in this repo. **README.md is the source of
truth for features, CLI usage and the safety model — read it first.** This
file holds what README does not: workflow, current state, preferences, and
lessons learned the hard way.

## The user

- Writes in **Turkish**; reply in Turkish. Code, comments, commit messages
  and docs stay in **English**.
- Experienced C/C++ / systems engineer. Wants idiomatic modern C++ and
  explicit macOS API reasoning, and expects claims to be *verified*, not
  assumed.
- **Commit messages: never add a `Co-Authored-By` trailer** (explicit,
  standing request). Style: imperative subject, body explaining *why*.
- The user usually opens and merges PRs on GitHub themselves; only push /
  merge to `main` when asked.

## What it is

macOS "Swiss Army knife" for disk and performance: a C++20 core
(`maccleaner_core`) with two front ends — `mac_cleaner` CLI and
`MacCleaner.app` (AppKit, ObjC++, plus one SwiftUI window). Tools in the
app sidebar: **Storage Cleaner**, **Large Files** (with Quick Look),
**Performance** (process monitor + **Optimize**).

- Repo: `~/Projects/Repos/MacCleanerTools`
- Remote: `git@github.com:ecucuk/MacCleanerTools.git`
- Installed copy: `/Applications/MacCleaner.app` (copied from `build/`)

## Build / test / run

```sh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo   # Ninja is REQUIRED (Swift target)
cmake --build build
ctest --test-dir build --output-on-failure
open build/MacCleaner.app
ditto build/MacCleaner.app /Applications/MacCleaner.app          # install
```

- Tests: one dependency-free runner, `tests/maccleaner_tests.cpp`
  (`CHECK` / `CHECK_EQ`, register each test in `main()`).
- Icon: `resources/MacCleaner.icns` is committed; regenerate with
  `sh tools/build_icon.sh` (drawn in code by `tools/make_icon.m`, no
  third-party art).

## Layout

```
include/maccleaner/  core API: types safety scanner cleaner bigfiles processes optimizer trash cli format
src/                 core impl + CLI (main.cpp)
src/platform/        Trash backend (trash_mac.mm = NSFileManager; trash_fallback.cpp)
src/gui/             AppKit: MCMainWindowController (sidebar shell) hosts tool VCs
                     MC*ViewController = tools, MC*Model = core wrapper + serial queue
src/gui/viz/         SwiftUI Activity window (static lib, bridged via MacCleanerViz-Swift.h)
tools/ resources/    icon generator + .icns
cmake/Info.plist.in  bundle plist template
```

Pattern for every tool: logic in the C++ core (own header + tests + ideally
a CLI subcommand) → small ObjC model with a serial work queue, callbacks on
main → `NSViewController` → one `MCToolEntry` row in `MCMainWindowController.mm`.
Anything that deletes or kills goes through `safety::isSafeToDelete()` /
`isSafeToKill()`.

## Git workflow

- `main` = stable base.
- Each tool on its own `<tool>-develop` branch; shell/infra work on
  `base-develop`. Merge `main` into a branch before PR if it drifted.
- Merged so far: PR #1 (`base-develop`, quit on main-window close),
  PR #2 (`performance-develop`), plus `large-files-develop`.

## Current state (2026-10-28)

| Branch | Ahead of main | Content |
|---|---|---|
| `optimizer-develop` | 3 | Optimize button + review sheet, widened rules |
| `base-develop` | 1 | App icon (+ CMake/plist wiring) |

Both merge into `main` **cleanly** (checked with `git merge-tree`, optimizer
first then base). Not yet merged — ask before merging.

Untracked `.vscode/` is the user's editor config: leave it alone.

## Backlog

- **Startup Items manager** (requested, not started): list login items /
  LaunchAgents and *disable* them (reversible, non-destructive) rather than
  killing processes — the real lasting performance win. New tool → new
  `startup-develop` branch. Likely via `launchctl disable gui/$UID/<label>`
  and reading `~/Library/LaunchAgents`, `/Library/LaunchAgents`; SMAppService
  items need separate handling.

## Hard-won lessons (do not regress)

Verify against the **real machine**, not just synthetic tests — most bugs
below were invisible to unit tests:

- **TCC**: dirs like `~/Library/Caches/com.apple.homed`, `CloudKit`, Safari
  caches have no flags and normal modes but `opendir` fails with **EPERM**.
  Exclude on EPERM; keep on EACCES (still trashable). See `isSystemProtected`.
- `recursive_directory_iterator` aborts the *whole* walk on EPERM
  (`skip_permission_denied` only forgives EACCES) → bigfiles uses a
  hand-rolled DFS. Never use range-for over `directory_iterator` (throwing
  `operator++`); use `increment(ec)`.
- `/` in a denylist checked with "is descendant" rejects everything; the home
  dir must only be guarded against equality/ancestry, not descendants.
- **Optimizer false positives found live**: `Mac Mouse Fix Helper` (a
  LoginItem that *is* the product), `GeminiAppLauncher` (launchd-registered),
  `SetStoreUpdateService` (Apple XPC service matched the updater pattern).
  Hence: orphan rule only for *role* helpers `"* Helper (Renderer|GPU|Plugin)"`;
  exclude `/LoginItems/`, `/LaunchAgents/`, `/LaunchDaemons/`, `/System/`,
  `.xpc/`; never touch user-facing apps; idle-helper rule is opt-in
  (unchecked). Each has a regression test.
- Optimizer needs **two samples** (CPU% is a delta); one snapshot makes
  everything look idle. 1s window → sampling variance is normal.
- Optimizer filesystem check is injected (`PathExistsFn`, on `optimizer-develop`) — synthetic test
  paths would otherwise look like deleted programs.
- AppKit labels with changing text (status, paths) need **low horizontal
  compression resistance**, or Auto Layout grows the *window*.
- Status line is overwritten by the 2s refresh — use `setStickyStatusMessage:`
  for outcome messages (on `optimizer-develop`).
- A kill that fails because the process already exited counts as success.

## Environment gotchas

- **Xcode license**: an Xcode update can gate `/usr/bin/clang`, `swiftc`,
  `xcrun` ("You have not agreed to the Xcode license") and break CMake
  configure. User fixes with `sudo xcodebuild -license accept` (needs their
  password — don't run it). `build_icon.sh` honours `$CC`/`$CFLAGS` for a
  Homebrew-clang fallback (see README).
- **No Accessibility permission** for Claude: `osascript` UI clicks fail.
  Verify GUI visually with `screencapture -x` + Read; verify logic via the
  CLI (same core code). Tell the user which UI step they must click.
- Copied Apple-signed binaries (e.g. `cp /bin/sleep`) die on launch (code
  signing). For fake processes in experiments, compile a tiny C program.
- `cmake --build build | grep error` then a second build printing
  `ninja: no work to do` is normal. If the build failed, `ctest` runs the
  **stale** binary and still says passed — check the build output first.
- Scratch/diagnostic files go in the session scratchpad, never the repo.
