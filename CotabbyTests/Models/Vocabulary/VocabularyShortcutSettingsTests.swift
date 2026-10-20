import CoreGraphics
import Foundation
import Testing
@testable import Cotabby

@MainActor
struct VocabularyShortcutSettingsTests {
    @Test func bindingsStartDisabledAndSurviveRestartAndReset() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = VocabularyShortcutSettings(defaults: defaults)
        #expect(settings.binding(.save).key == .max)
        #expect(settings.binding(.open).key == .max)
        settings.set(.save, key: 3, modifiers: [.control, .option], label: "⌃⌥F")
        let second = VocabularyShortcutSettings(defaults: defaults)
        #expect(second.command(key: 3, modifiers: [.control, .option]) == .save)
        second.reset()
        #expect(VocabularyShortcutSettings(defaults: defaults).binding(.save).key == .max)
    }

    @Test func vocabularyConflictIsSymmetricWithTranslationAndCompletion() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        #expect(model.vocabularyShortcutConflict(.save, key: UInt16(model.acceptanceKeyCode),
            modifiers: model.acceptanceKeyModifiers) != nil)
        model.vocabularyShortcuts.set(.save, key: 3, modifiers: [.control, .option], label: "⌃⌥F")
        #expect(model.conflictingShortcutName(keyCode: 3, modifiers: [.control, .option], excluding: .acceptWord) != nil)
        #expect(model.learningShortcutConflict(keyCode: 3, modifiers: [.control, .option], replacement: false) != nil)
        #expect(model.vocabularyShortcutConflict(.open, key: 3, modifiers: [.control, .option]) != nil)
        #expect(model.vocabularyShortcutConflict(.save, key: 3, modifiers: [.control, .option]) == nil)
    }

    @Test func returnEscapeAndUnmodifiedKeysCannotBeBound() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        #expect(model.vocabularyShortcutConflict(.save, key: 53, modifiers: [.option]) != nil)
        #expect(model.vocabularyShortcutConflict(.save, key: 36, modifiers: [.option]) != nil)
        #expect(model.vocabularyShortcutConflict(.save, key: 3, modifiers: []) != nil)
    }
}
