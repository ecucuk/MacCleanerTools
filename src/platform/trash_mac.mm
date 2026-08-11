// Objective-C++ implementation of maccleaner::trash::moveToTrash using
// -[NSFileManager trashItemAtURL:resultingItemURL:error:] -- the same
// mechanism Finder's "Move to Trash" uses. Compiled only when
// MACCLEANER_USE_NATIVE_TRASH is on for an Apple target (see CMakeLists.txt,
// which also adds -fobjc-arc for this file, so no manual retain/release
// below).

#include "maccleaner/trash.hpp"

#import <Foundation/Foundation.h>

namespace maccleaner::trash {

bool moveToTrash(const std::filesystem::path& path, std::string& error) {
    @autoreleasepool {
        NSString* nsPath = [NSString stringWithUTF8String:path.c_str()];
        if (nsPath == nil) {
            error = "path is not valid UTF-8";
            return false;
        }

        NSURL* url = [NSURL fileURLWithPath:nsPath isDirectory:NO];
        NSError* nsError = nil;
        NSFileManager* manager = [NSFileManager defaultManager];

        const BOOL ok = [manager trashItemAtURL:url resultingItemURL:nil error:&nsError];
        if (!ok) {
            error = nsError != nil ? std::string([[nsError localizedDescription] UTF8String]) : "unknown NSFileManager error";
            return false;
        }
        return true;
    }
}

bool isNativeImplementation() {
    return true;
}

} // namespace maccleaner::trash
