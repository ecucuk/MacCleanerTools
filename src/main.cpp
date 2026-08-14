#include "maccleaner/cleaner.hpp"
#include "maccleaner/cli.hpp"
#include "maccleaner/format.hpp"
#include "maccleaner/safety.hpp"
#include "maccleaner/scanner.hpp"
#include "maccleaner/trash.hpp"

#include <algorithm>
#include <iostream>

namespace {

using namespace maccleaner;

std::vector<ScanTarget> selectTargets(const CliOptions& options) {
    std::vector<ScanTarget> all = defaultTargets(homeDirectory());
    if (options.onlyCategories.empty()) {
        return all;
    }
    std::vector<ScanTarget> filtered;
    for (ScanTarget& target : all) {
        const bool wanted = std::find(options.onlyCategories.begin(), options.onlyCategories.end(), target.category) !=
                             options.onlyCategories.end();
        if (wanted) {
            filtered.push_back(std::move(target));
        }
    }
    return filtered;
}

void printScanResults(const std::vector<ScanResult>& results) {
    std::uintmax_t grandTotal = 0;
    for (const ScanResult& result : results) {
        if (!result.rootExisted) {
            continue;
        }
        std::cout << result.label << "  [" << result.root.string() << "]\n";
        if (result.entries.empty()) {
            std::cout << "  (empty)\n";
        }
        for (const FileEntry& entry : result.entries) {
            std::cout << "  " << humanReadableBytes(entry.sizeBytes) << "\t" << entry.path.filename().string()
                       << (entry.isDirectory ? "/" : "") << "\n";
        }
        std::cout << "  -- " << humanReadableBytes(result.totalSizeBytes) << " total --\n\n";
        grandTotal += result.totalSizeBytes;
    }
    std::cout << "================================\n";
    std::cout << "Total reclaimable: " << humanReadableBytes(grandTotal) << "\n";
}

bool confirm(const std::string& prompt) {
    std::cout << prompt << " [y/N] ";
    std::string line;
    if (!std::getline(std::cin, line)) {
        return false;
    }
    return line == "y" || line == "Y" || line == "yes";
}

int runScan(const CliOptions& options) {
    const std::vector<ScanTarget> targets = selectTargets(options);
    const std::vector<ScanResult> results = scanAll(targets);
    printScanResults(results);
    return 0;
}

int runClean(const CliOptions& options) {
    const std::vector<ScanTarget> targets = selectTargets(options);

    safety::AllowedRoots allowed;
    registerAllowedRoots(targets, allowed);

    const std::vector<ScanResult> results = scanAll(targets);
    printScanResults(results);

    CleanOptions cleanOptions;
    cleanOptions.dryRun = !options.apply;
    cleanOptions.mode = options.permanent ? DeleteMode::Permanent : DeleteMode::Trash;

    // ~/.Trash is always emptied permanently -- see requiresPermanentDelete().
    // Call that out before asking for confirmation rather than surprising the
    // user with an irreversible delete they didn't ask for with --permanent.
    const bool emptiesTrash = std::any_of(results.begin(), results.end(), [](const ScanResult& result) {
        return requiresPermanentDelete(result.category) && result.rootExisted && !result.entries.empty();
    });

    // In a fallback build (non-Apple, or -DMACCLEANER_USE_NATIVE_TRASH=OFF)
    // trash::moveToTrash is remove_all, so "Trash" mode is *not* recoverable.
    // Saying "move to Trash" there would be an outright false promise about
    // whether the user can undo this.
    const bool trashIsRecoverable = trash::isNativeImplementation();

    if (!cleanOptions.dryRun && !options.yes) {
        const std::string verb = (options.permanent || !trashIsRecoverable) ? "PERMANENTLY DELETE" : "move to Trash";
        std::string prompt = "\nThis will " + verb + " the items listed above.";
        if (!trashIsRecoverable && !options.permanent) {
            prompt += "\nThis build has no native Trash support, so deletions are irreversible.";
        } else if (emptiesTrash && !options.permanent) {
            prompt += "\nItems already in the Trash will be deleted permanently (they cannot be trashed again).";
        }
        if (!confirm(prompt + " Continue?")) {
            std::cout << "Aborted.\n";
            return 1;
        }
    }

    std::uintmax_t totalFreed = 0;
    std::uintmax_t totalWouldFree = 0;
    int failures = 0;
    int skipped = 0;
    for (const ScanResult& result : results) {
        if (!result.rootExisted || result.entries.empty()) {
            continue;
        }
        const CleanReport report = clean(result, allowed, cleanOptions);
        for (const CleanOutcome& outcome : report.outcomes) {
            if (outcome.skipped) {
                std::cout << "SKIP  " << outcome.path.string() << "  (" << outcome.message << ")\n";
                ++skipped;
            } else if (!outcome.succeeded) {
                std::cout << "FAIL  " << outcome.path.string() << "  (" << outcome.message << ")\n";
                ++failures;
            } else if (!cleanOptions.dryRun) {
                std::cout << "OK    " << outcome.path.string() << "  (" << humanReadableBytes(outcome.sizeBytes) << ")\n";
            }
        }
        totalFreed += report.bytesFreed;
        totalWouldFree += report.bytesWouldFree;
    }

    if (skipped > 0) {
        // The scan total above counts everything found; this is what survived
        // the safety re-check, so the two numbers can legitimately differ.
        std::cout << "\n" << skipped << " item(s) skipped by the safety check.\n";
    }

    if (cleanOptions.dryRun) {
        std::cout << "\nWould free " << humanReadableBytes(totalWouldFree)
                   << ". Dry run only -- nothing was deleted. Re-run with --apply to actually clean.\n";
    } else {
        std::cout << "\nFreed " << humanReadableBytes(totalFreed) << ".\n";
    }

    return failures == 0 ? 0 : 1;
}

} // namespace

int main(int argc, char** argv) {
    CliParseError parseError;
    const std::optional<CliOptions> parsed = parseArgs(argc, argv, parseError);
    if (!parsed) {
        std::cerr << "error: " << parseError.message << "\n\n";
        printUsage();
        return 2;
    }

    const CliOptions& options = *parsed;
    switch (options.command) {
        case Command::Help:
            printUsage();
            return 0;
        case Command::Scan:
            return runScan(options);
        case Command::Clean:
            return runClean(options);
    }
    return 0;
}
