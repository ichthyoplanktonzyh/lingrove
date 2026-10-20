#import <Foundation/Foundation.h>
#import <CoreServices/CoreServices.h>
#import <dlfcn.h>

/// Private Dictionary Services calls live in a disposable process. The parent enforces a
/// deadline and falls back to the public text API if an OS update changes this undocumented ABI.
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSString *query = [NSString stringWithUTF8String:argv[1]];
        if (!query.length || [query lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 256) return 2;
        CFRange term = DCSGetTermRangeInString(NULL, (__bridge CFStringRef)query, 0);
        if (term.location != 0 || term.length != query.length) return 0;
        void *framework = dlopen("/System/Library/Frameworks/CoreServices.framework/Frameworks/DictionaryServices.framework/DictionaryServices", RTLD_LAZY | RTLD_LOCAL);
        if (!framework) return 3;
        CFArrayRef (*active)(void) = dlsym(framework, "DCSGetActiveDictionaries");
        CFArrayRef (*records)(CFTypeRef, CFStringRef, unsigned long long, long long) = dlsym(framework, "DCSCopyRecordsForSearchString");
        CFStringRef (*data)(CFTypeRef, long) = dlsym(framework, "DCSRecordCopyData");
        CFStringRef (*name)(CFTypeRef) = dlsym(framework, "DCSDictionaryGetName");
        if (!active || !records || !data) return 3;
        // Get is borrowed. Calling this undocumented function twice has crashed on some OS
        // releases; one query and one call per process avoid retaining that mutable global state.
        CFArrayRef dictionaries = active();
        for (CFIndex i = 0; dictionaries && i < MIN(CFArrayGetCount(dictionaries), 32); i++) {
            CFTypeRef dictionary = CFArrayGetValueAtIndex(dictionaries, i);
            CFArrayRef hits = records(dictionary, (__bridge CFStringRef)query, 0, 2);
            if (!hits) continue;
            NSDictionary *result = nil;
            for (CFIndex j = 0; j < MIN(CFArrayGetCount(hits), 3); j++) {
                CFTypeRef hit = CFArrayGetValueAtIndex(hits, j);
                // Copy returns retained strings. ARC takes exactly one ownership transfer.
                NSString *html = CFBridgingRelease(data(hit, 2));
                NSString *text = CFBridgingRelease(data(hit, 3));
                if (!html.length || [html lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 1000000 ||
                    [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 64000) continue;
                NSString *source = name ? (__bridge NSString *)name(dictionary) : nil;
                result = @{ @"html": html, @"text": text ?: @"", @"sourceName": source ?: @"macOS Dictionary" };
                break;
            }
            CFRelease(hits);
            if (result) {
                NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
                if (json.length <= 2000000) [[NSFileHandle fileHandleWithStandardOutput] writeData:json];
                return 0;
            }
        }
    }
    return 0;
}
