#pragma once

#include <filesystem>
#include <string>

namespace maccleaner::trash {

// Moves `path` to the user's Trash.
//
// When built with MACCLEANER_NATIVE_TRASH (macOS + MACCLEANER_USE_NATIVE_TRASH),
// this is implemented in src/platform/trash_mac.mm via
// [NSFileManager trashItemAtURL:resultingItemURL:error:] -- the same API
// Finder's "Move to Trash" uses, so items are recoverable and Finder shows
// the origin path. Otherwise (src/platform/trash_fallback.cpp) this falls
// back to std::filesystem::remove_all, which is a *permanent* delete; that
// fallback exists for non-Apple development/CI builds only.
//
// Returns true on success. On failure returns false and sets `error`.
bool moveToTrash(const std::filesystem::path& path, std::string& error);

// True if this build uses the native NSFileManager trash implementation.
bool isNativeImplementation();

} // namespace maccleaner::trash
