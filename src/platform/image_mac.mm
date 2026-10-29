// ImageIO decoder for the photo folder scan. ImageIO reads every format the
// system does (JPEG, HEIF, PNG, TIFF, WebP, camera RAW) and can produce a
// downscaled, orientation-corrected thumbnail without decoding the full
// image, which keeps a scan of thousands of 12 MP photos fast. The file
// also tells the scan whether a folder sits on solid-state storage.

#include "image_mac.h"

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/storage/IOStorageDeviceCharacteristics.h>
#import <ImageIO/ImageIO.h>

#include <stdio.h> // renamex_np
#include <sys/mount.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>
#include <ctime>

namespace maccleaner::photos {

namespace {

// EXIF dates are "YYYY:MM:DD HH:MM:SS" in the camera's local time, with no
// zone; interpreting them in the Mac's zone is what Photos does too.
std::int64_t parseExifDate(NSString *text) {
    if (text == nil) {
        return 0;
    }
    struct tm parts {};
    if (::strptime(text.UTF8String, "%Y:%m:%d %H:%M:%S", &parts) == nullptr) {
        return 0;
    }
    parts.tm_isdst = -1;
    const std::time_t seconds = ::mktime(&parts);
    return seconds == -1 ? 0 : static_cast<std::int64_t>(seconds);
}

} // namespace

bool grayFromCGImage(CGImageRef image, GrayImage& out) {
    const std::size_t width = CGImageGetWidth(image);
    const std::size_t height = CGImageGetHeight(image);
    if (width == 0 || height == 0) {
        return false;
    }
    out.width = static_cast<int>(width);
    out.height = static_cast<int>(height);
    out.pixels.assign(width * height, 0);

    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(out.pixels.data(), width, height, 8, width, gray,
                                                 static_cast<CGBitmapInfo>(kCGImageAlphaNone));
    CGColorSpaceRelease(gray);
    if (context == nullptr) {
        return false;
    }
    CGContextDrawImage(context, CGRectMake(0, 0, static_cast<CGFloat>(width), static_cast<CGFloat>(height)), image);
    CGContextRelease(context);
    return true;
}

bool decodeImageFile(const std::filesystem::path& path, Decoded& out) {
    @autoreleasepool {
        // From raw bytes, not NSString: a non-UTF-8 name (possible on SMB or
        // exFAT) makes stringWithUTF8String return nil and fileURLWithPath throw.
        const std::string& raw = path.native();
        NSURL *url = CFBridgingRelease(CFURLCreateFromFileSystemRepresentation(
            kCFAllocatorDefault, reinterpret_cast<const UInt8 *>(raw.data()), static_cast<CFIndex>(raw.size()),
            false));
        if (url == nil) {
            return false;
        }
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
        if (source == nullptr) {
            return false;
        }

        NSDictionary *properties =
            CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr));
        out.pixelWidth = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] intValue];
        out.pixelHeight = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] intValue];
        NSDictionary *exif = properties[(__bridge NSString *)kCGImagePropertyExifDictionary];
        out.createdUnix = parseExifDate(exif[(__bridge NSString *)kCGImagePropertyExifDateTimeOriginal]);

        NSDictionary *options = @{
            (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
            (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform : @YES,
            (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize : @(kDecodeMaxPixels),
        };
        CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
        CFRelease(source);
        if (thumbnail == nullptr) {
            return false;
        }
        const bool ok = grayFromCGImage(thumbnail, out.gray);
        CGImageRelease(thumbnail);
        return ok;
    }
}

bool isSolidStateVolume(const std::filesystem::path& path) {
    struct statfs fs {};
    if (::statfs(path.c_str(), &fs) != 0 || std::strncmp(fs.f_mntfromname, "/dev/", 5) != 0) {
        return false;
    }
    io_service_t media =
        IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, fs.f_mntfromname + 5));
    if (media == IO_OBJECT_NULL) {
        return false;
    }
    // The characteristics sit on the physical device, above the partition
    // (and, for APFS, above the container) in the registry.
    NSDictionary *characteristics = CFBridgingRelease(IORegistryEntrySearchCFProperty(
        media, kIOServicePlane, CFSTR(kIOPropertyDeviceCharacteristicsKey), kCFAllocatorDefault,
        kIORegistryIterateRecursively | kIORegistryIterateParents));
    IOObjectRelease(media);
    return [characteristics isKindOfClass:[NSDictionary class]] &&
           [characteristics[@kIOPropertyMediumTypeKey] isEqual:@kIOPropertyMediumTypeSolidStateKey];
}

bool writeHeicCopy(const std::filesystem::path& source, const std::filesystem::path& destination, double quality,
                   std::string& error) {
    @autoreleasepool {
        auto urlFor = [](const std::filesystem::path& path) -> NSURL * {
            const std::string& raw = path.native();
            return CFBridgingRelease(CFURLCreateFromFileSystemRepresentation(
                kCFAllocatorDefault, reinterpret_cast<const UInt8 *>(raw.data()), static_cast<CFIndex>(raw.size()),
                false));
        };
        // Encode next to the destination, then rename without replacing, so a
        // crash or a full disk never leaves a half-written photo behind.
        std::filesystem::path partial = destination;
        partial += ".part";
        NSURL *sourceURL = urlFor(source);
        NSURL *partialURL = urlFor(partial);
        CGImageSourceRef input = sourceURL != nil ? CGImageSourceCreateWithURL((__bridge CFURLRef)sourceURL, nullptr)
                                                  : nullptr;
        if (input == nullptr || CGImageSourceGetCount(input) == 0 || partialURL == nil) {
            if (input != nullptr) {
                CFRelease(input);
            }
            error = "cannot read the image";
            return false;
        }
        CGImageDestinationRef output = CGImageDestinationCreateWithURL(
            (__bridge CFURLRef)partialURL, CFSTR("public.heic"), 1, nullptr);
        bool ok = output != nullptr;
        if (ok) {
            // From the source, not a decoded CGImage: metadata and orientation carry over.
            NSDictionary *options = @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @(quality)};
            CGImageDestinationAddImageFromSource(output, input, 0, (__bridge CFDictionaryRef)options);
            ok = CGImageDestinationFinalize(output);
            CFRelease(output);
        }
        CFRelease(input);

        if (ok) {
            CGImageSourceRef check = CGImageSourceCreateWithURL((__bridge CFURLRef)partialURL, nullptr);
            ok = check != nullptr && CGImageSourceGetCount(check) == 1 &&
                 CGImageSourceGetStatus(check) == kCGImageStatusComplete;
            if (check != nullptr) {
                CFRelease(check);
            }
        }
        if (!ok) {
            ::unlink(partial.c_str());
            error = "HEIC encoding failed";
            return false;
        }

        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:sourceURL.path error:nil];
        NSMutableDictionary *dates = [NSMutableDictionary dictionary];
        dates[NSFileCreationDate] = attributes[NSFileCreationDate];
        dates[NSFileModificationDate] = attributes[NSFileModificationDate];
        [NSFileManager.defaultManager setAttributes:dates ofItemAtPath:partialURL.path error:nil];
        if (::renamex_np(partial.c_str(), destination.c_str(), RENAME_EXCL) != 0) {
            error = std::strerror(errno);
            ::unlink(partial.c_str());
            return false;
        }
        return true;
    }
}

} // namespace maccleaner::photos
