#include "maccleaner/selfupdate.hpp"

#include "maccleaner/json.hpp"
#include "maccleaner/updater.hpp"

namespace maccleaner::selfupdate {

namespace {

std::string_view stripV(std::string_view version) {
    if (!version.empty() && (version.front() == 'v' || version.front() == 'V')) {
        version.remove_prefix(1);
    }
    return version;
}

} // namespace

std::optional<Release> parseLatestRelease(std::string_view text) {
    const auto root = json::parse(text);
    if (!root || root->type != json::Value::Type::Object) {
        return std::nullopt;
    }
    const std::string tag = root->str("tag_name");
    Release release;
    release.version = std::string(stripV(tag));
    release.pageUrl = root->str("html_url");
    // The response chooses this URL and the GUI opens it: only GitHub pages.
    constexpr std::string_view kGitHub = "https://github.com/";
    if (release.version.empty() || release.pageUrl.rfind(kGitHub, 0) != 0) {
        return std::nullopt;
    }
    release.name = root->str("name");
    if (release.name.empty()) {
        release.name = tag;
    }
    release.notes = root->str("body");
    return release;
}

bool isNewer(std::string_view latest, std::string_view current) {
    return updater::compareVersions(stripV(latest), stripV(current)) > 0;
}

} // namespace maccleaner::selfupdate
