#pragma once

#include <optional>
#include <string>
#include <string_view>

namespace maccleaner::selfupdate {

// MacCleaner's own update check: the latest GitHub release of this repo.
// Pure functions; the fetch lives in http.hpp.
struct Release {
    std::string version; // tag_name without a leading "v"/"V"
    std::string name;    // "name", else the tag
    std::string notes;   // "body", plain text
    std::string pageUrl; // "html_url"
};

// The JSON of GET /repos/{owner}/{repo}/releases/latest.
// nullopt if the JSON is malformed, has no tag_name, or html_url does not
// start with "https://github.com/" (the Download button opens it).
std::optional<Release> parseLatestRelease(std::string_view json);

// True if `latest` is newer than `current` (updater::compareVersions,
// after a leading "v"/"V" is removed from both).
bool isNewer(std::string_view latest, std::string_view current);

inline constexpr std::string_view kLatestReleaseUrl =
    "https://api.github.com/repos/ecucuk/MacCleanerTools/releases/latest";
inline constexpr std::string_view kIssuesUrl =
    "https://github.com/ecucuk/MacCleanerTools/issues/new";

} // namespace maccleaner::selfupdate
