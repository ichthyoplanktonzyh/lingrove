import Foundation
import Testing
@testable import Lingrove

/// Verifies isolated persistence for speech preferences, separate from translation/model settings.
@Suite
@MainActor
struct LearningSpeechSettingsTests {
    @Test
    func systemProviderAndNormalRateAreTheOnlyDefaults() throws {
        let (name, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let settings = LearningSpeechSettings(defaults: defaults)

        #expect(settings.selectedProvider == .system)
        #expect(settings.rateMultiplier == 1.0)
        #expect(settings.voiceIDs.isEmpty)
    }

    @Test(arguments: [(0.1, 0.5), (0.85, 0.85), (3.0, 1.5), (.nan, 1.0)])
    func rateIsClampedAndPersisted(_ value: Double, _ expected: Double) throws {
        let (name, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let settings = LearningSpeechSettings(defaults: defaults)
        settings.setRateMultiplier(value)
        let restored = LearningSpeechSettings(defaults: defaults)

        #expect(settings.rateMultiplier == expected)
        #expect(restored.rateMultiplier == expected)
    }

    @Test
    func voiceChoicePersistsIndependentlyForEachLearningLanguage() throws {
        let (name, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let settings = LearningSpeechSettings(defaults: defaults)
        settings.setVoiceID("voice.es", for: .spanish)
        settings.setVoiceID("voice.zh", for: .chinese)
        let restored = LearningSpeechSettings(defaults: defaults)

        #expect(restored.voiceID(for: .spanish) == "voice.es")
        #expect(restored.voiceID(for: .chinese) == "voice.zh")
        #expect(restored.voiceID(for: .traditionalChinese) == nil)
        restored.setVoiceID(nil, for: .spanish)
        #expect(LearningSpeechSettings(defaults: defaults).voiceID(for: .spanish) == nil)
    }

    private func makeDefaults() throws -> (name: String, defaults: UserDefaults) {
        let name = "LearningSpeechSettingsTests.\(UUID().uuidString)"
        return (name, try #require(UserDefaults(suiteName: name)))
    }
}
