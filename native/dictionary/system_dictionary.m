#import <Foundation/Foundation.h>
#import <CoreServices/CoreServices.h>
#import <dlfcn.h>

/// Private Dictionary Services calls live in a disposable process. The parent enforces a
/// deadline. Rich record failure falls back to public text from the same language-matched book.
// Metadata is read from the dictionary bundle rather than inferred from a localized title.
// A language-scoped query requires known matching metadata, including for homographs.
static NSString *languageCode(NSString *raw) {
    if (![raw isKindOfClass:NSString.class]) return @"";
    NSString *code = [raw stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
    if ([code hasPrefix:@"zh"]) {
        return ([code containsString:@"Hant"] || [code containsString:@"TW"] || [code containsString:@"HK"] || [code containsString:@"MO"]) ? @"zh-Hant" : @"zh-Hans";
    }
    return [[code componentsSeparatedByString:@"-"] firstObject] ?: @"";
}
static BOOL sameEntryLanguage(NSString *lhs, NSString *rhs) {
    return [lhs isEqual:rhs] || ([lhs hasPrefix:@"zh-"] && [rhs hasPrefix:@"zh-"]);
}

// This pure selection rule is shared with the native regression fixture. Its result contains
// only a score and gloss language, never a borrowed Dictionary Services pointer.
static NSDictionary *languageCandidate(NSArray *pairs, NSString *entryLanguage, NSString *preferred) {
    NSInteger rank = 1;
    NSString *gloss = @"";
    BOOL matches = !entryLanguage.length;
    if (entryLanguage.length && [pairs isKindOfClass:NSArray.class]) {
        rank = 3;
        for (id item in pairs) {
            if (![item isKindOfClass:NSDictionary.class]) continue;
            NSString *index = languageCode(item[@"DCSDictionaryIndexLanguage"]);
            NSString *description = languageCode(item[@"DCSDictionaryDescriptionLanguage"]);
            if (!sameEntryLanguage(index, entryLanguage)) continue;
            matches = YES;
            NSInteger score = [description isEqual:preferred] ? 0 : (description.length ? 2 : 1);
            if (score < rank) { rank = score; gloss = description; }
        }
    }
    return matches ? @{ @"rank": @(rank), @"gloss": gloss } : nil;
}

static BOOL hasReadableLanguageMetadata(NSArray *pairs) {
    if (![pairs isKindOfClass:NSArray.class]) return NO;
    for (id item in pairs) {
        if ([item isKindOfClass:NSDictionary.class] && languageCode(item[@"DCSDictionaryIndexLanguage"]).length) return YES;
    }
    return NO;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2 && argc != 4) return 2;
        NSString *entryLanguage = argc == 4 ? languageCode([NSString stringWithUTF8String:argv[2]]) : @"";
        NSString *preferred = argc == 4 ? languageCode([NSString stringWithUTF8String:argv[3]]) : @"";
        NSString *query = [NSString stringWithUTF8String:argv[1]];
        if (!query.length || [query lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 256) return 2;
        CFRange term = CFRangeMake(0, query.length);
        void *framework = dlopen("/System/Library/Frameworks/CoreServices.framework/Frameworks/DictionaryServices.framework/DictionaryServices", RTLD_LAZY | RTLD_LOCAL);
        if (!framework) return 3;
        CFArrayRef (*active)(void) = dlsym(framework, "DCSGetActiveDictionaries");
        CFArrayRef (*records)(CFTypeRef, CFStringRef, unsigned long long, long long) = dlsym(framework, "DCSCopyRecordsForSearchString");
        CFStringRef (*data)(CFTypeRef, long) = dlsym(framework, "DCSRecordCopyData");
        CFStringRef (*name)(CFTypeRef) = dlsym(framework, "DCSDictionaryGetName");
        CFURLRef (*url)(CFTypeRef) = dlsym(framework, "DCSDictionaryGetURL");
        if (!active || (argc == 4 && !url)) return 3;
        // Get is borrowed. Calling this undocumented function twice has crashed on some OS
        // releases; one query and one call per process avoid retaining that mutable global state.
        CFArrayRef dictionaries = active();
        NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
        BOOL readableMetadata = NO;
        for (CFIndex i = 0; dictionaries && i < MIN(CFArrayGetCount(dictionaries), 32); i++) {
            CFTypeRef dictionary = CFArrayGetValueAtIndex(dictionaries, i);
            NSURL *location = url ? (__bridge NSURL *)url(dictionary) : nil;
            NSDictionary *info = location ? [NSBundle bundleWithURL:location].infoDictionary : nil;
            NSArray *pairs = info[@"DCSDictionaryLanguages"];
            if (hasReadableLanguageMetadata(pairs)) readableMetadata = YES;
            NSDictionary *match = languageCandidate(pairs, entryLanguage, preferred);
            if (match) [candidates addObject:@{ @"index": @(i), @"rank": match[@"rank"], @"gloss": match[@"gloss"] }];
        }
        if (entryLanguage.length && dictionaries && CFArrayGetCount(dictionaries) && !readableMetadata) return 3;
        // Stable ties preserve the user's enabled macOS order.
        [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *lhs, NSDictionary *rhs) {
            NSComparisonResult order = [lhs[@"rank"] compare:rhs[@"rank"]];
            return order == NSOrderedSame ? [lhs[@"index"] compare:rhs[@"index"]] : order;
        }];
        for (NSDictionary *candidate in candidates) {
            CFTypeRef dictionary = CFArrayGetValueAtIndex(dictionaries, [candidate[@"index"] longValue]);
            CFRange detected = DCSGetTermRangeInString((DCSDictionaryRef)dictionary, (__bridge CFStringRef)query, 0);
            if (detected.location != 0 || detected.length != term.length) continue;
            CFArrayRef hits = records && data ? records(dictionary, (__bridge CFStringRef)query, 0, 2) : NULL;
            NSDictionary *result = nil;
            for (CFIndex j = 0; hits && j < MIN(CFArrayGetCount(hits), 3); j++) {
                CFTypeRef hit = CFArrayGetValueAtIndex(hits, j);
                // Copy returns retained strings. ARC takes exactly one ownership transfer.
                NSString *html = CFBridgingRelease(data(hit, 2));
                NSString *text = CFBridgingRelease(data(hit, 3));
                if ((!html.length && !text.length) || [html lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 1000000 ||
                    [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 64000) continue;
                NSString *source = name ? (__bridge NSString *)name(dictionary) : nil;
                result = @{ @"html": html ?: @"", @"text": text ?: @"", @"sourceName": source ?: @"macOS Dictionary",
                            @"entryLanguage": entryLanguage, @"definitionLanguage": candidate[@"gloss"] };
                break;
            }
            if (hits) CFRelease(hits);
            if (!result) {
                // Public plain text still targets this same language-matched dictionary.
                // Never use NULL here: that would reintroduce another language's homograph.
                CFStringRef copied = DCSCopyTextDefinition((DCSDictionaryRef)dictionary, (__bridge CFStringRef)query, term);
                NSString *text = CFBridgingRelease(copied);
                if (text.length && [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= 64000) {
                    NSString *source = name ? (__bridge NSString *)name(dictionary) : nil;
                    result = @{ @"html": @"", @"text": text, @"sourceName": source ?: @"macOS Dictionary",
                                @"entryLanguage": entryLanguage, @"definitionLanguage": candidate[@"gloss"] };
                }
            }
            if (result) {
                NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
                if (json.length <= 2000000) [[NSFileHandle fileHandleWithStandardOutput] writeData:json];
                return 0;
            }
        }
        // A successful miss is distinct from an unavailable helper. The router must not query
        // the unfiltered public default and accidentally return a different language's homograph.
        if (argc == 4) {
            NSData *miss = [NSJSONSerialization dataWithJSONObject:@{ @"html": @"", @"text": @"", @"sourceName": @"" } options:0 error:nil];
            [[NSFileHandle fileHandleWithStandardOutput] writeData:miss];
        }
    }
    return 0;
}
