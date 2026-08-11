// Minimal, dependency-free test runner: no GoogleTest/Catch2 fetch required
// to build & run the suite. Each CHECK failure is logged and counted; main()
// returns the failure count as the process exit code (0 == all green), which
// is all CTest needs.

#include "maccleaner/format.hpp"
#include "maccleaner/safety.hpp"

#include <fstream>
#include <iostream>
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

namespace fs = std::filesystem;
using maccleaner::humanReadableBytes;
using maccleaner::safety::AllowedRoots;
using maccleaner::safety::isSafeToDelete;

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

} // namespace

int main() {
    testHumanReadableBytes();
    testSafetyAcceptsDirectChildOfAllowedRoot();
    testSafetyRejectsPathOutsideAllowedRoot();
    testSafetyRejectsSymlink();
    testSafetyRejectsRootItself();
    testSafetyRejectsNonexistentPath();

    if (g_failures == 0) {
        std::cout << "All tests passed.\n";
    } else {
        std::cerr << g_failures << " check(s) failed.\n";
    }
    return g_failures;
}
