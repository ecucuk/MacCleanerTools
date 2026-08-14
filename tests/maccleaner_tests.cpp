// Minimal, dependency-free test runner: no GoogleTest/Catch2 fetch required
// to build & run the suite. Each CHECK failure is logged and counted; main()
// returns the failure count as the process exit code (0 == all green), which
// is all CTest needs.

#include "maccleaner/bigfiles.hpp"
#include "maccleaner/cleaner.hpp"
#include "maccleaner/processes.hpp"
#include "maccleaner/cli.hpp"
#include "maccleaner/format.hpp"
#include "maccleaner/safety.hpp"
#include "maccleaner/scanner.hpp"

#include <algorithm>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

namespace {

int g_failures = 0;

#define CHECK(cond)                                                                    \
    do {                                                                                \
        if (!(cond)) {                                                                  \
            std::cerr << "FAIL " << __FILE__ << ":" << __LINE__ << "  " << #cond << "\n"; \
            ++g_failures;                                                               \
        }                                                                               \
    } while (0)

// Prints both sides on failure -- with plain CHECK, a size mismatch just says
// "total == 110" without revealing what it actually was.
#define CHECK_EQ(actual, expected)                                                       \
    do {                                                                                 \
        const auto actualValue = (actual);                                               \
        const auto expectedValue = (expected);                                           \
        if (!(actualValue == expectedValue)) {                                           \
            std::cerr << "FAIL " << __FILE__ << ":" << __LINE__ << "  " << #actual       \
                       << "\n  expected: " << expectedValue                               \
                       << "\n  actual:   " << actualValue << "\n";                        \
            ++g_failures;                                                                \
        }                                                                                \
    } while (0)

namespace fs = std::filesystem;
using maccleaner::humanReadableBytes;
using maccleaner::safety::AllowedRoots;
using maccleaner::safety::isSafeToDelete;

// Writes a file of exactly `bytes` length so size assertions can be exact
// rather than approximate.
void writeFileOfSize(const fs::path& path, std::size_t bytes) {
    fs::create_directories(path.parent_path());
    std::ofstream out(path, std::ios::binary);
    out << std::string(bytes, 'x');
}

void testHumanReadableBytes() {
    CHECK(humanReadableBytes(0) == "0 B");
    CHECK(humanReadableBytes(999) == "999 B");
    CHECK(humanReadableBytes(1024) == "1.0 KB");
    CHECK(humanReadableBytes(1536) == "1.5 KB");
    CHECK(humanReadableBytes(1024ull * 1024) == "1.0 MB");
    CHECK(humanReadableBytes(1024ull * 1024 * 1024) == "1.0 GB");
}

// Sets up a scratch directory tree per test so failures can't leave stale
// state for the next run:
//   $HOME/.mc_test_XXXX/
//     root/            <- the single AllowedRoots entry
//       child_dir/
//       child_file.txt
//       linked_out -> ../outside/
//     outside/         <- sibling of root, never allowlisted
//
// Deliberately anchored under $HOME rather than the system temp directory:
// on macOS, fs::temp_directory_path() resolves under /private/var/folders/...,
// and /private is (correctly) in the hard denylist -- real cleanup roots are
// always under $HOME, so the test fixture should be too.
class ScratchTree {
public:
    ScratchTree() {
        const char* home = std::getenv("HOME");
        base_ = fs::path(home != nullptr ? home : "/tmp") /
                (".mc_test_" + std::to_string(::getpid()) + "_" + std::to_string(counter_++));
        root_ = base_ / "root";
        outside_ = base_ / "outside";
        fs::create_directories(root_ / "child_dir");
        fs::create_directories(outside_);
        std::ofstream(root_ / "child_file.txt") << "data";
        std::ofstream(outside_ / "secret.txt") << "data";
        std::error_code ec;
        fs::create_directory_symlink(outside_, root_ / "linked_out", ec);
    }

    ~ScratchTree() {
        std::error_code ec;
        fs::remove_all(base_, ec);
    }

    const fs::path& root() const { return root_; }
    const fs::path& outside() const { return outside_; }

private:
    static inline int counter_ = 0;
    fs::path base_;
    fs::path root_;
    fs::path outside_;
};

void testSafetyAcceptsDirectChildOfAllowedRoot() {
    ScratchTree tree;
    AllowedRoots allowed;
    allowed.add(tree.root());

    std::string reason;
    CHECK(isSafeToDelete(tree.root() / "child_dir", allowed, &reason));
    CHECK(isSafeToDelete(tree.root() / "child_file.txt", allowed, &reason));
}

void testSafetyRejectsPathOutsideAllowedRoot() {
    ScratchTree tree;
    AllowedRoots allowed;
    allowed.add(tree.root());

    std::string reason;
    CHECK(!isSafeToDelete(tree.outside(), allowed, &reason));
    CHECK(!reason.empty());
}

void testSafetyRejectsSymlink() {
    ScratchTree tree;
    AllowedRoots allowed;
    allowed.add(tree.root());

    std::string reason;
    CHECK(!isSafeToDelete(tree.root() / "linked_out", allowed, &reason));
}

void testSafetyRejectsRootItself() {
    // Only strict descendants of an allowed root are deletable, never the
    // root itself -- categories only ever offer children for deletion, and
    // this is the invariant that guarantees it even if a caller misuses the API.
    ScratchTree tree;
    AllowedRoots allowed;
    allowed.add(tree.root());

    std::string reason;
    CHECK(!isSafeToDelete(tree.root(), allowed, &reason));
}

void testSafetyRejectsNonexistentPath() {
    ScratchTree tree;
    AllowedRoots allowed;
    allowed.add(tree.root());

    std::string reason;
    CHECK(!isSafeToDelete(tree.root() / "does_not_exist", allowed, &reason));
}

// --- scanner ------------------------------------------------------------

using maccleaner::Category;
using maccleaner::directorySizeBytes;
using maccleaner::FileEntry;
using maccleaner::resolveExclusions;
using maccleaner::ScanResult;
using maccleaner::ScanTarget;
using maccleaner::scanTarget;

// A tree with known, exact byte sizes:
//   base/
//     top/
//       nested/          <- stands in for a category root nested in another
//         big.bin        1000 B
//       plain/
//         small.bin      10 B
//       loose.bin        5 B
class SizedTree {
public:
    SizedTree() {
        const char* home = std::getenv("HOME");
        base_ = fs::path(home != nullptr ? home : "/tmp") /
                (".mc_sized_" + std::to_string(::getpid()) + "_" + std::to_string(counter_++));
        top_ = base_ / "top";
        writeFileOfSize(top_ / "nested" / "big.bin", 1000);
        writeFileOfSize(top_ / "plain" / "small.bin", 10);
        writeFileOfSize(top_ / "loose.bin", 5);
    }

    ~SizedTree() {
        std::error_code ec;
        fs::remove_all(base_, ec);
    }

    const fs::path& top() const { return top_; }
    fs::path nested() const { return top_ / "nested"; }

private:
    static inline int counter_ = 0;
    fs::path base_;
    fs::path top_;
};

void testDirectorySizeSumsRecursively() {
    SizedTree tree;
    CHECK_EQ(directorySizeBytes(tree.top()), 1015u);
}

void testDirectorySizeHonoursExclusions() {
    SizedTree tree;
    // The nested subtree belongs to another category, so its 1000 bytes must
    // not be counted here -- this is the double-counting bug in the grand total.
    CHECK_EQ(directorySizeBytes(tree.top(), {tree.nested()}), 15u);
}

void testDirectorySizeDoesNotFollowDirectorySymlink() {
    // fs::file_size() fails on a symlink-to-directory and returns
    // uintmax_t(-1); accumulating that unchecked wraps the unsigned total.
    // The size here must stay small and sane, and must not include the 1000
    // bytes behind the link.
    SizedTree tree;
    std::error_code ec;
    fs::create_directory_symlink(tree.nested(), tree.top() / "plain" / "link_to_nested", ec);
    CHECK(!ec);

    const std::uintmax_t total = directorySizeBytes(tree.top());
    CHECK(total >= 1015u);
    CHECK(total < 2000u); // i.e. neither wrapped nor followed into `nested`
}

void testDirectorySizeHandlesBrokenSymlink() {
    // The pathological case of the same bug: with a total still at 0, adding
    // uintmax_t(-1) would report ~16 EB of reclaimable space.
    SizedTree tree;
    const fs::path dir = tree.top() / "onlylink";
    fs::create_directories(dir);
    std::error_code ec;
    fs::create_symlink(dir / "no_such_target", dir / "dangling", ec);
    CHECK(!ec);

    CHECK(directorySizeBytes(dir) < 4096u);
}

void testScanTargetExcludesNestedCategoryRoots() {
    SizedTree tree;
    ScanTarget target{Category::UserCaches, "test", tree.top(), {tree.nested()}};

    const ScanResult result = scanTarget(target);
    CHECK(result.rootExisted);

    const bool listsNested = std::any_of(result.entries.begin(), result.entries.end(),
                                          [&](const FileEntry& e) { return e.path == tree.nested(); });
    CHECK(!listsNested); // cleaning "caches" must not delete the nested category

    CHECK_EQ(result.entries.size(), 2u); // plain/ and loose.bin
    CHECK_EQ(result.totalSizeBytes, 15u);
}

void testScanTargetSortsBySizeDescending() {
    SizedTree tree;
    ScanTarget target{Category::UserCaches, "test", tree.top(), {}};

    const ScanResult result = scanTarget(target);
    CHECK_EQ(result.entries.size(), 3u);
    for (std::size_t i = 1; i < result.entries.size(); ++i) {
        CHECK(result.entries[i - 1].sizeBytes >= result.entries[i].sizeBytes);
    }
    CHECK_EQ(result.entries.front().sizeBytes, 1000u); // nested/ is the biggest
}

void testScanTargetKeepsMode000Directories() {
    // The SIP/TCC filter must key on errno == EPERM, not "opendir failed".
    // A chmod-000 directory the user owns fails the probe with EACCES and is
    // still perfectly trashable (rename only needs write on the parent), so
    // it has to stay in the scan. A real TCC EPERM can't be manufactured in a
    // test -- that half of the discrimination was verified live against
    // ~/Library/Caches/com.apple.homed and friends.
    SizedTree tree;
    const fs::path locked = tree.top() / "locked_dir";
    fs::create_directories(locked);
    ::chmod(locked.c_str(), 0000);

    ScanTarget target{Category::UserCaches, "test", tree.top(), {}};
    const ScanResult result = scanTarget(target);

    ::chmod(locked.c_str(), 0700); // restore before ~SizedTree's remove_all

    const bool listsLocked = std::any_of(result.entries.begin(), result.entries.end(),
                                          [&](const FileEntry& e) { return e.path == locked; });
    CHECK(listsLocked);
}

void testScanTargetOnMissingRoot() {
    SizedTree tree;
    ScanTarget target{Category::UserCaches, "test", tree.top() / "does_not_exist", {}};

    const ScanResult result = scanTarget(target);
    CHECK(!result.rootExisted);
    CHECK(result.entries.empty());
    CHECK_EQ(result.totalSizeBytes, 0u);
}

void testResolveExclusionsFindsNesting() {
    std::vector<ScanTarget> targets{
        {Category::UserCaches, "caches", "/home/u/Library/Caches", {}},
        {Category::HomebrewCache, "brew", "/home/u/Library/Caches/Homebrew", {}},
        {Category::NpmCache, "npm", "/home/u/.npm/_cacache", {}},
    };
    resolveExclusions(targets);

    CHECK_EQ(targets[0].exclusions.size(), 1u);
    CHECK(targets[0].exclusions.front() == fs::path("/home/u/Library/Caches/Homebrew"));
    CHECK(targets[1].exclusions.empty()); // nothing nests under Homebrew
    CHECK(targets[2].exclusions.empty());
}

void testResolveExclusionsIgnoresSiblingPrefixes() {
    // "/a/Caches2" must not count as nested inside "/a/Caches" just because
    // the string is a prefix.
    std::vector<ScanTarget> targets{
        {Category::UserCaches, "a", "/a/Caches", {}},
        {Category::YarnCache, "b", "/a/Caches2", {}},
    };
    resolveExclusions(targets);

    CHECK(targets[0].exclusions.empty());
    CHECK(targets[1].exclusions.empty());
}

void testDefaultTargetsWireUpKnownNesting() {
    const std::vector<ScanTarget> targets = maccleaner::defaultTargets("/home/u");

    const auto findByCategory = [&](Category category) {
        return std::find_if(targets.begin(), targets.end(),
                             [&](const ScanTarget& t) { return t.category == category; });
    };

    const auto caches = findByCategory(Category::UserCaches);
    CHECK(caches != targets.end());
    const auto& cacheExclusions = caches->exclusions;
    const auto excludes = [&](const fs::path& p) {
        return std::find(cacheExclusions.begin(), cacheExclusions.end(), p) != cacheExclusions.end();
    };
    CHECK(excludes("/home/u/Library/Caches/Homebrew"));
    CHECK(excludes("/home/u/Library/Caches/Yarn"));
    CHECK(excludes("/home/u/Library/Caches/pip"));

    const auto logs = findByCategory(Category::UserLogs);
    CHECK(logs != targets.end());
    CHECK(std::find(logs->exclusions.begin(), logs->exclusions.end(),
                     fs::path("/home/u/Library/Logs/DiagnosticReports")) != logs->exclusions.end());
}

// --- cleaner ------------------------------------------------------------

using maccleaner::clean;
using maccleaner::CleanOptions;
using maccleaner::CleanReport;
using maccleaner::DeleteMode;
using maccleaner::requiresPermanentDelete;

ScanResult scanForCleaning(const ScratchTree& tree) {
    ScanTarget target{Category::UserCaches, "test", tree.root(), {}};
    return scanTarget(target);
}

void testCleanDryRunTouchesNothing() {
    ScratchTree tree;
    AllowedRoots allowed;
    allowed.add(tree.root());

    CleanOptions options; // dryRun defaults to true
    const CleanReport report = clean(scanForCleaning(tree), allowed, options);

    CHECK(fs::exists(tree.root() / "child_dir"));
    CHECK(fs::exists(tree.root() / "child_file.txt"));
    CHECK_EQ(report.bytesFreed, 0u);
    CHECK(report.bytesWouldFree > 0u);
}

void testCleanSkipsUnsafeEntriesWithReason() {
    ScratchTree tree;
    AllowedRoots allowed;
    allowed.add(tree.root());

    const CleanReport report = clean(scanForCleaning(tree), allowed, CleanOptions{});

    // The scan surfaces `linked_out`, but the safety layer refuses symlinks.
    const auto skipped = std::find_if(report.outcomes.begin(), report.outcomes.end(),
                                       [](const auto& o) { return o.skipped; });
    CHECK(skipped != report.outcomes.end());
    if (skipped != report.outcomes.end()) {
        CHECK(skipped->path.filename() == "linked_out");
        CHECK(!skipped->message.empty());
    }
    CHECK(fs::is_symlink(tree.root() / "linked_out")); // and it survived
}

void testCleanPermanentRemovesEntries() {
    ScratchTree tree;
    AllowedRoots allowed;
    allowed.add(tree.root());

    CleanOptions options;
    options.dryRun = false;
    options.mode = DeleteMode::Permanent; // never DeleteMode::Trash in tests:
                                           // that would move fixtures into the
                                           // real user Trash.
    const CleanReport report = clean(scanForCleaning(tree), allowed, options);

    CHECK(!fs::exists(tree.root() / "child_dir"));
    CHECK(!fs::exists(tree.root() / "child_file.txt"));
    CHECK(report.bytesFreed > 0u);
    CHECK(fs::exists(tree.outside() / "secret.txt")); // never followed the symlink
}

void testTrashCategoryForcesPermanentDelete() {
    // Moving an item that is already in ~/.Trash to the Trash reclaims nothing,
    // so the Trash category must upgrade the mode regardless of the request.
    CHECK(requiresPermanentDelete(Category::Trash));
    CHECK(!requiresPermanentDelete(Category::UserCaches));
    CHECK(!requiresPermanentDelete(Category::XcodeDerivedData));
}

// --- CLI ----------------------------------------------------------------

using maccleaner::CliOptions;
using maccleaner::CliParseError;
using maccleaner::Command;
using maccleaner::parseArgs;

// parseArgs takes char** (argv) and only reads it, so const_cast off literals
// is safe here and keeps the call sites readable.
std::optional<CliOptions> parse(std::vector<const char*> args, CliParseError& error) {
    std::vector<char*> argv;
    argv.reserve(args.size());
    for (const char* arg : args) {
        argv.push_back(const_cast<char*>(arg));
    }
    return parseArgs(static_cast<int>(argv.size()), argv.data(), error);
}

// --- bigfiles -----------------------------------------------------------

using maccleaner::BigFile;
using maccleaner::BigFileScanOptions;
using maccleaner::findBigFiles;
using maccleaner::parseSizeSpec;

void testBigFilesFindsAndSortsAboveThreshold() {
    SizedTree tree;
    // SizedTree gives: nested/big.bin (1000), plain/a.bin (10), loose.bin (5).
    std::ofstream(tree.top() / "medium.bin") << std::string(100, 'x');

    BigFileScanOptions options;
    options.root = tree.top();
    options.minSizeBytes = 50;

    const std::vector<BigFile> files = findBigFiles(options);
    CHECK_EQ(files.size(), 2u); // big.bin (1000) and medium.bin (100)
    CHECK_EQ(files[0].sizeBytes, 1000u);
    CHECK_EQ(files[1].sizeBytes, 100u);
    CHECK(files[0].path.filename() == "big.bin");
}

void testBigFilesHonoursTopCap() {
    SizedTree tree;

    BigFileScanOptions options;
    options.root = tree.top();
    options.minSizeBytes = 1;
    options.maxResults = 2;

    const std::vector<BigFile> files = findBigFiles(options);
    CHECK_EQ(files.size(), 2u); // the two biggest of the three
    CHECK_EQ(files[0].sizeBytes, 1000u);
    CHECK_EQ(files[1].sizeBytes, 10u);
}

void testBigFilesIgnoresSymlinks() {
    SizedTree tree;
    std::error_code ec;
    // A file symlink to the biggest file: must not be reported (double count),
    // and a directory symlink loop must not hang the walk.
    fs::create_symlink(tree.top() / "nested" / "big.bin", tree.top() / "big_link", ec);
    CHECK(!ec);
    fs::create_directory_symlink(tree.top(), tree.top() / "self_loop", ec);
    CHECK(!ec);

    BigFileScanOptions options;
    options.root = tree.top();
    options.minSizeBytes = 500;

    const std::vector<BigFile> files = findBigFiles(options);
    CHECK_EQ(files.size(), 1u); // just the real big.bin, once
}

void testBigFilesStreamsResults() {
    SizedTree tree;

    BigFileScanOptions options;
    options.root = tree.top();
    options.minSizeBytes = 1;

    // Every insertion into the running top list must be observable, and the
    // last streamed snapshot must equal the final return value -- that is
    // the contract the GUI's live table depends on.
    std::size_t calls = 0;
    std::vector<BigFile> lastSnapshot;
    const std::vector<BigFile> files = findBigFiles(
        options, nullptr, {}, [&](const std::vector<BigFile>& current) {
            ++calls;
            lastSnapshot = current;
        });

    CHECK_EQ(calls, 3u); // one per qualifying file
    CHECK_EQ(lastSnapshot.size(), files.size());
    for (std::size_t i = 0; i < files.size(); ++i) {
        CHECK(lastSnapshot[i].path == files[i].path);
        CHECK_EQ(lastSnapshot[i].sizeBytes, files[i].sizeBytes);
    }
}

void testBigFilesCancellation() {
    SizedTree tree;

    BigFileScanOptions options;
    options.root = tree.top();
    options.minSizeBytes = 1;

    std::atomic<bool> cancelled{true}; // cancelled before it starts
    const std::vector<BigFile> files = findBigFiles(options, &cancelled);
    CHECK(files.empty());
}

void testParseSizeSpec() {
    std::uintmax_t bytes = 0;
    CHECK(parseSizeSpec("500M", bytes));
    CHECK_EQ(bytes, 500ull << 20);
    CHECK(parseSizeSpec("1.5G", bytes));
    CHECK_EQ(bytes, (3ull << 30) / 2);
    CHECK(parseSizeSpec("200K", bytes));
    CHECK_EQ(bytes, 200ull << 10);
    CHECK(parseSizeSpec("12345", bytes));
    CHECK_EQ(bytes, 12345u);
    CHECK(parseSizeSpec("2TB", bytes));
    CHECK_EQ(bytes, 2ull << 40);
    CHECK(parseSizeSpec("100mb", bytes));
    CHECK_EQ(bytes, 100ull << 20);

    CHECK(!parseSizeSpec("", bytes));
    CHECK(!parseSizeSpec("abc", bytes));
    CHECK(!parseSizeSpec("10X", bytes));
    CHECK(!parseSizeSpec("-5M", bytes));
    CHECK(!parseSizeSpec("10MBs", bytes));
}

void testCliParsesBigFiles() {
    CliParseError error;
    const char* argv[] = {"mac_cleaner", "bigfiles", "--under=/tmp", "--min=500M", "--top=25"};
    const auto options = parseArgs(5, const_cast<char**>(argv), error);
    CHECK(options.has_value());
    CHECK(options->command == Command::BigFiles);
    CHECK(options->under == "/tmp");
    CHECK_EQ(options->minSizeBytes, 500ull << 20);
    CHECK_EQ(options->top, 25u);
}

// --- processes ----------------------------------------------------------

using maccleaner::classifyProcess;
using maccleaner::diffProcessSamples;
using maccleaner::isSafeToKill;
using maccleaner::KillMode;
using maccleaner::killProcess;
using maccleaner::ProcessInfo;
using maccleaner::ProcessKind;
using maccleaner::ProcessSample;
using maccleaner::sampleProcesses;

void testClassifyProcess() {
    CHECK(classifyProcess("/Applications/Safari.app/Contents/MacOS/Safari") == ProcessKind::App);
    CHECK(classifyProcess("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder") ==
          ProcessKind::System);
    CHECK(classifyProcess("/usr/libexec/secd") == ProcessKind::System);
    CHECK(classifyProcess("/opt/homebrew/bin/node") == ProcessKind::Background);
    CHECK(classifyProcess("") == ProcessKind::Background);
}

void testDiffProcessSamplesComputesCpuPercent() {
    ProcessSample before;
    before.pid = 42;
    before.startTime = 1000;
    before.cpuTimeNs = 1'000'000'000; // 1s of CPU so far

    ProcessSample after = before;
    after.cpuTimeNs = 1'500'000'000; // +0.5s CPU ...

    const std::vector<ProcessInfo> infos =
        diffProcessSamples({before}, {after}, 1'000'000'000); // ... over 1s wall
    CHECK_EQ(infos.size(), 1u);
    CHECK(infos[0].cpuPercent > 49.9 && infos[0].cpuPercent < 50.1);
}

void testDiffProcessSamplesHandlesNewAndReusedPids() {
    ProcessSample fresh;
    fresh.pid = 7;
    fresh.startTime = 2000;
    fresh.cpuTimeNs = 500'000'000;

    // No baseline: 0%, not garbage.
    std::vector<ProcessInfo> infos = diffProcessSamples({}, {fresh}, 1'000'000'000);
    CHECK_EQ(infos.size(), 1u);
    CHECK_EQ(infos[0].cpuPercent, 0.0);

    // Same pid, different start time = pid reuse; must also get 0%, not a
    // bogus delta against the dead process's counters.
    ProcessSample old = fresh;
    old.startTime = 1000;
    old.cpuTimeNs = 9'000'000'000;
    infos = diffProcessSamples({old}, {fresh}, 1'000'000'000);
    CHECK_EQ(infos.size(), 1u);
    CHECK_EQ(infos[0].cpuPercent, 0.0);
}

#ifdef __APPLE__
void testSampleProcessesSeesOurselves() {
    const std::vector<ProcessSample> samples = sampleProcesses(::geteuid());
    const auto self = std::find_if(samples.begin(), samples.end(),
                                    [](const ProcessSample& s) { return s.pid == ::getpid(); });
    CHECK(self != samples.end());
    if (self != samples.end()) {
        CHECK(!self->name.empty());
        CHECK(self->memoryBytes > 0);
        CHECK(self->startTime > 0);
    }
}
#endif

void testIsSafeToKillRejectsProtectedTargets() {
    std::string reason;
    CHECK(!isSafeToKill(0, &reason));
    CHECK(!isSafeToKill(1, &reason));       // launchd: root-owned and pid<=1
    CHECK(!isSafeToKill(::getpid(), &reason)); // never ourselves
    CHECK(!reason.empty());
}

void testIsSafeToKillReportsForeignProcessesAccurately() {
    // A live root-owned process must be rejected as *someone else's*, not as
    // "no longer exists": proc_pidinfo fails for both cases, and this reason
    // string is what the UI shows the user in a tooltip.
    const pid_t child = ::fork();
    if (child == 0) {
        ::execlp("sleep", "sleep", "5", static_cast<char*>(nullptr));
        _exit(127);
    }
    CHECK(child > 0);

    // A pid that genuinely does not exist reports so. Reaping the child
    // first guarantees the pid is free (barring immediate reuse).
    std::string error;
    (void)killProcess(child, KillMode::Force, error);
    int status = 0;
    ::waitpid(child, &status, 0);

    std::string reason;
    CHECK(!isSafeToKill(child, &reason));
    CHECK(reason == "process no longer exists");

#ifdef __APPLE__
    // launchd (pid 1) is alive and root-owned; it must never be reported as
    // gone. pid<=1 short-circuits before the ownership branch, so use the
    // message to confirm it is the *system process* rule that fired.
    std::string launchdReason;
    CHECK(!isSafeToKill(1, &launchdReason));
    CHECK(launchdReason.find("no longer exists") == std::string::npos);
#endif
}

void testKillProcessTerminatesOwnChild() {
    // A real end-to-end kill against a process we own: spawn a sleeper,
    // gracefully terminate it, and confirm it died of SIGTERM.
    const pid_t child = ::fork();
    if (child == 0) {
        ::execlp("sleep", "sleep", "30", static_cast<char*>(nullptr));
        _exit(127); // exec failed
    }
    CHECK(child > 0);

    std::string reason;
    CHECK(isSafeToKill(child, &reason));

    std::string error;
    CHECK(killProcess(child, KillMode::Graceful, error));

    int status = 0;
    CHECK_EQ(::waitpid(child, &status, 0), child);
    CHECK(WIFSIGNALED(status));
    CHECK_EQ(WTERMSIG(status), SIGTERM);
}

void testCliDefaultsToScan() {
    CliParseError error;
    const auto options = parse({"mac_cleaner"}, error);
    CHECK(options.has_value());
    if (options) {
        CHECK(options->command == Command::Scan);
        CHECK(options->onlyCategories.empty());
        CHECK(!options->apply);
        CHECK(!options->permanent);
    }
}

void testCliParsesCleanFlags() {
    CliParseError error;
    const auto options = parse({"mac_cleaner", "clean", "--apply", "--permanent", "--yes"}, error);
    CHECK(options.has_value());
    if (options) {
        CHECK(options->command == Command::Clean);
        CHECK(options->apply);
        CHECK(options->permanent);
        CHECK(options->yes);
    }
}

void testCliParsesOnlyList() {
    CliParseError error;
    const auto options = parse({"mac_cleaner", "scan", "--only=caches,derived-data,npm"}, error);
    CHECK(options.has_value());
    if (options) {
        CHECK_EQ(options->onlyCategories.size(), 3u);
        CHECK(options->onlyCategories[0] == Category::UserCaches);
        CHECK(options->onlyCategories[1] == Category::XcodeDerivedData);
        CHECK(options->onlyCategories[2] == Category::NpmCache);
    }
}

void testCliRejectsUnknownCategory() {
    CliParseError error;
    const auto options = parse({"mac_cleaner", "scan", "--only=caches,nope"}, error);
    CHECK(!options.has_value());
    CHECK(!error.message.empty());
}

void testCliRejectsUnknownFlag() {
    CliParseError error;
    const auto options = parse({"mac_cleaner", "scan", "--force"}, error);
    CHECK(!options.has_value());
    CHECK(!error.message.empty());
}

void testCliRejectsPermanentWithoutApply() {
    // The guard that keeps --permanent from being a one-flag irreversible wipe.
    CliParseError error;
    const auto options = parse({"mac_cleaner", "clean", "--permanent"}, error);
    CHECK(!options.has_value());
    CHECK(error.message.find("--apply") != std::string::npos);
}

void testCliHelpShortCircuits() {
    CliParseError error;
    const auto options = parse({"mac_cleaner", "clean", "--help", "--bogus"}, error);
    CHECK(options.has_value());
    if (options) {
        CHECK(options->command == Command::Help);
    }
}

} // namespace

int main() {
    testHumanReadableBytes();

    testSafetyAcceptsDirectChildOfAllowedRoot();
    testSafetyRejectsPathOutsideAllowedRoot();
    testSafetyRejectsSymlink();
    testSafetyRejectsRootItself();
    testSafetyRejectsNonexistentPath();

    testDirectorySizeSumsRecursively();
    testDirectorySizeHonoursExclusions();
    testDirectorySizeDoesNotFollowDirectorySymlink();
    testDirectorySizeHandlesBrokenSymlink();
    testScanTargetExcludesNestedCategoryRoots();
    testScanTargetSortsBySizeDescending();
    testScanTargetKeepsMode000Directories();
    testScanTargetOnMissingRoot();
    testResolveExclusionsFindsNesting();
    testResolveExclusionsIgnoresSiblingPrefixes();
    testDefaultTargetsWireUpKnownNesting();

    testCleanDryRunTouchesNothing();
    testCleanSkipsUnsafeEntriesWithReason();
    testCleanPermanentRemovesEntries();
    testTrashCategoryForcesPermanentDelete();

    testBigFilesFindsAndSortsAboveThreshold();
    testBigFilesHonoursTopCap();
    testBigFilesIgnoresSymlinks();
    testBigFilesStreamsResults();
    testBigFilesCancellation();

    testClassifyProcess();
    testDiffProcessSamplesComputesCpuPercent();
    testDiffProcessSamplesHandlesNewAndReusedPids();
#ifdef __APPLE__
    testSampleProcessesSeesOurselves();
#endif
    testIsSafeToKillRejectsProtectedTargets();
    testIsSafeToKillReportsForeignProcessesAccurately();
    testKillProcessTerminatesOwnChild();
    testParseSizeSpec();

    testCliDefaultsToScan();
    testCliParsesCleanFlags();
    testCliParsesOnlyList();
    testCliRejectsUnknownCategory();
    testCliRejectsUnknownFlag();
    testCliRejectsPermanentWithoutApply();
    testCliHelpShortCircuits();
    testCliParsesBigFiles();

    if (g_failures == 0) {
        std::cout << "All tests passed.\n";
    } else {
        std::cerr << g_failures << " check(s) failed.\n";
    }
    return g_failures;
}
