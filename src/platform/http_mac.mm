#include "maccleaner/http.hpp"

#import <Foundation/Foundation.h>

namespace maccleaner::http {

std::optional<Response> get(const std::string& url,
                            const std::vector<std::pair<std::string, std::string>>& headers,
                            double timeoutSeconds) {
    @autoreleasepool {
        NSURL* nsurl = [NSURL URLWithString:[NSString stringWithUTF8String:url.c_str()]];
        if (nsurl == nil) {
            return std::nullopt;
        }
        NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:nsurl];
        request.timeoutInterval = timeoutSeconds;
        for (const auto& [name, value] : headers) {
            [request setValue:[NSString stringWithUTF8String:value.c_str()]
                forHTTPHeaderField:[NSString stringWithUTF8String:name.c_str()]];
        }

        // Ephemeral: no cookies, no credentials and no cache on disk.
        NSURLSession* session =
            [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
        __block std::optional<Response> result;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        NSURLSessionDataTask* task =
            [session dataTaskWithRequest:request
                       completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
                           if (error == nil && [response isKindOfClass:NSHTTPURLResponse.class]) {
                               Response r;
                               r.status = static_cast<int>(((NSHTTPURLResponse*)response).statusCode);
                               if (data != nil) {
                                   r.body.assign(static_cast<const char*>(data.bytes), data.length);
                               }
                               result = std::move(r);
                           }
                           dispatch_semaphore_signal(done);
                       }];
        [task resume];
        const auto waitNs = static_cast<int64_t>((timeoutSeconds + 1) * NSEC_PER_SEC);
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, waitNs)) != 0) {
            [task cancel];
            // The handler may still run after cancel; wait for it so it never
            // writes `result` after this frame is gone.
            dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
            result.reset();
        }
        [session finishTasksAndInvalidate];
        return result;
    }
}

} // namespace maccleaner::http
