// Import our implementation into one isolated test executable. This exercises metadata policy
// without relying on whichever dictionaries a developer has installed or enabled in macOS.
#define main lingroveDictionaryHelperMain
#import "../system_dictionary.m"
#undef main
#include <assert.h>

int main(void) {
    @autoreleasepool {
        NSArray *english = @[@{ @"DCSDictionaryIndexLanguage": @"en_US", @"DCSDictionaryDescriptionLanguage": @"en_US" }];
        NSArray *bilingual = @[@{ @"DCSDictionaryIndexLanguage": @"en", @"DCSDictionaryDescriptionLanguage": @"zh_CN" }];
        assert(hasReadableLanguageMetadata(english));
        assert(!hasReadableLanguageMetadata(nil));
        assert(!hasReadableLanguageMetadata(@[@"bad metadata", @{}, @{ @"DCSDictionaryIndexLanguage": @42 }]));
        assert(languageCandidate(english, @"fr", @"en") == nil);
        assert(languageCandidate(nil, @"fr", @"en") == nil);
        assert(languageCandidate(@[], @"en", @"en") == nil);
        assert(languageCandidate(@[@"bad metadata"], @"en", @"en") == nil);
        assert([languageCandidate(english, @"en", @"en")[@"rank"] integerValue] == 0);
        assert([languageCandidate(bilingual, @"en", @"en")[@"rank"] integerValue] == 2);
        assert([languageCandidate(bilingual, @"en", @"zh-Hans")[@"rank"] integerValue] == 0);
        assert([languageCode(@"zh_HK") isEqual:@"zh-Hant"]);
        assert([languageCode(@"zh_MO") isEqual:@"zh-Hant"]);
        assert(sameEntryLanguage(@"zh-Hans", @"zh-Hant"));
        assert(!sameEntryLanguage(@"ja", @"zh-Hans"));
    }
    return 0;
}
