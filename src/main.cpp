#include "maccleaner/bigfiles.hpp"
#include "maccleaner/cleaner.hpp"
#include "maccleaner/cli.hpp"
#include "maccleaner/format.hpp"
#include "maccleaner/optimizer.hpp"
#include "maccleaner/organizer.hpp"
#include "maccleaner/photos.hpp"
#include "maccleaner/processes.hpp"
#include "maccleaner/safety.hpp"
#include "maccleaner/scanner.hpp"
#include "maccleaner/trash.hpp"
#include "maccleaner/updater.hpp"

#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <iostream>
#include <map>
#include <thread>

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

int runBigFiles(const CliOptions& options) {
    BigFileScanOptions scanOptions;
    scanOptions.root = options.under.empty() ? homeDirectory() : std::filesystem::path(options.under);
    if (options.minSizeBytes > 0) {
        scanOptions.minSizeBytes = options.minSizeBytes;
    }
    if (options.top > 0) {
        scanOptions.maxResults = options.top;
    }

    std::error_code ec;
    if (!std::filesystem::is_directory(scanOptions.root, ec) || ec) {
        std::cerr << "error: not a directory: " << scanOptions.root.string() << "\n";
        return 2;
    }

    const std::vector<BigFile> files = findBigFiles(scanOptions);

    if (files.empty()) {
        std::cout << "No files >= " << humanReadableBytes(scanOptions.minSizeBytes) << " under "
                   << scanOptions.root.string() << ".\n";
        return 0;
    }

    std::uintmax_t total = 0;
    for (const BigFile& file : files) {
        std::cout << "  " << humanReadableBytes(file.sizeBytes) << "\t" << file.path.string() << "\n";
        total += file.sizeBytes;
    }
    std::cout << "================================\n";
    std::cout << files.size() << " file(s), " << humanReadableBytes(total) << " total (threshold "
               << humanReadableBytes(scanOptions.minSizeBytes) << ", top " << scanOptions.maxResults << ")\n";
    return 0;
}

int runOrganize(const CliOptions& options) {
    namespace fs = std::filesystem;
    const fs::path source = options.under;
    const fs::path dest = options.dest.empty() ? source : fs::path(options.dest);
    std::error_code ec;
    if (!fs::is_directory(source, ec) || ec) {
        std::cerr << "error: not a directory: " << source.string() << "\n";
        return 2;
    }
    std::string reason;
    if (!organizer::isValidDestination(dest, &reason)) {
        std::cerr << "error: " << reason << "\n";
        return 1;
    }

    auto files = organizer::scanForOrganize(source, dest, nullptr, [](std::size_t seen) {
        if (seen % 200 == 0) {
            std::cerr << "\rRead " << seen << " file(s)..." << std::flush;
        }
    });
    std::cerr << "\rRead " << files.size() << " file(s).    \n";
    if (options.photoLayout == organizer::PhotoLayout::Place) {
        organizer::resolvePlaces(files, homeDirectory() / "Library/Caches/MacCleaner/geocode.tsv", nullptr,
                                 [](std::size_t done, std::size_t total) {
                                     std::cerr << "\rLooked up " << done << "/" << total << " place(s)..." << std::flush;
                                 });
        std::cerr << "\n";
    }
    const auto moves = organizer::planOrganize(
        files, dest, [](const fs::path& path) { std::error_code e; return fs::exists(path, e); }, options.photoLayout);

    // "Photos/Nature", "Videos", ...: the first level that tells the groups apart.
    std::map<std::string, std::size_t> groups;
    for (const organizer::Move& move : moves) {
        const fs::path relative = move.to.lexically_relative(dest);
        auto part = relative.begin();
        std::string group = part->string();
        if (group == "Photos" && std::next(part) != relative.end()) {
            group += "/" + std::next(part)->string();
        }
        ++groups[group];
    }
    for (const auto& [group, count] : groups) {
        std::cout << "  " << count << "\t" << group << "\n";
    }
    for (std::size_t i = 0; i < moves.size() && i < 20; ++i) {
        std::cout << "  " << moves[i].from.string() << " -> " << moves[i].to.string() << "\n";
    }
    std::cout << "================================\n";
    std::cout << moves.size() << " of " << files.size() << " file(s) to move into " << dest.string() << "\n";
    if (options.photoLayout == organizer::PhotoLayout::Place) {
        if (const std::size_t waiting = organizer::countWaitingForPlace(files); waiting > 0) {
            std::cout << waiting << " photo(s) stay where they are: their place lookup failed (offline?). "
                      << "Run again later.\n";
        }
    }
    if (!options.apply) {
        std::cout << "Dry run. Pass --apply to move them.\n";
        return 0;
    }
    if (moves.empty()) {
        return 0;
    }
    if (!options.yes && !confirm("\nThis will move the files listed above. Continue?")) {
        std::cout << "Aborted.\n";
        return 1;
    }
    const organizer::ApplyResult result = organizer::applyPlan(moves, source);
    for (const std::string& problem : result.problems) {
        std::cout << "FAIL  " << problem << "\n";
    }
    std::cout << result.moved << " moved, " << result.problems.size() << " problem(s)\n";
    return result.problems.empty() ? 0 : 1;
}

int runPhotos(const CliOptions& options) {
    const std::filesystem::path root = options.under.empty() ? homeDirectory() : std::filesystem::path(options.under);
    std::error_code ec;
    if (!std::filesystem::is_directory(root, ec) || ec) {
        std::cerr << "error: not a directory: " << root.string() << "\n";
        return 2;
    }

    const photos::FolderScan scan = photos::scanPhotoFolder(root);
    const auto groups = photos::groupDuplicates(scan.photos, options.distance);

    auto printPhoto = [](const char* mark, const photos::PhotoInfo& p) {
        std::printf("    %-5s %5dx%-5d  sharp %8.1f  %9s  %s\n", mark, p.pixelWidth, p.pixelHeight, p.sharpness,
                    humanReadableBytes(p.sizeBytes).c_str(), p.id.c_str());
    };

    std::cout << "Duplicate groups: " << groups.size() << "\n";
    for (std::size_t g = 0; g < groups.size(); ++g) {
        std::cout << "  Group " << (g + 1) << "\n";
        for (std::size_t m = 0; m < groups[g].size(); ++m) {
            printPhoto(m == 0 ? "best" : "", scan.photos[groups[g][m]]);
        }
    }

    std::vector<const photos::PhotoInfo*> blurry;
    for (const photos::PhotoInfo& p : scan.photos) {
        if (p.sharpness < options.blurThreshold) {
            blurry.push_back(&p);
        }
    }
    std::sort(blurry.begin(), blurry.end(), [](auto* a, auto* b) { return a->sharpness < b->sharpness; });
    std::cout << "Blurry (sharpness < " << options.blurThreshold << "): " << blurry.size() << "\n";
    for (const photos::PhotoInfo* p : blurry) {
        printPhoto("", *p);
    }

    std::cout << "================================\n";
    std::cout << scan.photos.size() << " photo(s) analysed, " << scan.undecodable << " could not be decoded\n";
    return 0;
}

int runProcesses(const CliOptions& options) {
    const std::size_t top = options.top > 0 ? options.top : 20;
    const bool sortByMemory = options.sortKey == "mem";

    // CPU%% needs a sampling window; one second matches what people expect
    // from `top`-style tools.
    const std::vector<ProcessSample> before = sampleProcesses(::geteuid());
    const auto start = std::chrono::steady_clock::now();
    std::this_thread::sleep_for(std::chrono::seconds(1));
    const std::vector<ProcessSample> after = sampleProcesses(::geteuid());
    const auto wallDeltaNs = static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - start).count());

    std::vector<ProcessInfo> infos = diffProcessSamples(before, after, wallDeltaNs);
    std::sort(infos.begin(), infos.end(), [sortByMemory](const ProcessInfo& a, const ProcessInfo& b) {
        return sortByMemory ? a.sample.memoryBytes > b.sample.memoryBytes : a.cpuPercent > b.cpuPercent;
    });
    if (infos.size() > top) {
        infos.resize(top);
    }

    std::printf("%6s  %10s  %7s  %s\n", "CPU%", "MEM", "PID", "NAME");
    for (const ProcessInfo& info : infos) {
        std::printf("%6.1f  %10s  %7d  %s\n", info.cpuPercent,
                     humanReadableBytes(info.sample.memoryBytes).c_str(), info.sample.pid,
                     info.sample.name.c_str());
    }
    std::printf("%zu of %zu processes shown (owned by uid %u).\n", infos.size(), after.size(),
                 ::geteuid());
    return 0;
}

int runOptimize(const CliOptions& options) {
    // The idle-helper rule needs a real CPU percentage, which only exists
    // across two samples; a single snapshot would make every process look
    // idle and propose the lot.
    const std::vector<ProcessSample> before = sampleProcesses(::geteuid());
    const auto start = std::chrono::steady_clock::now();
    std::this_thread::sleep_for(std::chrono::seconds(1));
    const std::vector<ProcessSample> after = sampleProcesses(::geteuid());
    const auto wallDeltaNs = static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - start).count());

    const std::vector<ProcessInfo> infos = diffProcessSamples(before, after, wallDeltaNs);
    const std::vector<OptimizationCandidate> candidates = findOptimizationCandidates(infos);

    if (candidates.empty()) {
        std::cout << "Nothing to reclaim.\n";
        return 0;
    }

    std::uintmax_t recommendedBytes = 0;
    std::size_t recommendedCount = 0;
    for (const OptimizationCandidate& candidate : candidates) {
        std::printf("  %-3s %10s  %-28s  %s\n", candidate.recommended ? "*" : " ",
                     humanReadableBytes(candidate.reclaimableBytes).c_str(), candidate.sample.name.c_str(),
                     candidate.reason.c_str());
        if (candidate.recommended) {
            recommendedBytes += candidate.reclaimableBytes;
            ++recommendedCount;
        }
    }
    std::cout << "================================\n";
    std::cout << candidates.size() << " process(es) found; " << recommendedCount << " recommended ("
               << humanReadableBytes(recommendedBytes) << ")\n";
    std::cout << "Rows marked * are recommended; the rest are alive and would reload on next use.\n";

    if (!options.apply) {
        std::cout << "\nReport only -- re-run with --apply to terminate the recommended ones.\n";
        return 0;
    }

    // --apply acts on the recommended set only. The opt-in rows cost a
    // reload, and a non-interactive flag is no place to make that choice for
    // someone; the GUI's review sheet is where they get picked individually.
    std::size_t terminated = 0;
    for (const OptimizationCandidate& candidate : candidates) {
        if (!candidate.recommended) {
            continue;
        }
        std::string error;
        if (killProcess(candidate.sample.pid, KillMode::Graceful, error)) {
            ++terminated;
        } else {
            std::cout << "FAIL  " << candidate.sample.name << " — " << error << "\n";
        }
    }
    std::cout << "Terminated " << terminated << " of " << recommendedCount << " recommended.\n";
    return terminated == recommendedCount ? 0 : 1;
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

int runUpdates(const CliOptions& options) {
    using namespace maccleaner::updater;
    Environment env = defaultEnvironment();

    if (!options.upgradeNames.empty()) {
        if (env.brewPath.empty()) {
            std::cerr << "error: Homebrew is not installed\n";
            return 2;
        }
        // Only Homebrew is upgraded here, so skip the other sources' checks.
        env.portPath.clear();
        env.appFolders.clear();
        std::cout << "Checking Homebrew...\n";
        const CheckResult check = checkUpdates(runCommand, env, nullptr);
        if (!check.sources.front().error.empty()) {
            std::cerr << "error: brew outdated failed: " << check.sources.front().error << "\n";
            return 1;
        }
        std::vector<OutdatedItem> selected;
        for (const auto& name : options.upgradeNames) {
            const auto it = std::find_if(check.items.begin(), check.items.end(),
                                         [&](const OutdatedItem& item) { return item.name == name; });
            if (it == check.items.end()) {
                std::cerr << "error: " << name << " is not an outdated Homebrew item\n";
                return 2;
            }
            if (it->pinned) {
                std::cerr << "error: " << name << " is pinned (brew unpin " << name << " first)\n";
                return 2;
            }
            selected.push_back(*it);
        }
        int failed = 0;
        for (const auto& item : selected) {
            std::cout << "Upgrading " << item.name << " (" << item.installedVersion << " -> " << item.latestVersion
                      << ")... " << std::flush;
            const CommandResult r = upgradeBrew(runCommand, env, item);
            if (r.exitCode == 0) {
                std::cout << "ok\n";
                continue;
            }
            ++failed;
            std::string last = r.output;
            while (!last.empty() && (last.back() == '\n' || last.back() == ' ')) {
                last.pop_back();
            }
            last = last.substr(last.find_last_of('\n') == std::string::npos ? 0 : last.find_last_of('\n') + 1);
            std::cout << "failed: " << (last.empty() ? "exit code " + std::to_string(r.exitCode) : last) << "\n";
            std::cout << "  try in Terminal: " << manualCommand(item) << "\n";
        }
        return failed == 0 ? 0 : 1;
    }

    std::cout << "Checking for updates (brew update, App Store and appcast lookups)...\n";
    const CheckResult check = checkUpdates(runCommand, env, nullptr);
    for (const auto& status : check.sources) {
        std::cout << "\n== " << toString(status.source) << " ==\n";
        if (!status.available) {
            std::cout << "  (not installed)\n";
            continue;
        }
        if (!status.error.empty()) {
            std::cout << "  error: " << status.error << "\n";
        }
        bool any = false;
        for (const auto& item : check.items) {
            if (item.source != status.source) {
                continue;
            }
            any = true;
            std::cout << "  " << item.name << "  " << item.installedVersion << " -> " << item.latestVersion;
            if (item.isCask) std::cout << "  [cask]";
            if (item.pinned) std::cout << "  [pinned]";
            if (!item.appPath.empty()) std::cout << "  " << item.appPath;
            if (item.source == Source::MacPorts) std::cout << "  (" << manualCommand(item) << ")";
            std::cout << "\n";
        }
        if (!any && status.error.empty()) {
            std::cout << "  (up to date)\n";
        }
    }
    return 0;
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
        case Command::BigFiles:
            return runBigFiles(options);
        case Command::Processes:
            return runProcesses(options);
        case Command::Photos:
            return runPhotos(options);
        case Command::Optimize:
            return runOptimize(options);
        case Command::Organize:
            return runOrganize(options);
        case Command::Updates:
            return runUpdates(options);
    }
    return 0;
}
