#include "maccleaner/cli.hpp"

#include "maccleaner/bigfiles.hpp" // parseSizeSpec

#include <algorithm>
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
        "  mac_cleaner photos [--under=<path>] [--distance=<n>] [--blur=<t>]\n"
        "  mac_cleaner optimize [--apply]\n"
        "  mac_cleaner organize --under=<path> [--dest=<path>] [--by=content|place] [--apply] [--yes]\n"
        "  mac_cleaner malware [--path=<path>]... [--trash] [--yes]\n"
        "  mac_cleaner updates [--upgrade <name>...]\n"
        "  mac_cleaner uninstall --list\n"
        "  mac_cleaner uninstall <name|bundle-id|path> [--apply]\n"
        "  mac_cleaner check-update\n"
        "  mac_cleaner --version\n"
        "\n"
        "Commands:\n"
        "  scan       Report what would be cleaned and how much space it would free (default).\n"
        "  clean      Same as scan, but without --apply it is still a dry run. Pass --apply to\n"
        "             actually remove items (moved to Trash by default).\n"
        "  bigfiles   List the largest files under a directory (default: your home).\n"
        "  processes  List your processes by CPU or memory use (1s sampling window).\n"
        "  photos     Report duplicate and blurry photos under a directory (default: your home).\n"
        "             Report only; remove photos from the app.\n"
        "  optimize   Find reclaimable processes (orphaned helpers, zombies, update\n"
        "             agents). Reports only; pass --apply to terminate them.\n"
        "  organize   Sort a folder into Photos/<Category or Place>/YYYY/YYYY-MM, Videos/YYYY/YYYY-MM,\n"
        "             Music, Documents and Other. A dry run unless --apply; never overwrites.\n"
        "  malware    Scan for XProtect.plist signatures, quarantined unsigned programs and\n"
        "             suspicious LaunchAgents/LaunchDaemons. Reports only; not a real-time AV.\n"
        "  uninstall  List installed third-party apps (--list), or show an app and its\n"
        "             leftovers. Without --apply it is a dry run; --apply moves them to Trash.\n"
        "  check-update  Ask GitHub whether a newer MacCleaner release exists.\n"
        "  updates    List outdated Homebrew, MacPorts, App Store and Sparkle software\n"
        "             (runs brew update and fetches App Store and appcast versions).\n"
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
        "Options (photos):\n"
        "  --under=<path>        Folder to scan (default: home directory).\n"
        "  --distance=<n>        Max hash difference for duplicates, 0-64 (default: 6).\n"
        "  --blur=<t>            Sharpness below which a photo is blurry (default: 100).\n"
        "\n"
        "Options (organize):\n"
        "  --under=<path>        Folder to organize (required).\n"
        "  --dest=<path>         Where the kind folders go (default: the --under folder).\n"
        "  --by=content|place    Group photos by Vision category or by country/city\n"
        "                        (place sends grid-cell coordinates to Apple; default: content).\n"
        "  --apply               Actually move the files.\n"
        "  --yes                 Skip the confirmation prompt.\n"
        "\n"
        "Options (malware):\n"
        "  --path=<path>         Folder to scan, repeatable (default: ~/Downloads, ~/Desktop,\n"
        "                        ~/Applications, /Applications). Launchd plists are always checked.\n"
        "  --trash               Move Detected and Suspicious files to the Trash after a prompt.\n"
        "  --yes                 Skip the confirmation prompt.\n"
        "Options (updates):\n"
        "  --upgrade <name>...   Upgrade these outdated Homebrew items, one at a time.\n"
        "                        Other sources are updated from the App Store, the app\n"
        "                        itself, or Terminal (sudo port upgrade <name>).\n"
        "\n"
        "  --help                 Show this message.\n";
}

std::optional<CliOptions> parseArgs(int argc, char** argv, CliParseError& error) {
    CliOptions options;

    std::vector<std::string_view> args(argv + (argc > 0 ? 1 : 0), argv + argc);

    std::size_t index = 0;
    if (!args.empty() && args[0] == "check-update") {
        if (args.size() > 1 && args[1] != "--help" && args[1] != "-h") {
            error.message = "check-update takes no arguments";
            return std::nullopt;
        }
        options.command = args.size() > 1 ? Command::Help : Command::CheckUpdate;
        return options;
    }
    if (!args.empty() && (args[0] == "scan" || args[0] == "clean" || args[0] == "bigfiles" ||
                          args[0] == "processes" || args[0] == "optimize" || args[0] == "photos" ||
                          args[0] == "organize" || args[0] == "malware" || args[0] == "updates" ||
                          args[0] == "uninstall")) {
        options.command = (args[0] == "scan")       ? Command::Scan
                          : (args[0] == "clean")     ? Command::Clean
                          : (args[0] == "bigfiles")  ? Command::BigFiles
                          : (args[0] == "processes") ? Command::Processes
                          : (args[0] == "photos")    ? Command::Photos
                          : (args[0] == "organize")  ? Command::Organize
                          : (args[0] == "malware")   ? Command::Malware
                          : (args[0] == "updates")   ? Command::Updates
                          : (args[0] == "uninstall") ? Command::Uninstall
                                                      : Command::Optimize;
        index = 1;
    }

    for (; index < args.size(); ++index) {
        const std::string_view arg = args[index];

        if (arg == "--help" || arg == "-h") {
            options.command = Command::Help;
            return options;
        } else if (arg == "--version") {
            options.command = Command::Version;
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
        } else if (arg == "--trash") {
            options.apply = true;
        } else if (arg.rfind("--path=", 0) == 0) {
            options.paths.emplace_back(arg.substr(std::string_view("--path=").size()));
            if (options.paths.back().empty()) {
                error.message = "--path needs a path";
                return std::nullopt;
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
        } else if (arg.rfind("--distance=", 0) == 0) {
            const std::string spec(arg.substr(std::string_view("--distance=").size()));
            char* end = nullptr;
            const long parsed = std::strtol(spec.c_str(), &end, 10);
            if (end == spec.c_str() || *end != '\0' || parsed < 0 || parsed > 64) {
                error.message = "--distance needs an integer from 0 to 64";
                return std::nullopt;
            }
            options.distance = static_cast<int>(parsed);
        } else if (arg.rfind("--blur=", 0) == 0) {
            const std::string spec(arg.substr(std::string_view("--blur=").size()));
            char* end = nullptr;
            const double parsed = std::strtod(spec.c_str(), &end);
            if (end == spec.c_str() || *end != '\0' || !(parsed >= 0)) {
                error.message = "--blur needs a non-negative number";
                return std::nullopt;
            }
            options.blurThreshold = parsed;
        } else if (arg.rfind("--dest=", 0) == 0) {
            options.dest = std::string(arg.substr(std::string_view("--dest=").size()));
        } else if (arg == "--upgrade") {
            if (options.command != Command::Updates) {
                error.message = "--upgrade only works with the updates command";
                return std::nullopt;
            }
            while (index + 1 < args.size() && args[index + 1].rfind("--", 0) != 0) {
                options.upgradeNames.emplace_back(args[++index]);
            }
            if (options.upgradeNames.empty()) {
                error.message = "--upgrade needs at least one name";
                return std::nullopt;
            }
        } else if (arg == "--list" && options.command == Command::Uninstall) {
            options.listApps = true;
        } else if (options.command == Command::Uninstall && arg.rfind("-", 0) != 0) {
            options.paths.emplace_back(arg);
        } else if (arg == "--by=content" || arg == "--by=place") {
            options.photoLayout = arg == "--by=place" ? organizer::PhotoLayout::Place : organizer::PhotoLayout::Content;
        } else {
            error.message = "unrecognized argument: " + std::string(arg);
            return std::nullopt;
        }
    }

    // --trash means "apply" only for malware; elsewhere it would clean or kill.
    if ((options.command != Command::Malware) &&
        std::find(args.begin(), args.end(), std::string_view("--trash")) != args.end()) {
        error.message = "--trash is only valid for the malware command";
        return std::nullopt;
    }
    if (options.command == Command::Uninstall &&
        (options.listApps ? !options.paths.empty() : options.paths.size() != 1)) {
        error.message = "uninstall needs --list, or exactly one <name|bundle-id|path>";
        return std::nullopt;
    }
    if (options.command == Command::Organize && options.under.empty()) {
        error.message = "organize needs --under=<folder>";
        return std::nullopt;
    }

    if (options.permanent && !options.apply) {
        error.message = "--permanent requires --apply";
        return std::nullopt;
    }

    return options;
}

} // namespace maccleaner
