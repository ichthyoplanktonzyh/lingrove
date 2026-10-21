import Foundation
import Testing
@testable import Cotabby

@MainActor
struct LearningDictionarySettingsTests {
    @Test
    func preferencesNormalizeCorruptionAndSurviveReopening() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["system", "unknown", "system"], forKey: "learningDictionarySourceOrder")
        defaults.set([], forKey: "learningDictionaryEnabledSources")
        let settings = LearningDictionarySettings(defaults: defaults)
        #expect(settings.configuration.order == [.system, .bundled, .online])
        #expect(settings.configuration.activeSources == [.bundled])
        settings.setEnabled(false, for: .bundled)
        #expect(settings.configuration.activeSources == [.bundled], "The last source cannot be disabled")
        settings.setEnabled(true, for: .system)
        settings.move(.bundled, by: -1)
        let reopened = LearningDictionarySettings(defaults: defaults)
        #expect(reopened.configuration == settings.configuration)
        #expect(reopened.configuration.activeSources == [.bundled, .system])
        reopened.setEnabled(false, for: .bundled)
        #expect(reopened.configuration.activeSources == [.system])
        reopened.reset()
        #expect(LearningDictionarySettings(defaults: defaults).configuration == .init())
    }
}
