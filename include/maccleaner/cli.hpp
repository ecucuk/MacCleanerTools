#pragma once

#include "maccleaner/organizer.hpp"
#include "maccleaner/photos.hpp"
#include "maccleaner/types.hpp"

#include <optional>
#include <string>
#include <vector>

namespace maccleaner {

enum class Command {
    Scan,       // report sizes only (default)
    Clean,      // scan, then prompt/act according to options
    BigFiles,   // list the largest files under a root
    Processes,  // list the current user's processes by CPU/memory
    Photos,     // report duplicate and blurry photos under a root
    Optimize,   // find (and with --apply, terminate) reclaimable processes
    Organize,   // sort a folder into Photos/Videos/Music/Documents/Other (--apply moves)
    Malware,    // scan for malware signatures and suspicious persistence (--trash remediates)
    Updates,    // list outdated software; --upgrade <name>... upgrades brew items
    Uninstall,  // --list apps, or report/trash one app and its leftovers (--apply)
    Help,
};

struct CliOptions {
    Command command = Command::Scan;
    std::vector<Category> onlyCategories; // empty = all categories
    bool apply = false;      // Clean requires --apply, otherwise it's a dry run
    bool permanent = false;  // delete instead of moving to Trash (requires --apply too)
    bool yes = false;        // skip the interactive confirmation prompt

    // bigfiles options. `under` empty = home directory. minSizeBytes/top keep
    // the defaults from BigFileScanOptions when the flags are absent.
    std::string under;
    std::uintmax_t minSizeBytes = 0; // 0 = use default
    std::size_t top = 0;             // 0 = use default (also caps `processes` output)

    // processes options.
    std::string sortKey; // "cpu" (default) or "mem"

    // photos options (`under` is shared with bigfiles).
    int distance = photos::kDefaultMaxDistance;
    double blurThreshold = photos::kDefaultBlurThreshold;

    // organize options (`under` is the required source folder).
    std::string dest; // empty = the source folder itself
    organizer::PhotoLayout photoLayout = organizer::PhotoLayout::Content;

    // malware options. Empty = malware::defaultScanRoots(); --trash sets `apply`.
    std::vector<std::string> paths;
    // updates options: brew items to upgrade (empty = list only).
    std::vector<std::string> upgradeNames;
    // uninstall options: the target is paths[0]; --apply moves it to the Trash.
    bool listApps = false;
};

struct CliParseError {
    std::string message;
};

// Parses argv[1..argc). Returns CliParseError on unrecognized flags/values;
// the caller is expected to print `.message` and exit non-zero. `--help`
// short-circuits to Command::Help rather than being an error.
std::optional<CliOptions> parseArgs(int argc, char** argv, CliParseError& error);

void printUsage();

} // namespace maccleaner
