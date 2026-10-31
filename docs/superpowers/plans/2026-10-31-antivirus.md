# Antivirus Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An on-demand malware scan (XProtect.plist signatures, persistence and quarantine heuristics) as a core API, a `malware` CLI subcommand and an "Antivirus" sidebar tool.

**Architecture:** Pure C++ matching and scan logic in `maccleaner_core` (`malware.hpp/.cpp`). macOS APIs (Security, CommonCrypto, CoreFoundation, xattr) sit behind an injected `MalwarePlatform` struct in `src/platform/malware_mac.mm`. The GUI wraps the core in `MCMalwareModel` and `MCAntivirusViewController`.

**Tech Stack:** C++20, ObjC++ (AppKit), Security.framework, CommonCrypto, CMake + Ninja.

**Spec:** `docs/superpowers/specs/2026-10-31-antivirus-design.md`

## Global Constraints

- No dependency beyond system frameworks.
- Report-only by default; remediation is Trash only, through `safety::isSafeToDelete()` and `trash::moveToTrash()`.
- Never report or trash Apple-signed files or anything under `/System`.
- Default roots: `~/Downloads`, `~/Desktop`, `~/Applications`, `/Applications`.
- Persistence dirs: `~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons`.
- Content-scan size cap: 64 MB (`kMaxScanBytes = 64ull << 20`).
- File walk: `walkFiles` only (EPERM-tolerant).
- Commits: Conventional Commits, no `Co-Authored-By` trailer.
- Build: `cmake --build build` (Ninja). Check build output before `ctest`.

## Review Focus

1. A rule with an empty hex pattern must never match (else every file is "Detected"). Test in Task 1.
2. An XProtect.plist entry with an unknown `MatchType` or missing `Pattern` must be dropped, not turned into an always-true rule. Test in Task 3 (parser drops it).
3. A LaunchAgent plist whose target is relative or empty gives Info, not a crash or a signature lookup on `""`. Test in Task 2.
4. A file that cannot be opened (EACCES) during the content scan is skipped, the walk continues. Test in Task 2 (chmod 000 file).
5. Cancel during a scan of `/Applications` returns promptly with partial findings. Test in Task 2 (pre-set `cancelled`).

---

### Task 1: Signature model and matcher

**Files:**
- Create: `include/maccleaner/malware.hpp`, `src/malware.cpp`
- Modify: `CMakeLists.txt` (add `src/malware.cpp` to `MACCLEANER_CORE_SOURCES`)
- Test: `tests/maccleaner_tests.cpp`

**Interfaces (namespace `maccleaner::malware`):**
- Produces:
  ```cpp
  struct SignatureMatch {
      enum class Op { Bytes, Sha1, Any, All } op = Op::Bytes;
      std::vector<std::uint8_t> bytes;      // Bytes: pattern; Sha1: 20-byte digest
      std::vector<SignatureMatch> children; // Any / All
  };
  struct Signature { std::string name; std::optional<std::uint64_t> size; SignatureMatch match; };
  using Sha1Digest = std::array<std::uint8_t, 20>;
  bool matchSignature(const Signature& sig, std::span<const std::uint8_t> content, const Sha1Digest& sha1);
  Signature eicarSignature();                 // name "EICAR-Test-File"
  std::optional<std::vector<std::uint8_t>> parseHex(std::string_view hex); // nullopt on odd length / bad digit
  ```

- [ ] **Step 1: Write failing tests** `testMalwareMatchBytes`, `testMalwareMatchSha1`, `testMalwareMatchAnyAll`, `testMalwareSizeFilter`, `testMalwareEmptyPatternNeverMatches`, `testMalwareParseHex`, `testMalwareEicar`. Assertions: pattern `3A62696E3A` matches content containing `:bin:` and not `:bix:`; Any of {miss, hit} true, All of {miss, hit} false; `size = 5` rejects a 6-byte content; an empty `Bytes` pattern and an empty `All`/`Any` return false; `parseHex("3a6C")` gives `{0x3a,0x6c}`, `parseHex("abc")` and `parseHex("zz")` give nullopt; the 68-byte EICAR string matches `eicarSignature()`. Register each in `main()`.
- [ ] **Step 2:** `cmake --build build 2>&1 | grep -E 'error|warning' ; ctest --test-dir build --output-on-failure` → build fails (missing header).
- [ ] **Step 3:** Implement. `Bytes` uses `std::search`. `Sha1` compares to the passed digest. The EICAR string must be assembled at runtime from two halves so the source file itself does not match other scanners.
- [ ] **Step 4:** Build, run ctest → all pass.
- [ ] **Step 5:** `git commit -m "feat(malware): add signature model and matcher"`

### Task 2: scanMalware with injected platform

**Files:**
- Modify: `include/maccleaner/malware.hpp`, `src/malware.cpp`
- Test: `tests/maccleaner_tests.cpp`

**Interfaces:**
- Consumes: Task 1 types; `walkFiles` from `walk.hpp`.
- Produces:
  ```cpp
  enum class Severity { Detected, Suspicious, Info };
  enum class FindingKind { Signature, Persistence, Quarantine };
  enum class SigningStatus { Apple, DeveloperSigned, AdHoc, Unsigned, Unknown };
  struct Finding { std::filesystem::path path; Severity severity; FindingKind kind; std::string reason; };
  struct MalwarePlatform {
      std::function<SigningStatus(const std::filesystem::path&)> signingStatus;
      std::function<bool(const std::filesystem::path&)> hasQuarantine;
      std::function<Sha1Digest(std::span<const std::uint8_t>)> sha1;
      // nullopt = unreadable plist; "" = no Program/ProgramArguments
      std::function<std::optional<std::string>(const std::filesystem::path&)> readLaunchTarget;
      std::function<bool(const std::filesystem::path&)> pathExists;
  };
  struct MalwareReport { std::vector<Finding> findings; std::uint64_t filesScanned = 0; std::uint64_t skippedLarge = 0; };
  inline constexpr std::uint64_t kMaxScanBytes = 64ull << 20;
  std::vector<std::filesystem::path> defaultScanRoots();      // from HOME
  std::vector<std::filesystem::path> persistenceDirs();       // from HOME
  MalwareReport scanMalware(const std::vector<std::filesystem::path>& roots,
                            const std::vector<std::filesystem::path>& launchDirs,
                            const std::vector<Signature>& rules,
                            const MalwarePlatform& platform,
                            const std::atomic<bool>* cancelled = nullptr,
                            const std::function<void(std::uint64_t scanned, const std::filesystem::path& dir)>& progress = {});
  ```

Rules for `scanMalware` (from the spec):
- Skip any path under `/System`. Mach-O (first 4 bytes are one of the six magics in `XProtect.yara`'s `Macho` rule) gets `signingStatus`; Apple → skip the file entirely.
- Signature: first matching rule gives `Detected`, reason = rule name. Compute SHA-1 only if some rule needs it (precompute a `bool` once).
- Quarantine: Mach-O + `hasQuarantine` + (`AdHoc` or `Unsigned`) → `Suspicious`, kind `Quarantine`.
- Persistence: each `*.plist` directly in `launchDirs`: nullopt → Info "unreadable plist"; empty or relative target → Info "no program path"; `!pathExists` → Info "target missing"; target under `/tmp`, `/private/tmp`, `/Users/Shared` or with a path part starting with `.` → Suspicious; `signingStatus` `AdHoc`/`Unsigned` → Suspicious; else no finding.
- Unopenable file → skipped silently.

- [ ] **Step 1: Write failing tests** with a fake platform (lambdas) and a temp dir: `testScanMalwareFindsEicar` (Detected, `filesScanned >= 1`), `testScanMalwareSkipsAppleSigned` (EICAR content behind a Mach-O magic + fake Apple → no finding), `testScanMalwareQuarantinedAdhoc` (Mach-O + quarantine + AdHoc → Suspicious; same without quarantine → none; Developer → none), `testScanMalwarePersistence` (four plists via fake `readLaunchTarget`: unsigned target → Suspicious, `/tmp/x` → Suspicious, missing → Info, `""` → Info, Developer-signed → none), `testScanMalwareSkipsUnreadable` (chmod 000 file next to EICAR → EICAR still found), `testScanMalwareCancelled` (`cancelled = true` → returns, no crash, findings size ≤ 1).
- [ ] **Step 2:** Build → fails on missing symbols.
- [ ] **Step 3:** Implement as above.
- [ ] **Step 4:** Build, ctest → pass.
- [ ] **Step 5:** `git commit -m "feat(malware): scan files and launchd persistence"`

### Task 3: macOS platform and XProtect rule loader

**Files:**
- Create: `src/platform/malware_mac.mm`, `src/platform/malware_fallback.cpp`
- Modify: `CMakeLists.txt` (APPLE list: add `malware_mac.mm` with `-fobjc-arc`, link `Security` framework; else fallback), `include/maccleaner/malware.hpp`
- Test: `tests/maccleaner_tests.cpp`

**Interfaces:**
- Produces:
  ```cpp
  MalwarePlatform defaultMalwarePlatform();
  // XProtect rules (if present) + eicarSignature(). Pass a path for tests.
  std::vector<Signature> loadXProtectRules(const std::filesystem::path& plist =
      "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Resources/XProtect.plist");
  ```
- Signing: `SecStaticCodeCreateWithPath` + `SecStaticCodeCheckValidity(code, kSecCSDefaultFlags, req)` where `req` = `SecRequirementCreateWithString("anchor apple")` → Apple. Else validity with null requirement OK: read `SecCodeCopySigningInformation` `kSecCodeInfoFlags`; `kSecCodeSignatureAdhoc` → AdHoc, else DeveloperSigned. `errSecCSUnsigned` → Unsigned. Other errors → Unknown.
- Plist parser: `Description` → name; `Matches` → All of children; `MatchType` `Match` with `Pattern` → Bytes, with `Identity` (CFData) → Sha1; `MatchAny`/`MatchAll` with nested `Matches` → Any/All; `MatchFile.NSURLFileSizeKey` → `size`. Drop the whole entry on any unknown shape.

- [ ] **Step 1: Write failing tests** (guard with `#if defined(__APPLE__)`): `testSigningStatusReal` (`/bin/ls` → Apple; a temp copy of a test-compiled binary is out of scope here, Task 6 covers it), `testLoadXProtectRulesFromFixture` (write a small XML plist to a temp file: one valid `Match`+`Pattern` entry, one `MatchAny` entry, one entry with `MatchType` `Bogus` → expect 2 rules + EICAR = 3), `testLoadXProtectRulesMissingFile` (→ only EICAR).
- [ ] **Step 2:** Build → fails.
- [ ] **Step 3:** Implement. Fallback returns `{eicarSignature()}` and `Unknown`/false/stub SHA-1 (zeros, documented as a shortcut).
- [ ] **Step 4:** Build, ctest → pass. Also print `loadXProtectRules().size()` once in a scratch run: expect 95 on this Mac (94 + EICAR); fewer means entries were dropped — check why before going on.
- [ ] **Step 5:** `git commit -m "feat(malware): read XProtect rules and code signatures"`

### Task 4: CLI `malware` subcommand

**Files:**
- Modify: `include/maccleaner/cli.hpp` (`Command::Malware`, `std::vector<std::string> paths;` in `CliOptions`), `src/cli.cpp` (parse `malware`, repeatable `--path=P`, `--trash`, `--yes`; help text), `src/main.cpp` (run + print + optional trash)
- Test: `tests/maccleaner_tests.cpp`

- [ ] **Step 1: Write failing test** `testCliParsesMalware`: `malware --path=/a --path=/b --trash --yes` → `Command::Malware`, `paths == {"/a","/b"}`, `apply` true, `yes` true; plain `malware` → empty paths, `apply` false.
- [ ] **Step 2:** Build → fails.
- [ ] **Step 3:** Implement. Map `--trash` onto existing `apply`. Output: one line per finding `[DETECTED] path — reason`, grouped Detected, Suspicious, Info, then `N files scanned, M skipped (>64 MB)`. With `--trash`: list Detected+Suspicious paths, prompt via the existing `y/N` helper unless `--yes`, refuse a path when `!safety::isSafeToDelete()` or its signing status is Apple, print the reason.
- [ ] **Step 4:** Build, ctest → pass. `build/mac_cleaner malware --path=$SCRATCH` on a dir with an EICAR file prints one DETECTED line.
- [ ] **Step 5:** `git commit -m "feat(cli): add malware subcommand"`

### Task 5: GUI tool

**Files:**
- Create: `src/gui/MCMalwareModel.h/.mm`, `src/gui/MCAntivirusViewController.h/.mm`
- Modify: `src/gui/MCTheme.h/.mm` (`MCToolAntivirus`, red→orange gradient), `src/gui/MCMainWindowController.mm` (one `MCToolEntry`: "Antivirus", `shield.lefthalf.filled`, and the VC factory switch), `CMakeLists.txt` (GUI sources)

**Interfaces:**
- `MCMalwareModel`: `- (void)scanRoots:(nullable NSArray<NSURL *> *)roots` (nil = defaults), `- (void)cancel`, `- (void)trashFindings:(NSArray<NSNumber *> *)indexes`, properties `findings` (an ObjC value class or index access), callbacks `onProgress`, `onFinished`, `onTrashed` on main. Rules loaded once on the queue.
- VC follows `MCOrganizerViewController`: `MCHeroView` idle ("Scan", "Choose Folder…"), scanning status with Cancel, then `MCToolBanner` (value = findings count or "No threats found", caption = files scanned) and an `NSTableView` (Severity, Kind, Path, Reason; multi-select) with "Move to Trash" and "Reveal in Finder". Persistence rows show the note "Stops at next login".

- [ ] **Step 1:** Implement model, VC, theme colour, sidebar row.
- [ ] **Step 2:** Build with no warnings; ctest still passes.
- [ ] **Step 3:** `open build/MacCleaner.app`, select Antivirus, `screencapture -x` → hero shows in the new colour.
- [ ] **Step 4:** `git commit -m "feat(gui): add Antivirus tool"`

### Task 6: Real-machine check and README

**Files:**
- Modify: `README.md` (feature list, CLI usage, safety model, the non-goals from the spec, the XProtect.plist note)

- [ ] **Step 1:** Create samples (no real malware):
  1. EICAR file in `~/Downloads/mc-eicar-test.txt` (written by `printf` from two halves).
  2. `cc -o ~/Downloads/mc-adhoc-test` a tiny C program; `xattr -w com.apple.quarantine "0081;00000000;Test;" ~/Downloads/mc-adhoc-test`.
  3. `~/Library/LaunchAgents/com.maccleaner.test.plist` with `ProgramArguments[0]` = that binary. Do not `launchctl load` it.
- [ ] **Step 2:** `build/mac_cleaner malware` → exactly these three among findings (EICAR Detected, binary Suspicious Quarantine, plist Suspicious Persistence). Record runtime and any other findings; explain each in the report.
- [ ] **Step 3:** GUI scan → same three; select them, Move to Trash; confirm they are in `~/.Trash`. Do not empty the Trash; tell the user the three test items are there.
- [ ] **Step 4:** Update README; `git commit -m "docs: document the Antivirus tool"`
