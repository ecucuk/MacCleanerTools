#include "maccleaner/uninstaller.hpp"

#import <Foundation/Foundation.h>
#include <Security/Security.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdlib>
#include <filesystem>


namespace maccleaner::uninstaller {

namespace {

std::string stringValue(CFBundleRef bundle, CFStringRef key) {
    CFTypeRef value = CFBundleGetValueForInfoDictionaryKey(bundle, key);
    if (value == nullptr || CFGetTypeID(value) != CFStringGetTypeID()) return {};
    NSString* s = (__bridge NSString*)value;
    return s.UTF8String ? s.UTF8String : "";
}

std::string cfString(CFTypeRef v) {
    if (v == nullptr || CFGetTypeID(v) != CFStringGetTypeID()) return {};
    NSString* s = (__bridge NSString*)v;
    return s.UTF8String ? s.UTF8String : "";
}

std::string utf8(id s) {
    const char* c = [s UTF8String];
    return c != nullptr ? c : "";
}

} // namespace

Environment defaultEnvironment() {
    Environment env;
    const char* home = std::getenv("HOME");
    env.home = home != nullptr ? home : "";
    env.appFolders = {"/Applications"};
    if (!env.home.empty()) env.appFolders.push_back(env.home + "/Applications");

    env.readApp = [](const std::string& appPath) -> std::optional<AppInfo> {
        @autoreleasepool {
            NSURL* url = [NSURL fileURLWithPath:@(appPath.c_str()) isDirectory:YES];
            CFBundleRef bundle = CFBundleCreate(kCFAllocatorDefault, (__bridge CFURLRef)url);
            if (bundle == nullptr) return std::nullopt;
            AppInfo info;
            info.path = appPath;
            info.bundleId = stringValue(bundle, kCFBundleIdentifierKey);
            info.name = stringValue(bundle, kCFBundleNameKey);
            info.version = stringValue(bundle, CFSTR("CFBundleShortVersionString"));
            CFRelease(bundle);
            if (info.name.empty()) info.name = std::filesystem::path(appPath).stem().string();

            SecStaticCodeRef code = nullptr;
            if (SecStaticCodeCreateWithPath((__bridge CFURLRef)url, kSecCSDefaultFlags, &code) == errSecSuccess) {
                CFDictionaryRef sig = nullptr;
                if (SecCodeCopySigningInformation(code, kSecCSSigningInformation, &sig) == errSecSuccess && sig) {
                    info.teamId = cfString(CFDictionaryGetValue(sig, kSecCodeInfoTeamIdentifier));
                    CFTypeRef ents = CFDictionaryGetValue(sig, kSecCodeInfoEntitlementsDict);
                    if (ents != nullptr && CFGetTypeID(ents) == CFDictionaryGetTypeID()) {
                        CFTypeRef groups = CFDictionaryGetValue((CFDictionaryRef)ents,
                                                                CFSTR("com.apple.security.application-groups"));
                        if (groups != nullptr && CFGetTypeID(groups) == CFArrayGetTypeID()) {
                            for (id g in (__bridge NSArray*)groups)
                                if ([g isKindOfClass:NSString.class]) info.appGroups.push_back(utf8(g));
                        }
                    }
                    CFRelease(sig);
                }
                SecRequirementRef req = nullptr;
                if (SecRequirementCreateWithString(CFSTR("anchor apple"), kSecCSDefaultFlags, &req) == errSecSuccess) {
                    info.appleSigned = SecStaticCodeCheckValidity(code, kSecCSDoNotValidateResources, req) == errSecSuccess;
                    CFRelease(req);
                }
                CFRelease(code);
            }
            return info;
        }
    };

    env.ownedByUser = [](const std::string& path) {
        struct stat st {};
        return ::lstat(path.c_str(), &st) == 0 && st.st_uid == ::geteuid();
    };

    env.readLaunchAgent = [](const std::string& plistPath) -> std::optional<LaunchAgentInfo> {
        @autoreleasepool {
            NSData* data = [NSData dataWithContentsOfFile:@(plistPath.c_str())];
            if (data == nil) return std::nullopt;
            id obj = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable
                                                                format:nullptr error:nil];
            if (![obj isKindOfClass:NSDictionary.class]) return std::nullopt;
            NSDictionary* d = obj;
            LaunchAgentInfo info;
            if ([d[@"Label"] isKindOfClass:NSString.class]) info.label = utf8(d[@"Label"]);
            if ([d[@"Program"] isKindOfClass:NSString.class]) {
                info.program = utf8(d[@"Program"]);
            } else if ([d[@"ProgramArguments"] isKindOfClass:NSArray.class]) {
                NSArray* a = d[@"ProgramArguments"];
                if (a.count > 0 && [a[0] isKindOfClass:NSString.class]) info.program = utf8(a[0]);
            }
            return info;
        }
    };
    return env;
}

} // namespace maccleaner::uninstaller
