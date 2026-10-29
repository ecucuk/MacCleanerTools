// macOS side of the File Organizer: moving files (and, later, reading
// their metadata). Compiled with -fobjc-arc (see CMakeLists.txt).

#include "maccleaner/organizer.hpp"

#import <Foundation/Foundation.h>

#include <cerrno>
#include <cstdio>
#include <cstring>

namespace maccleaner::organizer {

bool moveFile(const std::filesystem::path& from, const std::filesystem::path& to, std::string* error) {
    @autoreleasepool {
        const auto fail = [&](std::string why) {
            if (error != nullptr) {
                *error = std::move(why);
            }
            return false;
        };
        std::error_code ec;
        std::filesystem::create_directories(to.parent_path(), ec);
        if (ec) {
            return fail("cannot create " + to.parent_path().string() + ": " + ec.message());
        }
        // Same volume: one atomic rename that refuses to replace `to`, so a
        // file that appeared after the plan was made is never overwritten.
        if (renamex_np(from.c_str(), to.c_str(), RENAME_EXCL) == 0) {
            return true;
        }
        if (errno != EXDEV) {
            return fail(errno == EEXIST ? "target already exists: " + to.string() : std::strerror(errno));
        }
        // Another volume: NSFileManager copies, then removes the source; it
        // fails when `to` exists and keeps the source when the copy fails.
        NSString* fromPath = [NSString stringWithUTF8String:from.c_str()];
        NSString* toPath = [NSString stringWithUTF8String:to.c_str()];
        if (fromPath == nil || toPath == nil) {
            return fail("path is not valid UTF-8");
        }
        NSError* nsError = nil;
        if (![[NSFileManager defaultManager] moveItemAtURL:[NSURL fileURLWithPath:fromPath]
                                                     toURL:[NSURL fileURLWithPath:toPath]
                                                     error:&nsError]) {
            return fail(nsError != nil ? nsError.localizedDescription.UTF8String : "move failed");
        }
        return true;
    }
}

} // namespace maccleaner::organizer
