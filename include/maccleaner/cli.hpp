#pragma once

#include "maccleaner/types.hpp"

#include <optional>
#include <string>
#include <vector>

namespace maccleaner {

enum class Command {
    Scan,   // report sizes only (default)
    Clean,  // scan, then prompt/act according to options
    Help,
};

struct CliOptions {
    Command command = Command::Scan;
    std::vector<Category> onlyCategories; // empty = all categories
    bool apply = false;      // Clean requires --apply, otherwise it's a dry run
    bool permanent = false;  // delete instead of moving to Trash (requires --apply too)
    bool yes = false;        // skip the interactive confirmation prompt
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
