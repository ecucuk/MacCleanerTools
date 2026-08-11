#include "maccleaner/cleaner.hpp"
#include "maccleaner/trash.hpp"

#include <filesystem>
#include <system_error>

namespace maccleaner {

namespace fs = std::filesystem;

CleanReport clean(const ScanResult& result, const safety::AllowedRoots& allowed, const CleanOptions& options) {
    CleanReport report;
    report.outcomes.reserve(result.entries.size());

    for (const FileEntry& entry : result.entries) {
        CleanOutcome outcome;
        outcome.path = entry.path;
        outcome.sizeBytes = entry.sizeBytes;

        std::string reason;
        if (!safety::isSafeToDelete(entry.path, allowed, &reason)) {
            outcome.skipped = true;
            outcome.message = reason;
            report.outcomes.push_back(std::move(outcome));
            continue;
        }

        report.bytesWouldFree += entry.sizeBytes;

        if (options.dryRun) {
            outcome.succeeded = true; // "would succeed"
            outcome.message = "dry run: not deleted";
            report.outcomes.push_back(std::move(outcome));
            continue;
        }

        if (options.mode == DeleteMode::Trash) {
            std::string error;
            outcome.succeeded = trash::moveToTrash(entry.path, error);
            outcome.message = outcome.succeeded ? "moved to Trash" : error;
        } else {
            std::error_code ec;
            const std::uintmax_t removed = fs::remove_all(entry.path, ec);
            outcome.succeeded = !ec && removed > 0;
            outcome.message = outcome.succeeded ? "permanently deleted" : ec.message();
        }

        if (outcome.succeeded) {
            report.bytesFreed += entry.sizeBytes;
        }
        report.outcomes.push_back(std::move(outcome));
    }

    return report;
}

} // namespace maccleaner
