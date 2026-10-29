// Minimal, dependency-free test runner: no GoogleTest/Catch2 fetch required
// to build & run the suite. Each CHECK failure is logged and counted; main()
// returns the failure count as the process exit code (0 == all green), which
// is all CTest needs.

#include "maccleaner/bigfiles.hpp"
#include "maccleaner/cleaner.hpp"
#include "maccleaner/optimizer.hpp"
#include "maccleaner/organizer.hpp"
#include "maccleaner/photos.hpp"
#include "maccleaner/processes.hpp"
#include "maccleaner/cli.hpp"
#include "maccleaner/format.hpp"
#include "maccleaner/safety.hpp"
#include "maccleaner/scanner.hpp"
#include "maccleaner/walk.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <fstream>
#include <iostream>
#include <map>
#include <numeric>
#include <random>
#include <string>
#include <thread>
#include <vector>
#include <signal.h>
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
namespace organizer = maccleaner::organizer;
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

void testSafetyRejectsPhotosLibrary() {
    ScratchTree tree;
    writeFileOfSize(tree.root() / "X.PhotosLibrary" / "originals" / "a.jpg", 1);
    writeFileOfSize(tree.root() / "a.jpg", 1);
    AllowedRoots allowed;
    allowed.add(tree.root());

    std::string reason;
    CHECK(!isSafeToDelete(tree.root() / "X.PhotosLibrary" / "originals" / "a.jpg", allowed, &reason));
    CHECK(reason.find("Photos library") != std::string::npos);
    CHECK(!isSafeToDelete(tree.root() / "X.PhotosLibrary", allowed, &reason));
    CHECK(isSafeToDelete(tree.root() / "a.jpg", allowed, &reason));
    CHECK(maccleaner::safety::isInsidePhotosLibrary("/u/Pictures/P.photoslibrary/originals/a.jpg"));
    CHECK(!maccleaner::safety::isInsidePhotosLibrary("/u/Pictures/photoslibrary-notes/a.jpg"));
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

void testSafetyRejectsVolumesAndMountPoints() {
    // Files inside an external volume may be deleted, but never /Volumes or a
    // mount point itself (the guard fires before the ownership check).
    AllowedRoots allowed;
    allowed.add("/");
    std::string reason;
    CHECK(!isSafeToDelete("/Volumes", allowed, &reason));
    CHECK(reason.find("mount point") != std::string::npos);
    std::error_code ec;
    for (fs::directory_iterator it("/Volumes", ec), end; !ec && it != end; it.increment(ec)) {
        if (!it->is_symlink()) {
            CHECK(!isSafeToDelete(it->path(), allowed, &reason));
            CHECK(reason.find("mount point") != std::string::npos);
        }
    }
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

void testCliParsesPhotos() {
    CliParseError error;
    const char* argv[] = {"mac_cleaner", "photos", "--under=/tmp", "--distance=4", "--blur=55.5"};
    const auto options = parseArgs(5, const_cast<char**>(argv), error);
    CHECK(options.has_value());
    CHECK(options->command == Command::Photos);
    CHECK(options->under == "/tmp");
    CHECK_EQ(options->distance, 4);
    CHECK_EQ(options->blurThreshold, 55.5);

    const char* defaults[] = {"mac_cleaner", "photos"};
    const auto plain = parseArgs(2, const_cast<char**>(defaults), error);
    CHECK_EQ(plain->distance, maccleaner::photos::kDefaultMaxDistance);
    CHECK_EQ(plain->blurThreshold, maccleaner::photos::kDefaultBlurThreshold);

    const char* bad[] = {"mac_cleaner", "photos", "--distance=x"};
    CHECK(!parseArgs(3, const_cast<char**>(bad), error).has_value());
    const char* tooFar[] = {"mac_cleaner", "photos", "--distance=65"};
    CHECK(!parseArgs(3, const_cast<char**>(tooFar), error).has_value());
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

// --- optimizer ----------------------------------------------------------

using maccleaner::appBundleDepth;
using maccleaner::findOptimizationCandidates;
using maccleaner::isRelaunchableAgent;
using maccleaner::isUserFacingApp;
using maccleaner::JunkKind;
using maccleaner::OptimizationCandidate;
using maccleaner::owningAppBundle;
using maccleaner::ProcessState;

// A live pid we own, so candidates survive the isSafeToKill() gate that
// findOptimizationCandidates applies last. Reused across the rule tests;
// reaped at the end of the run.
class LiveHelper {
public:
    LiveHelper() {
        pid_ = ::fork();
        if (pid_ == 0) {
            ::execlp("sleep", "sleep", "30", static_cast<char*>(nullptr));
            _exit(127);
        }
    }
    ~LiveHelper() {
        if (pid_ > 0) {
            ::kill(pid_, SIGKILL);
            int status = 0;
            ::waitpid(pid_, &status, 0);
        }
    }
    pid_t pid() const { return pid_; }

private:
    pid_t pid_ = -1;
};

maccleaner::ProcessSample makeSample(pid_t pid, const std::string& name, const std::string& path) {
    maccleaner::ProcessSample sample;
    sample.pid = pid;
    sample.name = name;
    sample.path = path;
    sample.memoryBytes = 100 << 20;
    sample.state = ProcessState::Running;
    // Recent by default, so the idle-helper rule (which needs a minimum
    // uptime) does not fire on samples written for the other rules.
    sample.startTime = std::time(nullptr);
    return sample;
}

// Most optimizer tests describe processes whose paths are synthetic, so the
// default world says every executable is still installed; the
// deleted-executable test overrides it. Without this every made-up path
// would look like a program that had been uninstalled.
const maccleaner::PathExistsFn kEverythingInstalled = [](const std::string&) { return true; };

// The optimizer works on diffed samples; most rules ignore cpuPercent, so
// tests state it only when the idle rule is what is under test.
maccleaner::ProcessInfo makeInfo(const maccleaner::ProcessSample& sample, double cpuPercent = 50.0) {
    maccleaner::ProcessInfo info;
    info.sample = sample;
    info.cpuPercent = cpuPercent;
    return info;
}

void testAppBundleDepthAndClassification() {
    CHECK_EQ(appBundleDepth("/Applications/Foo.app/Contents/MacOS/Foo"), 1);
    CHECK_EQ(appBundleDepth("/Applications/Foo.app/Contents/Frameworks/Foo Helper.app/Contents/MacOS/Foo Helper"), 2);
    CHECK_EQ(appBundleDepth("/usr/libexec/secd"), 0);
    // ".app" must be a whole path component: a directory named "notanapp"
    // or a file "data.appdata" must not register as a bundle, or a real
    // application could be misread as a nested helper and get killed.
    CHECK_EQ(appBundleDepth("/Users/x/notanapp/bin/tool"), 0);
    CHECK_EQ(appBundleDepth("/Users/x/data.appdata/thing"), 0);

    CHECK(isUserFacingApp("/Applications/Foo.app/Contents/MacOS/Foo"));
    CHECK(!isUserFacingApp("/Applications/Foo.app/Contents/Frameworks/Foo Helper.app/Contents/MacOS/Foo Helper"));
    CHECK(!isUserFacingApp("/usr/libexec/secd"));

    CHECK(owningAppBundle("/Applications/Foo.app/Contents/Frameworks/Foo Helper.app/Contents/MacOS/Foo Helper") ==
          "/Applications/Foo.app");
    CHECK(owningAppBundle("/Applications/Foo.app/Contents/MacOS/Foo").empty());

    CHECK(isRelaunchableAgent("GoogleSoftwareUpdateAgent"));
    CHECK(!isRelaunchableAgent("Google Chrome"));
}

void testOptimizerNeverTargetsUserFacingApps() {
    LiveHelper helper;
    // A running app, plus a zombie *app* (contrived) -- neither may be
    // proposed. This is the rule that keeps unsaved documents safe.
    auto app = makeSample(helper.pid(), "Foo", "/Applications/Foo.app/Contents/MacOS/Foo");
    auto zombieApp = makeSample(helper.pid(), "Bar", "/Applications/Bar.app/Contents/MacOS/Bar");
    zombieApp.state = ProcessState::Zombie;

    const auto candidates = findOptimizationCandidates({makeInfo(app), makeInfo(zombieApp)}, {}, kEverythingInstalled);
    CHECK(candidates.empty());
}

void testOptimizerFindsOrphanedHelperButNotAdoptedOne() {
    LiveHelper live;

    const std::string liveAppPath = "/Applications/Live.app/Contents/MacOS/Live";
    const std::string liveHelperPath =
        "/Applications/Live.app/Contents/Frameworks/Live Helper (Renderer).app/Contents/MacOS/Live Helper (Renderer)";
    const std::string deadHelperPath =
        "/Applications/Dead.app/Contents/Frameworks/Dead Helper (Renderer).app/Contents/MacOS/Dead Helper (Renderer)";

    const std::vector<maccleaner::ProcessInfo> samples{
        makeInfo(makeSample(live.pid(), "Live", liveAppPath)),                     // app running
        makeInfo(makeSample(live.pid(), "Live Helper (Renderer)", liveHelperPath)), // its helper: keep
        makeInfo(makeSample(live.pid(), "Dead Helper (Renderer)", deadHelperPath)), // owner gone: reclaim
    };

    const auto candidates = findOptimizationCandidates(samples, {}, kEverythingInstalled);
    CHECK_EQ(candidates.size(), 1u);
    if (!candidates.empty()) {
        CHECK(candidates[0].sample.path == deadHelperPath);
        CHECK(candidates[0].kind == JunkKind::OrphanedHelper);
        CHECK(candidates[0].reason.find("Dead.app") != std::string::npos);
    }
}

// Regression: an earlier version of the orphan rule matched any nested
// helper whose owning app was not running, and proposed killing persistent
// background agents on a real machine -- a login item that provides the
// user's mouse remapping, and an app launcher registered with launchd.
// Both are reparented to launchd and have no running parent app by design.
void testOptimizerSparesPersistentBackgroundAgents() {
    LiveHelper live;

    // Role-less helper living in a LoginItems bundle: the real "Mac Mouse
    // Fix Helper" shape. Two independent reasons to spare it.
    const std::string loginItem =
        "/Applications/Mouse.app/Contents/Library/LoginItems/Mouse Helper.app/Contents/MacOS/Mouse Helper";
    // Role-less launcher in a Helpers directory: the "GeminiAppLauncher"
    // shape -- nested, owner not running, but deliberately persistent.
    const std::string launcher =
        "/Applications/Thing.app/Contents/Helpers/ThingLauncher.app/Contents/MacOS/ThingLauncher";

    const std::vector<maccleaner::ProcessInfo> samples{
        makeInfo(makeSample(live.pid(), "Mouse Helper", loginItem)),
        makeInfo(makeSample(live.pid(), "ThingLauncher", launcher)),
    };

    CHECK(findOptimizationCandidates(samples, {}, kEverythingInstalled).empty());
}

void testOptimizerFindsZombiesStoppedAndAgents() {
    LiveHelper live;

    auto zombie = makeSample(live.pid(), "leftover", "/opt/tool/leftover");
    zombie.state = ProcessState::Zombie;
    auto stopped = makeSample(live.pid(), "paused", "/opt/tool/paused");
    stopped.state = ProcessState::Stopped;
    auto agent = makeSample(live.pid(), "GoogleSoftwareUpdateAgent", "/Users/x/Library/Google/GoogleUpdater");
    auto ordinary = makeSample(live.pid(), "node", "/opt/homebrew/bin/node");

    const auto candidates = findOptimizationCandidates(
        {makeInfo(zombie), makeInfo(stopped), makeInfo(agent), makeInfo(ordinary)}, {}, kEverythingInstalled);
    CHECK_EQ(candidates.size(), 3u); // ordinary background work is left alone

    bool sawZombie = false, sawStopped = false, sawAgent = false, sawOrdinary = false;
    for (const OptimizationCandidate& candidate : candidates) {
        sawZombie |= candidate.sample.name == "leftover";
        sawStopped |= candidate.sample.name == "paused";
        sawAgent |= candidate.sample.name == "GoogleSoftwareUpdateAgent";
        sawOrdinary |= candidate.sample.name == "node";
    }
    CHECK(sawZombie);
    CHECK(sawStopped);
    CHECK(sawAgent);
    CHECK(!sawOrdinary);
}

void testOptimizerSortsByReclaimableMemory() {
    LiveHelper live;
    auto small = makeSample(live.pid(), "small", "/opt/a");
    small.state = ProcessState::Zombie;
    small.memoryBytes = 10 << 20;
    auto big = makeSample(live.pid(), "big", "/opt/b");
    big.state = ProcessState::Zombie;
    big.memoryBytes = 900 << 20;

    const auto candidates = findOptimizationCandidates({makeInfo(small), makeInfo(big)}, {}, kEverythingInstalled);
    CHECK_EQ(candidates.size(), 2u);
    if (candidates.size() == 2) {
        CHECK(candidates[0].sample.name == "big");
    }
}

void testOptimizerFindsDeletedExecutables() {
    LiveHelper live;
    // A path that does not exist: the app was deleted or replaced by an
    // update while this process kept running.
    auto ghostBinary = makeSample(live.pid(), "leftover", "/opt/definitely/not/installed/leftover");
    // A path that does exist must not match this rule.
    auto realBinary = makeSample(live.pid(), "sleep", "/bin/sleep");

    // This test is the one that cares about the filesystem, so it says
    // exactly which path is missing rather than relying on the real disk.
    const maccleaner::PathExistsFn world = [&](const std::string& path) {
        return path != "/opt/definitely/not/installed/leftover";
    };
    const auto candidates =
        findOptimizationCandidates({makeInfo(ghostBinary), makeInfo(realBinary)}, {}, world);
    CHECK_EQ(candidates.size(), 1u);
    if (!candidates.empty()) {
        CHECK(candidates[0].kind == JunkKind::DeletedExecutable);
        CHECK(candidates[0].recommended);
    }
}

void testUpdaterNamePattern() {
    // Generic pattern, so vendors the explicit list never enumerates still
    // get caught.
    CHECK(isRelaunchableAgent("SomeVendorUpdater"));
    CHECK(isRelaunchableAgent("AcmeAutoUpdate"));
    CHECK(isRelaunchableAgent("VendorUpdateService"));
    CHECK(isRelaunchableAgent("GoogleSoftwareUpdateAgent")); // explicit list still works

    // Must not swallow processes that merely contain the letters.
    CHECK(!isRelaunchableAgent("Updaterface"));
    CHECK(!isRelaunchableAgent("Google Chrome"));
    CHECK(!isRelaunchableAgent("node"));
}

// Regression: the generic updater pattern matched SetStoreUpdateService, an
// Apple XPC service under /System/Library/PrivateFrameworks, and proposed
// closing five copies of it. Apple's own on-demand services are not
// third-party update checkers, whatever they are called.
void testOptimizerSparesAppleSystemServices() {
    LiveHelper live;
    const auto appleService = makeSample(
        live.pid(), "SetStoreUpdateService",
        "/System/Library/PrivateFrameworks/CascadeSets.framework/Versions/A/XPCServices/"
        "SetStoreUpdateService.xpc/Contents/MacOS/SetStoreUpdateService");
    CHECK(findOptimizationCandidates({makeInfo(appleService)}, {}, kEverythingInstalled).empty());

    // The same name outside /System, as a normal third-party binary, still
    // qualifies -- the exclusion is about who ships it, not the word.
    const auto vendorUpdater =
        makeSample(live.pid(), "VendorUpdateService", "/Applications/Vendor.app/Helpers/VendorUpdateService");
    const auto candidates =
        findOptimizationCandidates({makeInfo(vendorUpdater)}, {}, kEverythingInstalled);
    CHECK_EQ(candidates.size(), 1u);
    if (!candidates.empty()) {
        CHECK(candidates[0].kind == JunkKind::RelaunchableAgent);
    }
}

void testOptimizerIdleHelperRuleIsOptInAndBounded() {
    LiveHelper live;
    const std::string appPath = "/Applications/Editor.app/Contents/MacOS/Editor";
    const std::string helperPath = "/Applications/Editor.app/Contents/Frameworks/"
                                    "Editor Helper (Renderer).app/Contents/MacOS/Editor Helper (Renderer)";

    auto app = makeSample(live.pid(), "Editor", appPath);
    auto idleHelper = makeSample(live.pid(), "Editor Helper (Renderer)", helperPath);
    idleHelper.memoryBytes = 600ull << 20;
    idleHelper.startTime = std::time(nullptr) - 3600; // an hour old

    // Idle: proposed, but never pre-accepted -- it is alive, and its content
    // would have to reload.
    const auto candidates = findOptimizationCandidates({makeInfo(app), makeInfo(idleHelper, 0.1)}, {}, kEverythingInstalled);
    CHECK_EQ(candidates.size(), 1u);
    if (!candidates.empty()) {
        CHECK(candidates[0].kind == JunkKind::IdleHeavyHelper);
        CHECK(!candidates[0].recommended);
    }

    // Busy: not idle at all, so not proposed.
    CHECK(findOptimizationCandidates({makeInfo(app), makeInfo(idleHelper, 40.0)}, {}, kEverythingInstalled).empty());

    // Idle but small: not worth reclaiming.
    auto smallHelper = idleHelper;
    smallHelper.memoryBytes = 20ull << 20;
    CHECK(findOptimizationCandidates({makeInfo(app), makeInfo(smallHelper, 0.1)}, {}, kEverythingInstalled).empty());

    // Idle and large but only just started: too young to call idle.
    auto youngHelper = idleHelper;
    youngHelper.startTime = std::time(nullptr);
    CHECK(findOptimizationCandidates({makeInfo(app), makeInfo(youngHelper, 0.1)}, {}, kEverythingInstalled).empty());

    // And the rule must never reach a user-facing app, however idle and fat.
    auto idleApp = makeSample(live.pid(), "Editor", appPath);
    idleApp.memoryBytes = 4ull << 30;
    idleApp.startTime = std::time(nullptr) - 86400;
    CHECK(findOptimizationCandidates({makeInfo(idleApp, 0.0)}, {}, kEverythingInstalled).empty());
}

void testOptimizerSortsRecommendedFirst() {
    LiveHelper live;
    const std::string appPath = "/Applications/Editor.app/Contents/MacOS/Editor";
    const std::string helperPath = "/Applications/Editor.app/Contents/Frameworks/"
                                    "Editor Helper (Renderer).app/Contents/MacOS/Editor Helper (Renderer)";

    auto app = makeSample(live.pid(), "Editor", appPath);
    auto bigIdle = makeSample(live.pid(), "Editor Helper (Renderer)", helperPath);
    bigIdle.memoryBytes = 900ull << 20;
    bigIdle.startTime = std::time(nullptr) - 3600;

    auto smallZombie = makeSample(live.pid(), "tiny", "/opt/tiny");
    smallZombie.state = ProcessState::Zombie;
    smallZombie.memoryBytes = 1 << 20;

    const auto candidates =
        findOptimizationCandidates({makeInfo(app), makeInfo(bigIdle, 0.1), makeInfo(smallZombie)}, {},
                                    kEverythingInstalled);
    CHECK_EQ(candidates.size(), 2u);
    if (candidates.size() == 2) {
        // The small recommended one outranks the large opt-in one: the rows
        // the user is most likely to accept must not be buried.
        CHECK(candidates[0].recommended);
        CHECK(!candidates[1].recommended);
    }
}

void testOptimizerRespectsSafeKillGuard() {
    // Our own pid passes every rule below but must still be filtered out by
    // the isSafeToKill() gate the rules apply last.
    auto self = makeSample(::getpid(), "self", "/opt/self");
    self.state = ProcessState::Zombie;
    CHECK(findOptimizationCandidates({makeInfo(self)}, {}, kEverythingInstalled).empty());

    // A pid that does not exist cannot be killed either.
    auto ghost = makeSample(999999, "ghost", "/opt/ghost");
    ghost.state = ProcessState::Zombie;
    CHECK(findOptimizationCandidates({makeInfo(ghost)}, {}, kEverythingInstalled).empty());
}

void testCliParsesOptimize() {
    CliParseError error;
    const char* argv[] = {"mac_cleaner", "optimize", "--apply"};
    const auto options = parseArgs(3, const_cast<char**>(argv), error);
    CHECK(options.has_value());
    CHECK(options->command == Command::Optimize);
    CHECK(options->apply);
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

// --- walk ---------------------------------------------------------------

void testWalkFilesSkipsFilteredDirs() {
    SizedTree tree;
    writeFileOfSize(tree.top() / "Lib.photoslibrary" / "originals" / "b.jpg", 1);

    std::vector<fs::path> seen;
    maccleaner::walkFiles(
        tree.top(), [&](const fs::path& path, const struct stat&) { seen.push_back(path); },
        nullptr, {}, [](const fs::path& dir) { return dir.extension() != ".photoslibrary"; });

    CHECK_EQ(seen.size(), 3u); // big.bin, small.bin, loose.bin
    CHECK(std::none_of(seen.begin(), seen.end(),
                       [](const fs::path& p) { return p.filename() == "b.jpg"; }));
}

// --- photos -------------------------------------------------------------

namespace photos = maccleaner::photos;

photos::GrayImage makeImage(int width, int height, int (*pixel)(int x, int y)) {
    photos::GrayImage image{width, height, std::vector<std::uint8_t>(static_cast<std::size_t>(width * height))};
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            image.pixels[static_cast<std::size_t>(y * width + x)] =
                static_cast<std::uint8_t>(std::clamp(pixel(x, y), 0, 255));
        }
    }
    return image;
}

// Ramp with a 28 px square wave on top: wider than one 9x8 cell, so the
// cells are not monotone and dHash gets both 0 and 1 bits.
int rampPixel(int x, int y) { return x * 2 + ((x / 14) % 2) * 80 + y; }
int rampMirroredPixel(int x, int y) { return rampPixel(63 - x, y); }
int rampBrighterPixel(int x, int y) { return rampPixel(x, y) + 20; }
int checkerPixel(int x, int y) { return ((x / 4 + y / 4) % 2) ? 255 : 0; }

photos::GrayImage boxBlur(const photos::GrayImage& in) {
    photos::GrayImage out = in;
    for (int y = 1; y + 1 < in.height; ++y) {
        for (int x = 1; x + 1 < in.width; ++x) {
            int sum = 0;
            for (int dy = -1; dy <= 1; ++dy) {
                for (int dx = -1; dx <= 1; ++dx) {
                    sum += in.pixels[static_cast<std::size_t>((y + dy) * in.width + x + dx)];
                }
            }
            out.pixels[static_cast<std::size_t>(y * in.width + x)] = static_cast<std::uint8_t>(sum / 9);
        }
    }
    return out;
}

void testDHashIdentical() {
    const auto image = makeImage(64, 64, rampPixel);
    CHECK_EQ(photos::hammingDistance(photos::dHash(image), photos::dHash(image)), 0);
    CHECK(photos::dHash(image) != 0);
}

void testDHashBrightnessShift() {
    const auto a = photos::dHash(makeImage(64, 64, rampPixel));
    const auto b = photos::dHash(makeImage(64, 64, rampBrighterPixel));
    CHECK(photos::hammingDistance(a, b) <= 2);
}

void testDHashMirrored() {
    const auto a = photos::dHash(makeImage(64, 64, rampPixel));
    const auto b = photos::dHash(makeImage(64, 64, rampMirroredPixel));
    CHECK(photos::hammingDistance(a, b) >= 32);
}

void testPhotoMetricsOnTinyImages() {
    CHECK_EQ(photos::dHash(makeImage(4, 4, rampPixel)), 0u);
    CHECK_EQ(photos::sharpness(makeImage(2, 2, checkerPixel)), 0.0);
    CHECK_EQ(photos::dHash(photos::GrayImage{}), 0u);
}

void testSharpnessBlurLower() {
    const auto sharp = makeImage(64, 64, checkerPixel);
    CHECK(photos::sharpness(sharp) > 4 * photos::sharpness(boxBlur(sharp)));
}

photos::PhotoInfo info(std::string id, std::uint64_t hash, int side, double sharpness, std::int64_t created) {
    photos::PhotoInfo p;
    p.id = std::move(id);
    p.hash = hash;
    p.pixelWidth = side;
    p.pixelHeight = side;
    p.sharpness = sharpness;
    p.createdUnix = created;
    return p;
}

void testGroupKeeperOrder() {
    const std::vector<photos::PhotoInfo> infos = {
        info("small", 7, 100, 50, 1000),
        info("big-blurry", 7, 200, 5, 1000),
        info("big-sharp", 7, 200, 9, 3000),
        info("big-sharp-older", 7, 200, 9, 2000),
    };
    const auto groups = photos::groupDuplicates(infos);
    CHECK_EQ(groups.size(), 1u);
    if (groups.size() == 1) {
        CHECK_EQ(groups[0].size(), 4u);
        CHECK_EQ(infos[groups[0][0]].id, std::string("big-sharp-older"));
    }
}

void testGroupTransitive() {
    const std::vector<photos::PhotoInfo> infos = {
        info("a", 0x100, 10, 1, 0), info("b", 0x10F, 10, 1, 0), info("c", 0x1FF, 10, 1, 0),
        info("far", ~0ull, 10, 1, 0),
    };
    const auto groups = photos::groupDuplicates(infos);
    CHECK_EQ(groups.size(), 1u);
    if (!groups.empty()) {
        CHECK_EQ(groups[0].size(), 3u);
    }
}

// dHash is 0 for tiny and flat images; unrelated icons and blank frames
// must not land in one "duplicate" group.
void testGroupSkipsUnhashedPhotos() {
    CHECK(photos::groupDuplicates({info("icon", 0, 4, 1, 0), info("blank", 0, 640, 0, 0)}).empty());
    CHECK_EQ(photos::groupDuplicates({info("x", 0, 10, 1, 0), info("y", 1, 10, 1, 0)}).size(), 0u);
}

void testGroupNoPairs() {
    CHECK(photos::groupDuplicates({}).empty());
    CHECK(photos::groupDuplicates({info("only", 1, 10, 1, 0)}).empty());
}

// The multi-index grouping must find exactly the groups of a plain pair
// scan, on both sides of its chunk-width cutover and at the extremes.
void testGroupMatchesBruteForce() {
    std::mt19937_64 rng(1234);
    std::vector<photos::PhotoInfo> infos;
    for (int base = 0; base < 60; ++base) {
        const std::uint64_t hash = rng();
        for (int copy = 0; copy < 5; ++copy) {
            std::uint64_t flipped = hash;
            for (int flip = static_cast<int>(rng() % 18); flip > 0; --flip) {
                flipped ^= std::uint64_t{1} << (rng() % 64);
            }
            infos.push_back(info("p" + std::to_string(infos.size()), flipped, 10, 1, 0));
        }
    }
    infos.push_back(info("unhashed", 0, 10, 1, 0));

    for (int distance : {-1, 0, 1, 3, 6, 9, 11, 12, 16, 40, 64}) {
        std::vector<std::size_t> parent(infos.size());
        std::iota(parent.begin(), parent.end(), std::size_t{0});
        auto find = [&](std::size_t i) {
            while (parent[i] != i) {
                i = parent[i];
            }
            return i;
        };
        for (std::size_t a = 0; a < infos.size(); ++a) {
            for (std::size_t b = a + 1; b < infos.size(); ++b) {
                if (infos[a].hash != 0 && infos[b].hash != 0 &&
                    photos::hammingDistance(infos[a].hash, infos[b].hash) <= distance) {
                    parent[find(a)] = find(b);
                }
            }
        }
        std::map<std::size_t, std::vector<std::size_t>> components;
        for (std::size_t i = 0; i < infos.size(); ++i) {
            components[find(i)].push_back(i);
        }
        std::vector<std::vector<std::size_t>> expected;
        for (auto& [root, members] : components) {
            if (members.size() > 1) {
                expected.push_back(members);
            }
        }

        std::vector<std::vector<std::size_t>> actual = photos::groupDuplicates(infos, distance);
        for (auto& group : actual) {
            std::sort(group.begin(), group.end());
        }
        std::sort(actual.begin(), actual.end());
        std::sort(expected.begin(), expected.end());
        CHECK(actual == expected);
    }
}

void testScanPhotoFolderUsesDecoder() {
    SizedTree tree;
    for (const char* name : {"a.jpg", "sub/b.JPG", "notes.txt", "bad.png", "L.photoslibrary/originals/x.jpg"}) {
        writeFileOfSize(tree.top() / name, 1);
    }

    const auto fakeDecode = [](const fs::path& path, photos::Decoded& out) {
        if (path.filename() == "bad.png") {
            return false;
        }
        out.gray = makeImage(64, 64, rampPixel);
        out.pixelWidth = 640;
        out.pixelHeight = 480;
        return true;
    };
    const photos::FolderScan scan = photos::scanPhotoFolder(tree.top(), nullptr, {}, fakeDecode);

    CHECK_EQ(scan.photos.size(), 2u);
    CHECK_EQ(scan.undecodable, 1u);
    for (const auto& photo : scan.photos) {
        CHECK(photo.id.find("photoslibrary") == std::string::npos);
        CHECK_EQ(photo.pixelWidth, 640);
        CHECK_EQ(photo.sizeBytes, 1u);
        CHECK(photo.hash == photos::dHash(makeImage(64, 64, rampPixel)));
    }
    CHECK(!photos::isSolidStateVolume("/no/such/volume"));
    CHECK(photos::isPhotoExtension("x.HEIC"));
    CHECK(!photos::isPhotoExtension("x.txt"));
}

// Workers finish out of order; the scan must still report walk order.
void testScanPhotoFolderParallel() {
    SizedTree tree;
    for (int i = 0; i < 40; ++i) {
        writeFileOfSize(tree.top() / ("d" + std::to_string(i % 4)) / ("p" + std::to_string(i) + ".jpg"), 1);
    }
    std::vector<std::string> walkOrder;
    maccleaner::walkFiles(tree.top(), [&](const fs::path& path, const struct stat&) {
        if (photos::isPhotoExtension(path)) {
            walkOrder.push_back(path.string());
        }
    });

    const auto slowDecode = [](const fs::path& path, photos::Decoded& out) {
        std::this_thread::sleep_for(std::chrono::milliseconds(path.filename().string().size() % 3));
        out.gray = makeImage(64, 64, rampPixel);
        return true;
    };
    std::uint64_t progressCalls = 0;
    const photos::FolderScan scan = photos::scanPhotoFolder(
        tree.top(), nullptr, [&](std::uint64_t, const fs::path&) { ++progressCalls; }, slowDecode);
    CHECK_EQ(scan.photos.size(), walkOrder.size());
    for (std::size_t i = 0; i < scan.photos.size() && i < walkOrder.size(); ++i) {
        CHECK_EQ(scan.photos[i].id, walkOrder[i]);
    }
    CHECK_EQ(progressCalls, 40u);

    // A cancel stops the workers before they claim the rest.
    std::atomic<bool> cancelled{false};
    const auto cancellingDecode = [&](const fs::path&, photos::Decoded& out) {
        cancelled = true;
        out.gray = makeImage(64, 64, rampPixel);
        return true;
    };
    CHECK(photos::scanPhotoFolder(tree.top(), &cancelled, {}, cancellingDecode).photos.size() < 40u);
}

// A rescan with the earlier result decodes only new or changed files and
// drops deleted ones.
void testScanPhotoFolderReusesPrevious() {
    SizedTree tree;
    for (const char* name : {"a.jpg", "b.jpg", "sub/c.jpg"}) {
        writeFileOfSize(tree.top() / name, 1);
    }
    std::atomic<int> decodes{0};
    const auto countingDecode = [&](const fs::path&, photos::Decoded& out) {
        ++decodes;
        out.gray = makeImage(64, 64, rampPixel);
        return true;
    };

    const photos::FolderScan first = photos::scanPhotoFolder(tree.top(), nullptr, {}, countingDecode);
    CHECK_EQ(decodes.load(), 3);
    decodes = 0;
    const photos::FolderScan same = photos::scanPhotoFolder(tree.top(), nullptr, {}, countingDecode, first.photos);
    CHECK_EQ(decodes.load(), 0);
    CHECK_EQ(same.photos.size(), 3u);

    writeFileOfSize(tree.top() / "b.jpg", 2); // changed size
    fs::remove(tree.top() / "sub" / "c.jpg");
    decodes = 0;
    const photos::FolderScan changed =
        photos::scanPhotoFolder(tree.top(), nullptr, {}, countingDecode, same.photos);
    CHECK_EQ(decodes.load(), 1);
    CHECK_EQ(changed.photos.size(), 2u);
}

void testPhotoCacheRoundTrip() {
    SizedTree tree;
    const fs::path file = tree.top() / "scan.cache";
    photos::PhotoInfo a = info("/x/a.jpg", 0x1234, 4000, 87.5, 1700000000);
    a.sizeBytes = 123456;
    a.modifiedNs = 1700000000123456789;
    const std::vector<photos::PhotoInfo> saved = {a, info("/x/b\nname.heic", ~0ull, 10, 0, 0)};
    CHECK(photos::savePhotoCache(file, "/x", saved));

    std::vector<photos::PhotoInfo> loaded;
    CHECK(photos::loadPhotoCache(file, "/x", loaded));
    CHECK_EQ(loaded.size(), 2u);
    if (loaded.size() == 2) {
        CHECK_EQ(loaded[0].id, a.id);
        CHECK(loaded[0].hash == a.hash);
        CHECK(loaded[0].sharpness == a.sharpness);
        CHECK_EQ(loaded[0].pixelWidth, 4000);
        CHECK_EQ(loaded[0].createdUnix, a.createdUnix);
        CHECK_EQ(loaded[0].sizeBytes, a.sizeBytes);
        CHECK_EQ(loaded[0].modifiedNs, a.modifiedNs);
        CHECK_EQ(loaded[1].id, saved[1].id);
    }

    CHECK(!photos::loadPhotoCache(file, "/other", loaded));
    CHECK(loaded.empty());
    CHECK(!photos::loadPhotoCache(tree.top() / "missing.cache", "/x", loaded));

    // Damaged files must be rejected, not half-read.
    const auto size = fs::file_size(file);
    fs::resize_file(file, size - 1);
    CHECK(!photos::loadPhotoCache(file, "/x", loaded));
    CHECK(loaded.empty());
    writeFileOfSize(file, 64);
    CHECK(!photos::loadPhotoCache(file, "/x", loaded));
}

// --- File Organizer ---------------------------------------------------------

void testKindFromPath() {
    using organizer::Kind;
    using organizer::kindFromPath;
    CHECK(kindFromPath("/s/a.JPG") == Kind::Photos);
    CHECK(kindFromPath("/s/b.heic") == Kind::Photos);
    CHECK(kindFromPath("/s/Kına ğ.JPG") == Kind::Photos);
    CHECK(kindFromPath("/s/c.MP4") == Kind::Videos);
    CHECK(kindFromPath("/s/d.mov") == Kind::Videos);
    CHECK(kindFromPath("/s/e.mp3") == Kind::Music);
    CHECK(kindFromPath("/s/f.PDF") == Kind::Documents);
    CHECK(kindFromPath("/s/g") == Kind::Other);
    CHECK(kindFromPath("/s/h.xyz") == Kind::Other);
    CHECK(kindFromPath("/s/.DS_Store") == Kind::Other);
    CHECK_EQ(std::string(organizer::kindName(Kind::Videos)), std::string("Videos"));
}

void testCategoryFromLabels() {
    using organizer::PhotoCategory;
    using organizer::categoryFromLabels;
    CHECK(categoryFromLabels({}) == PhotoCategory::Other);
    CHECK(categoryFromLabels({{"people", 0.98f}, {"adult", 0.95f}}) == PhotoCategory::People);
    CHECK(categoryFromLabels({{"outdoor", 0.95f}, {"sky", 0.95f}, {"people", 0.79f}}) == PhotoCategory::People);
    CHECK(categoryFromLabels({{"people", 0.79f}, {"dog", 0.37f}, {"animal", 0.37f}}) == PhotoCategory::People);
    CHECK(categoryFromLabels({{"vehicle", 0.81f}, {"outdoor", 0.76f}, {"people", 0.4f}}) == PhotoCategory::Vehicles);
    CHECK(categoryFromLabels({{"plant", 0.75f}, {"forest", 0.74f}}) == PhotoCategory::Nature);
    CHECK(categoryFromLabels({{"people", 0.9f}, {"screenshot", 0.6f}}) == PhotoCategory::Screenshots);
    CHECK(categoryFromLabels({{"receipt", 0.7f}}) == PhotoCategory::Documents);
    CHECK(categoryFromLabels({{"curtain", 0.84f}, {"people", 0.49f}}) == PhotoCategory::Other);
    CHECK_EQ(std::string(organizer::categoryName(PhotoCategory::Buildings)), std::string("Buildings"));
}

namespace {
// 2023-07-15 12:00 UTC: July 2023 in every time zone.
constexpr std::time_t kJuly2023 = 1689422400;
const organizer::ExistsFn kNothingExists = [](const fs::path&) { return false; };

organizer::FileMeta meta(const fs::path& path, std::optional<std::time_t> date = kJuly2023,
                         organizer::PhotoCategory category = organizer::PhotoCategory::Other) {
    organizer::FileMeta file;
    file.path = path;
    file.kind = organizer::kindFromPath(path);
    file.date = date;
    file.category = category;
    return file;
}
} // namespace

void testPlanPhotoPaths() {
    const auto moves = organizer::planOrganize(
        {meta("/s/x/Kına ğ.JPG", kJuly2023, organizer::PhotoCategory::Nature)}, "/d", kNothingExists);
    CHECK_EQ(moves.size(), std::size_t{1});
    CHECK_EQ(moves[0].from.string(), std::string("/s/x/Kına ğ.JPG"));
    CHECK_EQ(moves[0].to.string(), std::string("/d/Photos/Nature/2023/2023-07/Kına ğ.JPG"));
}

void testPlanOtherKinds() {
    const auto moves = organizer::planOrganize(
        {meta("/s/v.mp4"), meta("/s/m.mp3"), meta("/s/f.pdf"), meta("/s/g"), meta("/s/nodate.mp4", std::nullopt)},
        "/d", kNothingExists);
    CHECK_EQ(moves.size(), std::size_t{4});
    if (moves.size() == 4) {
        CHECK_EQ(moves[0].to.string(), std::string("/d/Videos/2023/2023-07/v.mp4"));
        CHECK_EQ(moves[1].to.string(), std::string("/d/Music/m.mp3"));
        CHECK_EQ(moves[2].to.string(), std::string("/d/Documents/f.pdf"));
        CHECK_EQ(moves[3].to.string(), std::string("/d/Other/g"));
    }
}

void testPlanSkipsAlreadyPlaced() {
    const fs::path placed = "/d/Photos/People/2023/2023-07/a.jpg";
    const auto moves = organizer::planOrganize({meta(placed, kJuly2023, organizer::PhotoCategory::People)}, "/d",
                                               [&](const fs::path& p) { return p == placed; });
    CHECK(moves.empty());
}

void testPlanCollisions() {
    const auto moves = organizer::planOrganize({meta("/s/a/IMG_1.jpg"), meta("/s/b/IMG_1.jpg")}, "/d", kNothingExists);
    CHECK_EQ(moves.size(), std::size_t{2});
    if (moves.size() == 2) {
        CHECK_EQ(moves[0].to.string(), std::string("/d/Photos/Other/2023/2023-07/IMG_1.jpg"));
        CHECK_EQ(moves[1].to.string(), std::string("/d/Photos/Other/2023/2023-07/IMG_1 (2).jpg"));
    }
    const fs::path taken = "/d/Photos/Other/2023/2023-07/IMG_1.jpg";
    const auto onDisk =
        organizer::planOrganize({meta("/s/a/IMG_1.jpg")}, "/d", [&](const fs::path& p) { return p == taken; });
    CHECK_EQ(onDisk.size(), std::size_t{1});
    if (!onDisk.empty()) {
        CHECK_EQ(onDisk[0].to.string(), std::string("/d/Photos/Other/2023/2023-07/IMG_1 (2).jpg"));
    }
}

namespace {
std::string readAll(const fs::path& path) {
    std::ifstream in(path);
    return std::string(std::istreambuf_iterator<char>(in), {});
}
} // namespace

void testApplyMovesFiles() {
    ScratchTree tree;
    std::ofstream(tree.root() / "a.jpg") << "a";
    const fs::path dest = tree.root() / "Photos/Other/2023/2023-07";
    const auto result = organizer::applyPlan(
        {{tree.root() / "a.jpg", dest / "a.jpg"}, {tree.root() / "child_file.txt", tree.root() / "Documents/child_file.txt"}},
        tree.root());
    CHECK_EQ(result.moved, std::size_t{2});
    CHECK(result.problems.empty());
    CHECK(!fs::exists(tree.root() / "a.jpg"));
    CHECK_EQ(readAll(dest / "a.jpg"), std::string("a"));
    CHECK(fs::exists(tree.root() / "Documents/child_file.txt"));
}

void testApplyRefusesOutsideSource() {
    ScratchTree tree;
    const auto result =
        organizer::applyPlan({{tree.outside() / "secret.txt", tree.root() / "Documents/secret.txt"}}, tree.root());
    CHECK_EQ(result.moved, std::size_t{0});
    CHECK_EQ(result.problems.size(), std::size_t{1});
    CHECK(fs::exists(tree.outside() / "secret.txt"));
    CHECK(!fs::exists(tree.root() / "Documents/secret.txt"));
}

void testApplyNeverOverwrites() {
    ScratchTree tree;
    fs::create_directories(tree.root() / "Documents");
    std::ofstream(tree.root() / "Documents/child_file.txt") << "keep";
    const auto result =
        organizer::applyPlan({{tree.root() / "child_file.txt", tree.root() / "Documents/child_file.txt"}}, tree.root());
    CHECK_EQ(result.moved, std::size_t{0});
    CHECK_EQ(result.problems.size(), std::size_t{1});
    CHECK(fs::exists(tree.root() / "child_file.txt"));
    CHECK_EQ(readAll(tree.root() / "Documents/child_file.txt"), std::string("keep"));
}

void testApplyReportsMissingSource() {
    ScratchTree tree;
    std::ofstream(tree.root() / "gone.txt") << "x";
    fs::remove(tree.root() / "gone.txt");
    const auto result = organizer::applyPlan({{tree.root() / "gone.txt", tree.root() / "Documents/gone.txt"},
                                              {tree.root() / "child_file.txt", tree.root() / "Documents/child_file.txt"}},
                                             tree.root());
    CHECK_EQ(result.moved, std::size_t{1});
    CHECK_EQ(result.problems.size(), std::size_t{1});
    CHECK(fs::exists(tree.root() / "Documents/child_file.txt"));
}

void testIsValidDestination() {
    const char* home = std::getenv("HOME");
    const fs::path homeDir = home != nullptr ? home : "/Users/nobody";
    std::string reason;
    CHECK(!organizer::isValidDestination("", &reason));
    CHECK(!organizer::isValidDestination("/System/x", &reason));
    CHECK(!reason.empty());
    CHECK(!organizer::isValidDestination(homeDir / "Pictures/P.photoslibrary/x", &reason));
    CHECK(organizer::isValidDestination(homeDir / "Org", &reason));
}

namespace {
const organizer::MetadataFn kNoMetadata = [](organizer::FileMeta&) {};

std::vector<std::string> relativePaths(const std::vector<organizer::FileMeta>& files, const fs::path& root) {
    std::vector<std::string> out;
    for (const auto& file : files) {
        out.push_back(file.path.lexically_relative(root).string());
    }
    std::sort(out.begin(), out.end());
    return out;
}
} // namespace

void testScanFillsBirthTime() {
    ScratchTree tree;
    const auto files = organizer::scanForOrganize(tree.root(), tree.root(), nullptr, {}, kNoMetadata);
    CHECK_EQ(files.size(), std::size_t{1});
    if (files.size() == 1) {
        struct stat st {};
        CHECK(::stat((tree.root() / "child_file.txt").c_str(), &st) == 0);
        CHECK(files[0].kind == organizer::Kind::Documents);
        CHECK(files[0].date.has_value());
#ifdef __APPLE__
        CHECK(files[0].date == st.st_birthtimespec.tv_sec);
#endif
    }
}

void testScanSkipsOrganizedFolders() {
    ScratchTree tree;
    const fs::path root = tree.root();
    fs::remove(root / "child_file.txt");
    for (const char* name : {"Photos/x.jpg", ".hidden/y.jpg", ".z.jpg", "A.app/c.jpg", "L.photoslibrary/d.jpg",
                             "sub/e.jpg", "sub/Photos/f.jpg"}) {
        writeFileOfSize(root / name, 1);
    }
    const auto files = organizer::scanForOrganize(root, root, nullptr, {}, kNoMetadata);
    // Only kind folders directly under the destination are skipped.
    CHECK(relativePaths(files, root) == (std::vector<std::string>{"sub/Photos/f.jpg", "sub/e.jpg"}));
}

void testOrganizeTwiceMovesNothing() {
    ScratchTree tree;
    const fs::path root = tree.root();
    writeFileOfSize(root / "a/IMG_1.jpg", 1);
    writeFileOfSize(root / "b/IMG_1.jpg", 1);
    writeFileOfSize(root / "song.mp3", 1);
    const auto exists = [](const fs::path& p) { return fs::exists(p); };
    const auto first = organizer::planOrganize(organizer::scanForOrganize(root, root, nullptr, {}, kNoMetadata), root, exists);
    CHECK_EQ(first.size(), std::size_t{4});
    const auto applied = organizer::applyPlan(first, root);
    CHECK_EQ(applied.moved, std::size_t{4});
    CHECK(applied.problems.empty());
    const auto second = organizer::planOrganize(organizer::scanForOrganize(root, root, nullptr, {}, kNoMetadata), root, exists);
    CHECK(second.empty());
}

void testCellOf() {
    CHECK(organizer::cellOf({41.0082, 28.9784}) == organizer::cellOf({41.0101, 28.9799}));
    CHECK(organizer::cellOf({41.0082, 28.9784}) != organizer::cellOf({41.0600, 28.9784}));
    CHECK_EQ(organizer::cellOf({-33.9, 18.4}).lat, -678);
    const organizer::GeoPoint center = organizer::cellCenter(organizer::cellOf({41.0082, 28.9784}));
    CHECK(organizer::cellOf(center) == organizer::cellOf({41.0082, 28.9784}));
}

void testFolderName() {
    CHECK_EQ(organizer::folderName("A/B: C ", "X"), std::string("A-B- C"));
    CHECK_EQ(organizer::folderName("", "X"), std::string("X"));
    CHECK_EQ(organizer::folderName("  ", "X"), std::string("X"));
    CHECK_EQ(organizer::folderName("..", "X"), std::string("X"));
    CHECK_EQ(organizer::folderName("İstanbul", "X"), std::string("İstanbul"));
}

void testPlanPlaceLayout() {
    auto istanbul = meta("/s/a.jpg");
    istanbul.location = organizer::GeoPoint{41.0, 29.0};
    istanbul.country = "Turkey";
    istanbul.province = "Istanbul";
    istanbul.city = "Kartal";
    auto noCity = meta("/s/c.jpg");
    noCity.location = organizer::GeoPoint{39.0, 35.0};
    noCity.country = "Turkey";
    noCity.province = "Ankara";
    const auto moves = organizer::planOrganize({istanbul, meta("/s/b.jpg"), noCity, meta("/s/v.mp4")}, "/d",
                                               kNothingExists, organizer::PhotoLayout::Place);
    CHECK_EQ(moves.size(), std::size_t{4});
    if (moves.size() == 4) {
        CHECK_EQ(moves[0].to.string(), std::string("/d/Photos/Turkey/Istanbul/Kartal/2023/2023-07/a.jpg"));
        CHECK_EQ(moves[1].to.string(), std::string("/d/Photos/Unknown Place/2023/2023-07/b.jpg"));
        CHECK_EQ(moves[2].to.string(), std::string("/d/Photos/Turkey/Ankara/Unknown City/2023/2023-07/c.jpg"));
        CHECK_EQ(moves[3].to.string(), std::string("/d/Videos/2023/2023-07/v.mp4"));
    }
}

namespace {
organizer::FileMeta photoAt(const char* path, double lat, double lon) {
    auto file = meta(path);
    file.location = organizer::GeoPoint{lat, lon};
    return file;
}

struct FakeGeocoder {
    std::vector<organizer::GeocodeStatus> script; // returned in order; then Found
    std::size_t calls = 0;
    std::vector<long long> sleeps;

    organizer::GeocodeFn geocode() {
        return [this](organizer::GeoPoint, organizer::Place& place) {
            const auto status = calls < script.size() ? script[calls] : organizer::GeocodeStatus::Found;
            ++calls;
            if (status == organizer::GeocodeStatus::Found) {
                place = {"Turkey", "Istanbul", "Kartal"};
            }
            return status;
        };
    }
    std::function<void(std::chrono::milliseconds)> sleep() {
        return [this](std::chrono::milliseconds ms) { sleeps.push_back(ms.count()); };
    }
};
} // namespace

void testResolvePlacesGroupsCells() {
    ScratchTree tree;
    std::vector<organizer::FileMeta> files = {photoAt("/s/a.jpg", 41.0082, 28.9784),
                                              photoAt("/s/b.jpg", 41.0101, 28.9799),
                                              photoAt("/s/c.jpg", 39.92, 32.85), meta("/s/d.jpg")};
    FakeGeocoder fake;
    organizer::resolvePlaces(files, tree.root() / "geo.tsv", nullptr, {}, fake.geocode(), fake.sleep());
    CHECK_EQ(fake.calls, std::size_t{2});
    CHECK_EQ(files[0].province, std::string("Istanbul"));
    CHECK_EQ(files[0].city, std::string("Kartal"));
    CHECK_EQ(files[2].country, std::string("Turkey"));
    CHECK(files[3].country.empty());
}

void testResolvePlacesUsesCache() {
    ScratchTree tree;
    std::vector<organizer::FileMeta> files = {photoAt("/s/a.jpg", 41.0082, 28.9784)};
    FakeGeocoder first;
    organizer::resolvePlaces(files, tree.root() / "geo.tsv", nullptr, {}, first.geocode(), first.sleep());
    std::vector<organizer::FileMeta> again = {photoAt("/s/a.jpg", 41.0082, 28.9784)};
    FakeGeocoder second;
    organizer::resolvePlaces(again, tree.root() / "geo.tsv", nullptr, {}, second.geocode(), second.sleep());
    CHECK_EQ(second.calls, std::size_t{0});
    CHECK_EQ(again[0].city, std::string("Kartal"));
}

void testResolvePlacesRetriesThrottled() {
    ScratchTree tree;
    std::vector<organizer::FileMeta> files = {photoAt("/s/a.jpg", 41.0082, 28.9784)};
    FakeGeocoder fake;
    fake.script = {organizer::GeocodeStatus::Throttled};
    organizer::resolvePlaces(files, tree.root() / "geo.tsv", nullptr, {}, fake.geocode(), fake.sleep());
    CHECK_EQ(fake.calls, std::size_t{2});
    CHECK(std::find(fake.sleeps.begin(), fake.sleeps.end(), 60000) != fake.sleeps.end());
    CHECK_EQ(files[0].city, std::string("Kartal"));
}

void testResolvePlacesSkipsFailedInCache() {
    ScratchTree tree;
    std::vector<organizer::FileMeta> files = {photoAt("/s/a.jpg", 41.0082, 28.9784), photoAt("/s/n.jpg", 0.01, 0.01)};
    FakeGeocoder fake;
    fake.script = {organizer::GeocodeStatus::Failed, organizer::GeocodeStatus::NotFound};
    organizer::resolvePlaces(files, tree.root() / "geo.tsv", nullptr, {}, fake.geocode(), fake.sleep());
    CHECK(files[0].country.empty());
    FakeGeocoder again;
    organizer::resolvePlaces(files, tree.root() / "geo.tsv", nullptr, {}, again.geocode(), again.sleep());
    // The failed cell is asked again; the NotFound cell is cached.
    CHECK_EQ(again.calls, std::size_t{1});
}

void testCliParsesOrganize() {
    CliParseError error;
    const char* argv[] = {"mac_cleaner", "organize", "--under=/a", "--dest=/b", "--by=place", "--apply", "--yes"};
    const auto options = parseArgs(7, const_cast<char**>(argv), error);
    CHECK(options.has_value());
    CHECK(options->command == Command::Organize);
    CHECK(options->under == "/a");
    CHECK(options->dest == "/b");
    CHECK(options->photoLayout == organizer::PhotoLayout::Place);
    CHECK(options->apply);

    const char* plain[] = {"mac_cleaner", "organize", "--under=/a"};
    const auto defaults = parseArgs(3, const_cast<char**>(plain), error);
    CHECK(defaults.has_value() && defaults->photoLayout == organizer::PhotoLayout::Content && !defaults->apply);

    // Organizing the whole home folder by default would be a disaster.
    const char* noFolder[] = {"mac_cleaner", "organize"};
    CHECK(!parseArgs(2, const_cast<char**>(noFolder), error).has_value());
    const char* badLayout[] = {"mac_cleaner", "organize", "--under=/a", "--by=size"};
    CHECK(!parseArgs(4, const_cast<char**>(badLayout), error).has_value());
}

int main() {
    testHumanReadableBytes();

    testSafetyAcceptsDirectChildOfAllowedRoot();
    testSafetyRejectsPathOutsideAllowedRoot();
    testSafetyRejectsPhotosLibrary();
    testSafetyRejectsSymlink();
    testSafetyRejectsRootItself();
    testSafetyRejectsVolumesAndMountPoints();
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
    testWalkFilesSkipsFilteredDirs();

    testDHashIdentical();
    testDHashBrightnessShift();
    testDHashMirrored();
    testPhotoMetricsOnTinyImages();
    testSharpnessBlurLower();
    testGroupKeeperOrder();
    testGroupTransitive();
    testGroupSkipsUnhashedPhotos();
    testScanPhotoFolderUsesDecoder();
    testScanPhotoFolderParallel();
    testScanPhotoFolderReusesPrevious();
    testPhotoCacheRoundTrip();
    testGroupMatchesBruteForce();
    testGroupNoPairs();

    testClassifyProcess();
    testDiffProcessSamplesComputesCpuPercent();
    testDiffProcessSamplesHandlesNewAndReusedPids();
#ifdef __APPLE__
    testSampleProcessesSeesOurselves();
#endif
    testIsSafeToKillRejectsProtectedTargets();
    testIsSafeToKillReportsForeignProcessesAccurately();
    testKillProcessTerminatesOwnChild();

    testAppBundleDepthAndClassification();
    testOptimizerNeverTargetsUserFacingApps();
    testOptimizerFindsOrphanedHelperButNotAdoptedOne();
    testOptimizerSparesPersistentBackgroundAgents();
    testOptimizerFindsZombiesStoppedAndAgents();
    testOptimizerSortsByReclaimableMemory();
    testOptimizerFindsDeletedExecutables();
    testUpdaterNamePattern();
    testOptimizerSparesAppleSystemServices();
    testOptimizerIdleHelperRuleIsOptInAndBounded();
    testOptimizerSortsRecommendedFirst();
    testOptimizerRespectsSafeKillGuard();
    testParseSizeSpec();

    testCliDefaultsToScan();
    testCliParsesCleanFlags();
    testCliParsesOnlyList();
    testCliRejectsUnknownCategory();
    testCliRejectsUnknownFlag();
    testCliRejectsPermanentWithoutApply();
    testCliHelpShortCircuits();
    testCliParsesBigFiles();
    testCliParsesPhotos();
    testCliParsesOptimize();
    testKindFromPath();
    testCategoryFromLabels();
    testPlanPhotoPaths();
    testPlanOtherKinds();
    testPlanSkipsAlreadyPlaced();
    testPlanCollisions();
    testApplyMovesFiles();
    testApplyRefusesOutsideSource();
    testApplyNeverOverwrites();
    testApplyReportsMissingSource();
    testIsValidDestination();
    testScanFillsBirthTime();
    testScanSkipsOrganizedFolders();
    testOrganizeTwiceMovesNothing();
    testCellOf();
    testFolderName();
    testPlanPlaceLayout();
    testResolvePlacesGroupsCells();
    testResolvePlacesUsesCache();
    testResolvePlacesRetriesThrottled();
    testResolvePlacesSkipsFailedInCache();
    testCliParsesOrganize();

    if (g_failures == 0) {
        std::cout << "All tests passed.\n";
    } else {
        std::cerr << g_failures << " check(s) failed.\n";
    }
    return g_failures;
}
