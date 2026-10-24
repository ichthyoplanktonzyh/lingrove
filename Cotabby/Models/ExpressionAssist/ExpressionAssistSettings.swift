import Combine
import Foundation

/// Owned by LanguageLearningSettings for the app lifetime. These are interaction preferences;
/// model selection and credentials remain exclusively in the existing explanation profile.
@MainActor
final class ExpressionAssistSettings: ObservableObject {
    private let defaults: UserDefaults
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "expressionAssist.enabled") } }
    @Published var trigger: String { didSet { defaults.set(trigger, forKey: "expressionAssist.trigger") } }
    @Published var keyCode: UInt16 { didSet { defaults.set(Int(keyCode), forKey: "expressionAssist.key") } }
    @Published var modifiers: ShortcutModifierMask {
        didSet { defaults.set(Int(modifiers.rawValue), forKey: "expressionAssist.modifiers") }
    }
    @Published var keyLabel: String { didSet { defaults.set(keyLabel, forKey: "expressionAssist.label") } }

    var changes: AnyPublisher<Void, Never> {
        Publishers.MergeMany([$enabled.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $trigger.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $keyCode.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $modifiers.dropFirst().map { _ in () }.eraseToAnyPublisher()]).eraseToAnyPublisher()
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "expressionAssist.enabled")
        trigger = defaults.string(forKey: "expressionAssist.trigger") ?? "??"
        keyCode = UInt16(clamping: defaults.object(forKey: "expressionAssist.key") as? Int ?? Int(UInt16.max))
        modifiers = ShortcutModifierMask(rawValue: UInt32(clamping:
            defaults.object(forKey: "expressionAssist.modifiers") as? Int ?? 0))
        keyLabel = defaults.string(forKey: "expressionAssist.label") ?? SuggestionSettingsModel.disabledKeyLabel
    }

    func reset() {
        enabled = false
        trigger = "??"
        keyCode = .max
        modifiers = []
        keyLabel = SuggestionSettingsModel.disabledKeyLabel
    }
}
