// Minimal, dependency-free test runner: no GoogleTest/Catch2 fetch required
// to build & run the suite. Each CHECK failure is logged and counted; main()
// returns the failure count as the process exit code (0 == all green), which
// is all CTest needs.

#include "maccleaner/cleaner.hpp"
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

    testCliDefaultsToScan();
    testCliParsesCleanFlags();
    testCliParsesOnlyList();
    testCliRejectsUnknownCategory();
    testCliRejectsUnknownFlag();
    testCliRejectsPermanentWithoutApply();
    testCliHelpShortCircuits();

    if (g_failures == 0) {
        std::cout << "All tests passed.\n";
    } else {
        std::cerr << g_failures << " check(s) failed.\n";
    }
    return g_failures;
}
