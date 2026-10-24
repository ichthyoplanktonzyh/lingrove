import Foundation
import Testing
@testable import Cotabby

@MainActor
struct ExpressionAssistSettingsTests {
    @Test
    func interactionPreferencesPersistWithoutChangingTheSharedModel() throws {
        let suite = "test.expressionSettings.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let learning = LanguageLearningSettings(defaults: defaults)
        #expect(!learning.expressionAssist.enabled && learning.expressionAssist.trigger == "??")
        learning.explanation.localModel = "shared.gguf"
        let shared = learning.explanation.snapshot
        learning.expressionAssist.enabled = true
        learning.expressionAssist.trigger = ";;"
        learning.expressionAssist.keyCode = 4
        learning.expressionAssist.modifiers = [.control, .option]
        let restored = LanguageLearningSettings(defaults: defaults)
        #expect(restored.expressionAssist.enabled && restored.expressionAssist.trigger == ";;")
        #expect(restored.expressionAssist.modifiers == [.control, .option])
        #expect(restored.explanation.snapshot == shared)
        learning.expressionAssist.reset()
        #expect(learning.explanation.snapshot == shared)
    }

    @Test
    func shortcutConflictsAreDetectedInBothDirections() throws {
        let suite = "test.expressionShortcuts.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        let assist = settings.languageLearning.expressionAssist
        assist.enabled = true
        assist.keyCode = 4
        assist.modifiers = [.control, .option, .shift]
        #expect(settings.conflictingShortcutName(keyCode: 4, modifiers: assist.modifiers, excluding: .acceptWord) != nil)
        #expect(settings.expressionAssistShortcutConflict(keyCode: settings.acceptanceKeyCode,
            modifiers: settings.acceptanceKeyModifiers) != nil)
        #expect(settings.expressionAssistShortcutConflict(keyCode: 4, modifiers: assist.modifiers) == nil)
        #expect(settings.expressionAssistShortcutConflict(keyCode: .max, modifiers: []) == nil)
    }
}
