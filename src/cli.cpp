#include "maccleaner/cli.hpp"

#include "maccleaner/bigfiles.hpp" // parseSizeSpec

#include <array>
#include <cstdlib>
#include <iostream>
#include <optional>
#include <string_view>

namespace maccleaner {

namespace {

std::optional<Category> parseCategory(std::string_view name) {
    static constexpr std::array<std::pair<std::string_view, Category>, 12> table{{
        {"caches", Category::UserCaches},
        {"logs", Category::UserLogs},
        {"diagnostics", Category::DiagnosticReports},
        {"derived-data", Category::XcodeDerivedData},
        {"xcode-archives", Category::XcodeArchives},
        {"device-support", Category::XcodeDeviceSupport},
        {"simulator", Category::SimulatorCaches},
        {"homebrew", Category::HomebrewCache},
        {"npm", Category::NpmCache},
        {"yarn", Category::YarnCache},
        {"pip", Category::PipCache},
        {"trash", Category::Trash},
    }};
    for (const auto& [key, category] : table) {
        if (key == name) {
            return category;
        }
    }
    return std::nullopt;
}

std::vector<std::string_view> split(std::string_view csv) {
    std::vector<std::string_view> parts;
    std::size_t start = 0;
    while (start <= csv.size()) {
        const std::size_t comma = csv.find(',', start);
        const std::size_t end = (comma == std::string_view::npos) ? csv.size() : comma;
        parts.push_back(csv.substr(start, end - start));
        if (comma == std::string_view::npos) {
            break;
        }
        start = comma + 1;
    }
    return parts;
}

} // namespace

void printUsage() {
    std::cout <<
        "mac_cleaner - scan and clean macOS cache/log/build-artifact directories\n"
        "\n"
        "Usage:\n"
        "  mac_cleaner scan [--only=<categories>]\n"
        "  mac_cleaner clean [--only=<categories>] [--apply] [--permanent] [--yes]\n"
        "  mac_cleaner bigfiles [--under=<path>] [--min=<size>] [--top=<n>]\n"
        "  mac_cleaner processes [--sort=cpu|mem] [--top=<n>]\n"
        "  mac_cleaner optimize [--apply]\n"
        "\n"
        "Commands:\n"
        "  scan       Report what would be cleaned and how much space it would free (default).\n"
        "  clean      Same as scan, but without --apply it is still a dry run. Pass --apply to\n"
        "             actually remove items (moved to Trash by default).\n"
        "  bigfiles   List the largest files under a directory (default: your home).\n"
        "  processes  List your processes by CPU or memory use (1s sampling window).\n"
        "  optimize   Find reclaimable processes (orphaned helpers, zombies, update\n"
        "             agents). Reports only; pass --apply to terminate them.\n"
        "\n"
        "Options (scan/clean):\n"
        "  --only=<categories>  Comma-separated subset, e.g. --only=caches,derived-data\n"
        "                        Categories: caches, logs, diagnostics, derived-data,\n"
        "                        xcode-archives, device-support, simulator, homebrew,\n"
        "                        npm, yarn, pip, trash\n"
        "  --apply               Actually perform deletions (clean command only).\n"
        "  --permanent            Delete permanently instead of moving to Trash. Requires --apply.\n"
        "  --yes                  Skip the interactive confirmation prompt.\n"
        "\n"
        "Options (bigfiles):\n"
        "  --under=<path>        Search root (default: home directory).\n"
        "  --min=<size>          Minimum file size, e.g. 500M, 1.5G, 200K (default: 100M).\n"
        "  --top=<n>             Show at most n files (default: 100).\n"
        "\n"
        "Options (processes):\n"
        "  --sort=cpu|mem        Sort order (default: cpu).\n"
        "  --top=<n>             Show at most n processes (default: 20).\n"
        "\n"
        "  --help                 Show this message.\n";
}

std::optional<CliOptions> parseArgs(int argc, char** argv, CliParseError& error) {
    CliOptions options;

    std::vector<std::string_view> args(argv + (argc > 0 ? 1 : 0), argv + argc);

    std::size_t index = 0;
    if (!args.empty() && (args[0] == "scan" || args[0] == "clean" || args[0] == "bigfiles" ||
                           args[0] == "processes" || args[0] == "optimize")) {
        options.command = (args[0] == "scan")       ? Command::Scan
                          : (args[0] == "clean")     ? Command::Clean
                          : (args[0] == "bigfiles")  ? Command::BigFiles
                          : (args[0] == "processes") ? Command::Processes
                                                      : Command::Optimize;
        index = 1;
    }

    for (; index < args.size(); ++index) {
        const std::string_view arg = args[index];

        if (arg == "--help" || arg == "-h") {
            options.command = Command::Help;
            return options;
        } else if (arg == "--apply") {
            options.apply = true;
        } else if (arg == "--permanent") {
            options.permanent = true;
        } else if (arg == "--yes" || arg == "-y") {
            options.yes = true;
        } else if (arg.rfind("--only=", 0) == 0) {
            const std::string_view csv = arg.substr(std::string_view("--only=").size());
            for (std::string_view name : split(csv)) {
                if (auto category = parseCategory(name)) {
                    options.onlyCategories.push_back(*category);
                } else {
                    error.message = "unknown category: " + std::string(name);
                    return std::nullopt;
                }
            }
        } else if (arg.rfind("--under=", 0) == 0) {
            options.under = std::string(arg.substr(std::string_view("--under=").size()));
            if (options.under.empty()) {
                error.message = "--under needs a path";
                return std::nullopt;
            }
        } else if (arg.rfind("--min=", 0) == 0) {
            const std::string spec(arg.substr(std::string_view("--min=").size()));
            if (!parseSizeSpec(spec, options.minSizeBytes) || options.minSizeBytes == 0) {
                error.message = "cannot parse size: " + spec + " (try 500M, 1.5G, 200K)";
                return std::nullopt;
            }
        } else if (arg.rfind("--sort=", 0) == 0) {
            const std::string key(arg.substr(std::string_view("--sort=").size()));
            if (key != "cpu" && key != "mem") {
                error.message = "--sort must be cpu or mem, got: " + key;
                return std::nullopt;
            }
            options.sortKey = key;
        } else if (arg.rfind("--top=", 0) == 0) {
            const std::string spec(arg.substr(std::string_view("--top=").size()));
            char* end = nullptr;
            const unsigned long long parsed = std::strtoull(spec.c_str(), &end, 10);
            if (end == spec.c_str() || *end != '\0' || parsed == 0) {
                error.message = "--top needs a positive integer";
                return std::nullopt;
            }
            options.top = static_cast<std::size_t>(parsed);
        } else {
            error.message = "unrecognized argument: " + std::string(arg);
            return std::nullopt;
        }
    }

    if (options.permanent && !options.apply) {
        error.message = "--permanent requires --apply";
        return std::nullopt;
    }

    return options;
}

} // namespace maccleaner
