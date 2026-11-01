// macOS side of the File Organizer: moving files and reading photo and
// video metadata. Compiled with -fobjc-arc (see CMakeLists.txt).

#include "maccleaner/organizer.hpp"

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <MapKit/MapKit.h>
#import <Vision/Vision.h>

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <ctime>

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

namespace {

// EXIF/TIFF "YYYY:MM:DD HH:MM:SS", camera local time.
std::optional<std::time_t> parseExifDate(NSString* text) {
    std::tm tm{};
    if (text == nil || strptime(text.UTF8String, "%Y:%m:%d %H:%M:%S", &tm) == nullptr) {
        return std::nullopt;
    }
    tm.tm_isdst = -1;
    const std::time_t time = std::mktime(&tm);
    return time == -1 ? std::nullopt : std::optional<std::time_t>(time);
}

void readPhoto(FileMeta& meta, NSURL* url) {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
    if (source == nullptr) {
        return;
    }
    NSDictionary* properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr));
    NSDictionary* exif = properties[(__bridge NSString*)kCGImagePropertyExifDictionary];
    NSDictionary* tiff = properties[(__bridge NSString*)kCGImagePropertyTIFFDictionary];
    meta.date = parseExifDate(exif[(__bridge NSString*)kCGImagePropertyExifDateTimeOriginal]);
    if (!meta.date) {
        meta.date = parseExifDate(tiff[(__bridge NSString*)kCGImagePropertyTIFFDateTime]);
    }
    NSDictionary* gps = properties[(__bridge NSString*)kCGImagePropertyGPSDictionary];
    NSNumber* latitude = gps[(__bridge NSString*)kCGImagePropertyGPSLatitude];
    NSNumber* longitude = gps[(__bridge NSString*)kCGImagePropertyGPSLongitude];
    if ([latitude isKindOfClass:NSNumber.class] && [longitude isKindOfClass:NSNumber.class]) {
        // EXIF stores magnitudes; the hemisphere is in the Ref fields.
        const bool south = [gps[(__bridge NSString*)kCGImagePropertyGPSLatitudeRef] isEqual:@"S"];
        const bool west = [gps[(__bridge NSString*)kCGImagePropertyGPSLongitudeRef] isEqual:@"W"];
        meta.location = GeoPoint{south ? -latitude.doubleValue : latitude.doubleValue,
                                 west ? -longitude.doubleValue : longitude.doubleValue};
    }

    NSDictionary* options = @{
        (__bridge NSString*)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
        (__bridge NSString*)kCGImageSourceCreateThumbnailWithTransform : @YES,
        (__bridge NSString*)kCGImageSourceThumbnailMaxPixelSize : @512,
    };
    CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (thumbnail == nullptr) {
        return;
    }
    VNClassifyImageRequest* request = [[VNClassifyImageRequest alloc] init];
    VNImageRequestHandler* handler = [[VNImageRequestHandler alloc] initWithCGImage:thumbnail options:@{}];
    std::vector<Label> labels;
    if ([handler performRequests:@[ request ] error:nil]) {
        // ~1300 results per image, nearly all near 0; only strong ones matter.
        for (VNClassificationObservation* observation in request.results) {
            if (observation.confidence >= kMinLabelConfidence) {
                labels.push_back({observation.identifier.UTF8String, observation.confidence});
            }
        }
    }
    CGImageRelease(thumbnail);
    meta.category = categoryFromLabels(labels);
}

void readVideo(FileMeta& meta, NSURL* url) {
    AVURLAsset* asset = [AVURLAsset URLAssetWithURL:url options:nil];
    dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
    [asset loadValuesAsynchronouslyForKeys:@[ @"creationDate" ]
                         completionHandler:^{
                           dispatch_semaphore_signal(loaded);
                         }];
    dispatch_semaphore_wait(loaded, DISPATCH_TIME_FOREVER);
    if ([asset statusOfValueForKey:@"creationDate" error:nil] != AVKeyValueStatusLoaded) {
        return;
    }
    // KVC: the property getter is deprecated, but the key is loaded above.
    AVMetadataItem* item = [asset valueForKey:@"creationDate"];
    NSDate* date = item.dateValue;
    if (date != nil) {
        meta.date = static_cast<std::time_t>(date.timeIntervalSince1970);
    }
}

} // namespace

bool isPackageDirectory(const std::filesystem::path& dir) {
    @autoreleasepool {
        NSString* path = [NSString stringWithUTF8String:dir.c_str()];
        NSNumber* isPackage = nil;
        return path != nil &&
               [[NSURL fileURLWithPath:path isDirectory:YES] getResourceValue:&isPackage forKey:NSURLIsPackageKey
                                                                         error:nil] &&
               isPackage.boolValue;
    }
}

GeocodeStatus reverseGeocode(GeoPoint point, Place& place) {
    @autoreleasepool {
        CLLocation* location = [[CLLocation alloc] initWithLatitude:point.latitude longitude:point.longitude];
        __block GeocodeStatus status = GeocodeStatus::Failed;
        __block NSString* country = nil;
        __block NSString* province = nil;
        __block NSString* city = nil;
        __block bool done = false;
        dispatch_semaphore_t finished = dispatch_semaphore_create(0);
        void (^cancel)(void) = nil;
        if (@available(macOS 26.0, *)) {
            MKReverseGeocodingRequest* request = [[MKReverseGeocodingRequest alloc] initWithLocation:location];
            if (request == nil) {
                return GeocodeStatus::Failed;
            }
            cancel = ^{ [request cancel]; };
            // The completion handler runs on the main queue.
            [request getMapItemsWithCompletionHandler:^(NSArray<MKMapItem*>* items, NSError* error) {
              MKAddressRepresentations* address = items.firstObject.addressRepresentations;
              if (address != nil) {
                  country = address.regionName;
                  // Over water Apple names the country as the city.
                  city = [address.cityName isEqual:address.regionName] ? nil : address.cityName;
                  // MKAddressRepresentations has no state / il field; cityName is the
                  // district in Turkey (Kartal, not İstanbul).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                  province = items.firstObject.placemark.administrativeArea;
#pragma clang diagnostic pop
                  status = country.length > 0 ? GeocodeStatus::Found : GeocodeStatus::NotFound;
              } else if ([error.domain isEqual:MKErrorDomain] && error.code == MKErrorLoadingThrottled) {
                  status = GeocodeStatus::Throttled;
              } else if ([error.domain isEqual:MKErrorDomain] && error.code == MKErrorPlacemarkNotFound) {
                  status = GeocodeStatus::NotFound;
              }
              done = true;
              dispatch_semaphore_signal(finished);
            }];
        } else {
            // macOS 14-25: CLGeocoder, which macOS 26 deprecates for the request above.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            CLGeocoder* geocoder = [[CLGeocoder alloc] init];
            cancel = ^{ [geocoder cancelGeocode]; };
            [geocoder reverseGeocodeLocation:location
                           completionHandler:^(NSArray<CLPlacemark*>* placemarks, NSError* error) {
                             CLPlacemark* placemark = placemarks.firstObject;
                             if (placemark != nil) {
                                 country = placemark.country;
                                 province = placemark.administrativeArea;
                                 city = [placemark.locality isEqual:placemark.country] ? nil : placemark.locality;
                                 status = country.length > 0 ? GeocodeStatus::Found : GeocodeStatus::NotFound;
                             } else if ([error.domain isEqual:kCLErrorDomain] && error.code == kCLErrorNetwork) {
                                 // CLGeocoder reports its rate limit as a network error.
                                 status = GeocodeStatus::Throttled;
                             } else if ([error.domain isEqual:kCLErrorDomain] &&
                                        error.code == kCLErrorGeocodeFoundNoResult) {
                                 status = GeocodeStatus::NotFound;
                             }
                             done = true;
                             dispatch_semaphore_signal(finished);
                           }];
#pragma clang diagnostic pop
        }
        // A stalled network must not hang the scan (or its Cancel) for good.
        constexpr double kTimeoutSeconds = 30;
        bool timedOut = false;
        if (NSThread.isMainThread) {
            const CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + kTimeoutSeconds;
            while (!done && !(timedOut = CFAbsoluteTimeGetCurrent() > deadline)) {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, true);
            }
        } else {
            timedOut = dispatch_semaphore_wait(
                           finished, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kTimeoutSeconds * NSEC_PER_SEC))) != 0;
        }
        if (timedOut) {
            cancel();
            return GeocodeStatus::Failed;
        }
        place.country = country != nil ? country.UTF8String : "";
        place.province = province != nil ? province.UTF8String : "";
        place.city = city != nil ? city.UTF8String : "";
        return status;
    }
}

void readMetadata(FileMeta& meta) {
    if (meta.kind != Kind::Photos && meta.kind != Kind::Videos) {
        return;
    }
    @autoreleasepool {
        NSString* path = [NSString stringWithUTF8String:meta.path.c_str()];
        if (path == nil) {
            return;
        }
        NSURL* url = [NSURL fileURLWithPath:path];
        if (meta.kind == Kind::Photos) {
            readPhoto(meta, url);
        } else {
            readVideo(meta, url);
        }
    }
}

} // namespace maccleaner::organizer
