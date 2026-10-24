import Foundation
import Testing

@testable import Lingrove

@Suite @MainActor struct LearningReadingSettingsTests {
    @Test func appPoliciesAndBindingsSurviveReloadWithoutBroadeningLegacyPermissions() throws {
        let suite = "reading-settings-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        settings.updatePerAppTranslationPolicy(bundleIdentifier: "test.allowed", displayName: "Allowed") {
            $0.selectionTranslationAllowed = true
            $0.pointerTranslationAllowed = true
            $0.screenshotTranslationAllowed = true
        }
        settings.updatePerAppTranslationPolicy(bundleIdentifier: "test.legacy", displayName: "Legacy") {
            $0.selectionTranslationAllowed = true
        }
        settings.languageLearning.pointerTranslationEnabled = true
        settings.languageLearning.screenshotTranslationEnabled = true
        settings.languageLearning.setReadingBinding(.pointer, key: 1, modifiers: [.control, .option], label: "⌃⌥S")
        let restored = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        for source in LearningReadingSource.allCases { #expect(restored.readingTranslationAllowed(source, in: "test.allowed")) }
        #expect(restored.selectionTranslationAllowed(in: "test.legacy"))
        #expect(!restored.readingTranslationAllowed(.pointer, in: "test.legacy"))
        #expect(!restored.readingTranslationAllowed(.screenshot, in: "test.legacy"))
        #expect(restored.languageLearning.pointerTranslationEnabled && restored.languageLearning.screenshotTranslationEnabled)
        #expect(restored.languageLearning.readingBinding(.pointer).key == 1)
        #expect(restored.languageLearning.readingBinding(.pointer).modifiers == [.control, .option])
    }
    @Test func newSourcePermissionsMarkAppRowsAsCustomized() throws {
        let row = PerAppShortcutOverride(bundleIdentifier: "test.app", displayName: "Test", pointerTranslationAllowed: true)
        let entries = AppSettingsList.entries(inputCounts: [:], disabledRules: [], overrides: [row], excludedFromHistory: [], displayName: { $0 })
        #expect(try #require(entries.first).hasOverrides)
    }

    @Test func ocrPerformanceRecordsRemainSeparateAndContentFree() throws {
        let suite = "reading-metrics-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PerformanceMetricsStore(userDefaults: defaults)
        store.record(
            modelName: "Apple Vision", latencyMs: 120, source: .ocr, requestID: "test-trace", firstOutputMs: 20, usableResultMs: 120)
        let record = try #require(PerformanceMetricsStore(userDefaults: defaults).entries.first)
        #expect(record.source == .ocr && record.firstOutputMs == 20 && record.usableResultMs == 120)
        #expect(record.requestID == "test-trace")
    }
}
