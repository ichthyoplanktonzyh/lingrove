import XCTest
@testable import Cotabby

/// Pins the hygiene rules of the Settings search index. The index drifts silently when a new
/// setting ships without an entry (it simply never appears in search), so these tests make the
/// cheap invariants loud: every item must carry a non-empty title, symbol, and keyword set, and
/// the queries users actually type for recently shipped settings must land on them.
final class SettingsIndexTests: XCTestCase {
    func test_completionSwitchIsSearchableInWriting() {
        for query in ["启用补全", "关闭补全", "autocomplete"] {
            XCTAssertTrue(SettingsItem.results(for: query).contains(.completionEnabled))
        }
        XCTAssertEqual(SettingsItem.completionEnabled.category, .writing)
    }

    func test_everyItemHasTitleSymbolKeywordsAndSummary() {
        for item in SettingsItem.allCases {
            XCTAssertFalse(item.title.isEmpty, "\(item) needs a title")
            XCTAssertFalse(item.systemImage.isEmpty, "\(item) needs an SF Symbol")
            XCTAssertFalse(item.keywords.isEmpty, "\(item) needs search keywords")
            XCTAssertFalse(item.summary.isEmpty, "\(item) needs a one-line summary for search results")
        }
    }

    func test_selectionTranslationSearchFindsBehaviorAndShortcut() {
        XCTAssertTrue(SettingsItem.results(for: "划词").contains(.selectionTranslation))
        XCTAssertTrue(SettingsItem.results(for: "白名单").contains(.selectionTranslationApps))
        XCTAssertEqual(SettingsItem.selectionTranslationShortcut.category, .shortcuts)
    }

    func test_ghostSearchIncludesHostSizeMatching() {
        XCTAssertTrue(SettingsItem.results(for: "ghost").contains(.matchHostTextSize))
    }

    func test_perAppPolicyQueriesLandOnTheUnifiedAppsPane() {
        for query in ["app settings", "per app", "mid-line", "collected inputs"] {
            XCTAssertTrue(SettingsItem.results(for: query).contains(.disabledApps), query)
        }
    }

    func test_sidebarGroupsCoverEveryCategoryExactlyOnce() {
        // The sidebar renders from `sidebarGroups`, not `allCases`, so a category missing from the
        // groups would silently disappear from the window. Order is pinned too: the flattened
        // groups must read in the same top-down sequence the enum declares.
        let flattened = SettingsCategory.sidebarGroups.flatMap { $0 }
        XCTAssertEqual(flattened, SettingsCategory.allCases,
                       "sidebar groups must list every category exactly once, in declaration order")
    }

    func test_everyPaneExceptHomeIsReachableFromSearch() {
        // Home is the search surface itself; every other pane must own at least one indexed row,
        // or search can never land on it.
        let searchableCategories = Set(SettingsItem.allCases.map(\.category))
        for category in SettingsCategory.allCases where category != .home {
            XCTAssertTrue(searchableCategories.contains(category), "\(category) has no SettingsItem entries")
        }
        XCTAssertFalse(searchableCategories.contains(.home), "Home hosts search and should not index rows")
    }

    func test_typingAnItemsExactTitleRanksThatItemFirst() {
        // The ranker's exact-title bonus exists so a row's own name always wins. Running it over the
        // real catalog catches a new title that collides with (or is shadowed by) another item.
        for item in SettingsItem.allCases {
            XCTAssertEqual(
                SettingsItem.results(for: item.title).first,
                item,
                "searching \"\(item.title)\" should rank \(item) first"
            )
        }
    }

    func test_searchFindsRecentlyShippedSettings() {
        // Each pair pins one real query for a setting that previously shipped without an index
        // entry. If one of these fails, a rename or removal broke search for that setting.
        let expectations: [(query: String, item: SettingsItem)] = [
            ("ghost text size", .ghostTextSize),
            ("predict ahead", .predictAheadWhileTyping),
            ("background", .predictAheadWhileTyping),
            ("mid word", .suggestWithinWords),
            ("word boundary", .suggestWithinWords),
            ("next words", .showFollowingWords),
            ("one word", .showFollowingWords),
            ("smallest ghost text", .ghostTextSizeFloor),
            ("largest ghost text", .ghostTextSizeCeiling),
            ("terminal", .suggestInIntegratedTerminals),
            ("vscode", .suggestInIntegratedTerminals),
            ("typo", .automaticallyFixTypos),
            ("model status", .modelStatus),
            ("battery", .batteryModel),
            ("plugged", .pluggedInModel),
            ("unsupported language", .appleLanguageFallback),
            ("fallback model", .appleLanguageFallbackModel),
            ("keep loaded", .keepFallbackModelLoaded),
            ("preload", .keepFallbackModelLoaded),
            ("interface language", .interfaceLanguage),
            ("localization", .interfaceLanguage)
        ]
        XCTAssertEqual(SettingsItem.interfaceLanguage.category, .general)
        for expectation in expectations {
            XCTAssertTrue(
                SettingsItem.results(for: expectation.query).contains(expectation.item),
                "query \"\(expectation.query)\" should surface \(expectation.item)"
            )
        }
    }

    func test_ttsAndReadAloudSettingsAreSearchable() {
        XCTAssertTrue(SettingsItem.results(for: "tts").contains(.speechProvider))
        XCTAssertTrue(SettingsItem.results(for: "voice language").contains(.speechLanguage))
        XCTAssertTrue(SettingsItem.results(for: "test voice").contains(.speechVoice))
        XCTAssertTrue(SettingsItem.results(for: "audio decoder").contains(.speechDecoder))
        XCTAssertTrue(SettingsItem.results(for: "speech api key").contains(.speechEndpoint))
        XCTAssertTrue(SettingsItem.results(for: "voice identifier").contains(.speechEndpointVoice))
        XCTAssertTrue(SettingsItem.results(for: "speech server model").contains(.speechEndpointModel))
        XCTAssertTrue(SettingsItem.results(for: "read aloud speed").contains(.readAloudSpeed))
        XCTAssertTrue(SettingsItem.results(for: "朗读").contains(.readAloudSpeed))
    }

    func test_blankQueryReturnsNothing() {
        for query in ["", "   ", "\n\t"] {
            XCTAssertEqual(SettingsItem.results(for: query), [], "query \(query.debugDescription)")
        }
    }

    func test_translationBehaviorAndModelsHaveSearchableSeparateHomes() {
        let behavior: [SettingsItem] = [.translationEnabled, .sentencePreview, .translationTargetLanguage,
            .translationSourceLanguages, .translationReferenceMode]
        for item in behavior { XCTAssertEqual(item.category, .languageLearning) }
        XCTAssertEqual(SettingsItem.translationModel.category, .engineAndModel)
        for (query, item) in [("translation reference", SettingsItem.translationReferenceMode),
                              ("source languages", .translationSourceLanguages),
                              ("translation model", .translationModel)] {
            XCTAssertTrue(SettingsItem.results(for: query).contains(item), query)
        }
        XCTAssertEqual(SettingsItem.languages.category, .writing,
            "Autocomplete language preference keeps its original search destination")
    }

    #if DEBUG
    func test_debugOverlaySettingIsSearchableInDevelopmentBuilds() {
        XCTAssertTrue(SettingsItem.results(for: "debug overlays").contains(.developmentDebugOverlays))
        XCTAssertEqual(SettingsItem.developmentDebugOverlays.category, .general)
    }
    #endif
}
