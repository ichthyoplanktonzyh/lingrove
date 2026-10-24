import Combine
import Foundation

/// Two opt-in bindings live in the central Shortcuts pane. Their independent defaults keys keep
/// notebook commands out of generation snapshots and avoid reloading models when a key changes.
@MainActor
final class VocabularyShortcutSettings: ObservableObject {
    nonisolated enum Command: String, CaseIterable, Sendable { case save, open }
    nonisolated struct Binding: Codable, Equatable, Sendable {
        var key: UInt16 = .max
        var modifiers: ShortcutModifierMask = []
        var label = ""
    }
    @Published private(set) var bindings: [String: Binding]
    private let defaults: UserDefaults
    private static let key = "vocabulary.shortcuts.v1"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        bindings = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Binding].self, from: $0) } ?? [:]
    }

    func binding(_ command: Command) -> Binding { bindings[command.rawValue] ?? Binding() }
    func set(_ command: Command, key: UInt16, modifiers: ShortcutModifierMask, label: String) {
        bindings[command.rawValue] = Binding(key: key, modifiers: modifiers, label: label)
        if let data = try? JSONEncoder().encode(bindings) { defaults.set(data, forKey: Self.key) }
    }
    func reset() { bindings = [:]; defaults.removeObject(forKey: Self.key) }
    func command(key: UInt16, modifiers: ShortcutModifierMask, excluding: Command? = nil) -> Command? {
        guard key != .max else { return nil }
        return Command.allCases.first {
            $0 != excluding && binding($0).key == key && binding($0).modifiers == modifiers
        }
    }
}

extension VocabularyShortcutSettings.Command {
    var title: String {
        switch self {
        case .save: String(localized: "Save current learning item", table: "Vocabulary")
        case .open: String(localized: "Open vocabulary", table: "Vocabulary")
        }
    }
}
