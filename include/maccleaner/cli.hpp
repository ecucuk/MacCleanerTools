#pragma once

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
