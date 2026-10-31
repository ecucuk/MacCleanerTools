# Updater — design

Date: 2026-10-31. Branch: `updater-develop` (from `origin/main` 76b3d8e).

## Goal

List outdated software from four sources in one place. Update the
Homebrew items that the user selects. For the other sources, show what is
outdated and give one click to the place that can update it.

Success: on the real machine, `mac_cleaner updates` and the GUI show the
same list. The Sparkle apps and App Store apps on this Mac show correct
installed and latest versions. A selected outdated brew package updates
with per-row status. The Ninja build is clean and `ctest` passes.

## Scope (first release)

| Source | Detect | Check | Action |
|---|---|---|---|
| Homebrew | `/opt/homebrew/bin/brew` or `/usr/local/bin/brew` | `brew update`, then `brew outdated --json=v2` | select, then `brew upgrade <name>` |
| MacPorts | `/opt/local/bin/port` | `port outdated` | "Copy command" (`sudo port upgrade <name>`) |
| App Store | `<app>/Contents/_MASReceipt` exists, id from `mdls -raw -name kMDItemAppStoreAdamID` | one request: `https://itunes.apple.com/lookup?id=a,b,c&country=<cc>` | "Open in App Store" (`macappstore://apps.apple.com/app/id<id>`) |
| Sparkle | `SUFeedURL` in `Info.plist`, https only, app not managed by a brew cask | fetch the appcast, take the highest item that has no `sparkle:channel` | "Open app" (Sparkle in the app offers the update) |

Not in scope:
- Apps that come from none of these sources. There is no reliable
  version source for them.
- `mas` CLI, privileged helpers, and in-app sudo. The app never runs
  `sudo` and never asks for or stores a password.
- A Home hub card. PR #13 (`home-develop`) is not merged yet. Add the card
  in a follow-up after the merge, from a cached result only.

Apps are found as top-level `*.app` in `/Applications` and
`~/Applications`.

## Rules

- All tools are called with absolute paths. A GUI app has no shell
  `PATH`.
- A missing tool is not an error. The source shows an info row, for
  example "Homebrew is not installed".
- The app does no network access on launch. Network access happens only
  when the user clicks "Check" or runs `mac_cleaner updates`.
- Network access uses `/usr/bin/curl -fsSL --proto =https --max-time 10
  --max-filesize 5M`. Feeds with an `http:` URL are skipped.
- Country code for the iTunes lookup: the region of the current locale,
  lowercased. If the region is missing, use `us`. An app id that the
  lookup does not return is skipped (for example a region-limited app).
- Cask/Sparkle overlap: `brew info --cask --json=v2 --installed` lists
  the `app` artifacts of each installed cask. A Sparkle app whose bundle
  name is in that set is not listed as Sparkle. If it is outdated,
  Homebrew already lists it.
- Pinned formulae are listed but cannot be selected.

## Version comparison

`compareVersions(a, b)` splits both strings into parts: each maximal
run of digits or of letters is one part, and all other characters are
separators. It compares the parts left to right. Numeric parts compare
as numbers (`1.10 > 1.9`). Text parts compare as strings, case-insensitive.
A text part is lower than a numeric part, so `2.0b1 < 2.0`. A missing
part counts as `0`, so `1.0 == 1`. App Store: compare the store `version` with
`CFBundleShortVersionString`. Sparkle: compare the item `sparkle:version`
with `CFBundleVersion` (Sparkle's own rule). Show
`sparkle:shortVersionString` when it is present.

## Core API (`include/maccleaner/updater.hpp`)

```cpp
namespace maccleaner::updater {
enum class Source { Homebrew, MacPorts, AppStore, Sparkle };

struct OutdatedItem {
    Source source;
    std::string name;             // brew/port token, or the app name
    std::string installedVersion;
    std::string latestVersion;
    std::string appPath;          // App Store and Sparkle
    std::string storeId;          // App Store
    bool isCask = false;          // Homebrew
    bool pinned = false;          // Homebrew
};

struct SourceStatus { Source source; bool available; std::string error; };
struct CheckResult { std::vector<OutdatedItem> items; std::vector<SourceStatus> sources; };

struct CommandResult { int exitCode; std::string output; };
using RunFn = std::function<CommandResult(const std::vector<std::string>& argv, int timeoutSeconds)>;

CommandResult runCommand(const std::vector<std::string>& argv, int timeoutSeconds); // posix_spawn
CheckResult checkUpdates(const RunFn&, const Environment&, const std::function<bool()>& cancelled);
CommandResult upgradeBrew(const RunFn&, const Environment&, const OutdatedItem&);
}
```

`Environment` holds the injected inputs that the tests replace: the brew
and port paths (empty = not installed), the app folders, a
`readInfoPlist` function and the country code. The parsers
(`parseBrewOutdated`, `parseBrewCaskApps`, `parsePortOutdated`,
`parseItunesLookup`, `parseAppcast`) and `compareVersions` are public
for the tests.

`runCommand` uses `posix_spawn` with no shell. Its stdin is `/dev/null`.
It merges stderr into stdout through one pipe. When the timeout expires,
it sends `SIGTERM` and returns exit code `-1`. Arguments are an argv
vector, so names from JSON or XML can never inject a shell command.

JSON: the repo has no JSON library. Add a small JSON reader to the core
(objects, arrays, strings with escapes, numbers, booleans, null). Do not
add a dependency. Appcast XML: scan the `<item>` blocks as strings. Read
the `sparkle:version` and `sparkle:shortVersionString` values as
attributes of `<enclosure>` or as elements.

Timeouts: `brew update` 120 s, other checks 60 s, curl 10 s, and
`brew upgrade` 30 min.

## Upgrade, progress and cancel

- Upgrade only Homebrew items. Run one `brew upgrade [--cask] <name>`
  per item, in sequence, with `HOMEBREW_NO_AUTO_UPDATE=1` and
  `NONINTERACTIVE=1` (passed through `env`).
- Row state: Pending, Upgrading, Done or Failed. A failed row shows the
  last line of the output. A cask that needs a password fails because
  there is no TTY. That row offers "Copy command".
- Cancel: the running `brew` finishes. The model does not start the
  remaining items. A killed `brew` can leave a lock or a partial
  install. During a check, cancel skips the remaining sources.

## CLI

- `mac_cleaner updates` checks all sources and prints one table, grouped
  by source, plus the status of each source.
- `mac_cleaner updates --upgrade <name>...` checks Homebrew, then
  upgrades the given brew items in sequence. A name that is not an
  outdated brew item is an error. It exits non-zero if an upgrade fails.

## GUI

- `MCUpdaterModel`: a serial work queue. It calls back on the main
  thread. It owns the cancel flag.
- `MCUpdaterViewController`: a hero screen with "Check". After the check:
  `MCToolBanner`, then one table grouped by source. The columns are
  select, name, installed, latest, source, and action/state. Below the
  table: "Update selected" (Homebrew rows only) and "Cancel".
- `MCToolUpdater` is a new `MCTool` value with its own gradient. Add one
  `MCToolEntry` row in `MCMainWindowController.mm`. PR #13 also adds a
  value to this enum, so expect a small merge conflict.
- Changing labels get low horizontal compression resistance. Outcome
  messages use the sticky status.

## Safety

The Updater does not delete files or end processes. It does not use
`safety::`. Its risks are network access (https only, size and time
caps), running package managers (absolute paths, no shell, no sudo) and
false "outdated" results (channel filter, cask overlap, numeric version
compare).

## Tests (`tests/maccleaner_tests.cpp`)

- JSON reader: nesting, escapes, malformed input.
- `compareVersions`: `1.10 > 1.9`, `1.0 == 1`, `2.0b1` against `2.0`.
- `parseBrewOutdated`: formulae, casks, pinned, empty.
- `parsePortOutdated`, `parseItunesLookup`, `parseAppcast` (channel
  items skipped, attribute and element forms).
- `checkUpdates` with a fake `RunFn`: tools missing, cask/Sparkle
  overlap, http feed skipped, cancel between sources.
- `upgradeBrew`: argv contains `--cask` for casks and the env variables.
