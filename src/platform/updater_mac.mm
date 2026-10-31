#include "maccleaner/updater.hpp"

#import <Foundation/Foundation.h>

#include <cstdlib>
#include <filesystem>
#include <unistd.h>

namespace maccleaner::updater {

namespace {

std::string stringValue(CFBundleRef bundle, CFStringRef key) {
    CFTypeRef value = CFBundleGetValueForInfoDictionaryKey(bundle, key);
    if (value == nullptr || CFGetTypeID(value) != CFStringGetTypeID()) {
        return {};
    }
    NSString* s = (__bridge NSString*)value;
    return s.UTF8String ? s.UTF8String : "";
}

std::string firstExecutable(std::initializer_list<const char*> paths) {
    for (const char* p : paths) {
        if (::access(p, X_OK) == 0) {
            return p;
        }
    }
    return {};
}

} // namespace

Environment defaultEnvironment() {
    Environment env;
    env.brewPath = firstExecutable({"/opt/homebrew/bin/brew", "/usr/local/bin/brew"});
    env.portPath = firstExecutable({"/opt/local/bin/port"});
    env.appFolders = {"/Applications"};
    if (const char* home = std::getenv("HOME")) {
        env.appFolders.push_back(std::string(home) + "/Applications");
    }
    env.readBundle = [](const std::string& appPath) -> std::optional<BundleInfo> {
        @autoreleasepool {
            NSURL* url = [NSURL fileURLWithPath:@(appPath.c_str()) isDirectory:YES];
            CFBundleRef bundle = CFBundleCreate(kCFAllocatorDefault, (__bridge CFURLRef)url);
            if (bundle == nullptr) {
                return std::nullopt;
            }
            BundleInfo info{stringValue(bundle, CFSTR("CFBundleShortVersionString")),
                            stringValue(bundle, kCFBundleVersionKey), stringValue(bundle, CFSTR("SUFeedURL"))};
            CFRelease(bundle);
            return info;
        }
    };
    env.exists = [](const std::string& path) {
        std::error_code ec;
        return std::filesystem::exists(path, ec);
    };
    NSString* region = NSLocale.currentLocale.countryCode;
    if (region.length == 2) {
        env.country = region.lowercaseString.UTF8String;
    }
    return env;
}

} // namespace maccleaner::updater
